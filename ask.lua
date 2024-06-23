local api = vim.api
local fn = vim.fn
local json = vim.json

local M = {}

local system_prompt = [[
You are an AI programming assistant integrated into a code editor. Your purpose is to help the user with programming tasks as they write code. When asked to write code, only generate the code, with no additional information.
]]

-- API base class
local API = {}
API.__index = API

function API.new(url, key)
    local self = setmetatable({}, API)
    self.url = url
    self.key = key
    return self
end

function API.headers(api_key)
    return {Authorization = "Bearer " .. api_key, ["Content-Type"] = "application/json"}
end

function API.params(model_name, messages, temperature)
    temperature = temperature or 0.7
    return {
        model = model_name,
        messages = messages,
        temperature = temperature,
        max_tokens = 4096,
        stream = true
    }
end

function API.decode(chunk)
    if string.sub(chunk, 1, 6) == "data: " and chunk ~= 'data: [DONE]' then
        local line = json.decode(string.sub(chunk, 7))
        return line.choices[1].delta.content or ''
    else
        return ''
    end
end

-- Anthropic API
local AnthropicAPI = setmetatable({}, {__index = API})
AnthropicAPI.__index = AnthropicAPI

function AnthropicAPI.new(url, key)
    local self = setmetatable(API.new(url, key), AnthropicAPI)
    return self
end

function AnthropicAPI.headers(api_key)
    return {
        ["x-api-key"] = api_key,
        ["anthropic-version"] = "2023-06-01",
        ["Content-Type"] = "application/json"
    }
end

function AnthropicAPI.params(model_name, messages, temperature)
    temperature = temperature or 0.7
    local systemMessages = {}
    local userMessages = {}
    for _, msg in ipairs(messages) do
        if msg.role == "system" then
            table.insert(systemMessages, msg.content)
        elseif msg.role == "user" then
            table.insert(userMessages, msg)
        end
    end
    local systemPrompt = #systemMessages > 0 and table.concat(systemMessages, "\n\n") or nil
    return {
        model = model_name,
        system = systemPrompt,
        messages = userMessages,
        temperature = temperature,
        max_tokens = 4096,
        stream = true
    }
end

function AnthropicAPI.decode(chunk)
    if string.sub(chunk, 1, 6) == "data: " and chunk ~= 'data: [DONE]' then
        local line = json.decode(string.sub(chunk, 7))
        if line.type == 'content_block_delta' then
            return line.delta.text
        end
    end
    return ''
end

-- API definitions
local APIS = {
    OpenAI = API.new("https://api.openai.com/v1/chat/completions", "OPENAI_API_KEY"),
    Mistral = API.new("https://api.mistral.ai/v1/chat/completions", "MISTRAL_API_KEY"),
    Anthropic = AnthropicAPI.new("https://api.anthropic.com/v1/messages", "ANTHROPIC_API_KEY")
}

-- Model definitions
local MODELS = {
    {id = "gpt-3.5-turbo", name = "GPT 3.5 Turbo", api = APIS.OpenAI},
    {id = "gpt-4", name = "GPT 4", api = APIS.OpenAI},
    {id = "gpt-4-turbo", name = "GPT 4 Turbo", api = APIS.OpenAI},
    {id = "open-mixtral-8x7b", name = "Mixtral", api = APIS.Mistral},
    {id = "mistral-medium-latest", name = "Mistral Medium", api = APIS.Mistral},
    {id = "mistral-large-latest", name = "Mistral Large", api = APIS.Mistral},
    {id = "claude-3-haiku-20240307", name = "Claude 3 Haiku", api = APIS.Anthropic},
    {id = "claude-3-5-sonnet-20240620", name = "Claude 3 Sonnet", api = APIS.Anthropic},
    {id = "claude-3-opus-20240229", name = "Claude 3 Opus", api = APIS.Anthropic}
}

-- Functions to get/set the active model
local function get_active_model()
    local active_model_id = vim.g.ACTIVE_MODEL_ID or MODELS[1].id
    for _, model in ipairs(MODELS) do
        if model.id == active_model_id then
            return model
        end
    end
    return MODELS[1]
end

local function set_active_model(model_id)
    for _, model in ipairs(MODELS) do
        if model.id == model_id then
            vim.g.ACTIVE_MODEL_ID = model_id
            return true
        end
    end
    return false
end

-- Buffer logic
local response_buffer = nil
local function get_or_create_response_buffer()
    if response_buffer and api.nvim_buf_is_valid(response_buffer) then
        -- Clear the existing buffer
        api.nvim_buf_set_lines(response_buffer, 0, -1, false, {})
        -- Switch to the window containing the response buffer
        for _, win in ipairs(api.nvim_list_wins()) do
            if api.nvim_win_get_buf(win) == response_buffer then
                api.nvim_set_current_win(win)
                return response_buffer
            end
        end
        -- If window not found, create a new split with the existing buffer
        api.nvim_command("botright vsplit")
        api.nvim_win_set_buf(0, response_buffer)
        return response_buffer
    else
        -- Create a new buffer if none exists
        response_buffer = api.nvim_create_buf(false, true)
        api.nvim_command("botright vsplit")
        api.nvim_win_set_buf(0, response_buffer)
        api.nvim_buf_set_option(response_buffer, "buftype", "nofile")
        return response_buffer
    end
end

local function write_string_at_cursor(str)
	local current_window = api.nvim_get_current_win()
	local cursor_position = api.nvim_win_get_cursor(current_window)
	local row, col = cursor_position[1], cursor_position[2]

	local lines = vim.split(str, "\n")
	api.nvim_put(lines, "c", true, true)

	local num_lines = #lines
	local last_line_length = #lines[num_lines]
	api.nvim_win_set_cursor(current_window, {row + num_lines - 1, col + last_line_length})
end

-- Query logic
local function trim(str)
    return str:gsub("^%s*(.-)%s*$", "%1")
end

local function escape_single_quotes(str)
    return string.gsub(str, "'", "'\\''")
end

local function format_headers(headers)
    local result = ""
    for key, value in pairs(headers) do
        result = result .. "-H '" .. key .. ": " .. value .. "' "
    end
    return result
end

local function stream_response_to_buffer(prompt, buf)
    local model = get_active_model() 
    local api_key = os.getenv(model.api.key)

    if not api_key or api_key == "" then
        error("API key not found. Please set the " .. model.api.key .. " environment variable.")
    end

    local messages = {{role = "system", content = trim(system_prompt)}, {role = "user", content = trim(prompt)}}
    local payload = json.encode(model.api.params(model.id, messages))
    local headers = model.api.headers(api_key)
    local curl_command = string.format("curl -sN %s %s -d '%s'", model.api.url, format_headers(headers), escape_single_quotes(payload)) 

    local first_chunk = true
    local job_id = fn.jobstart(curl_command, {
        on_stdout = function(_, data)
            for _, chunk in ipairs(data) do
                if first_chunk then
                    write_string_at_cursor("\n")
                else
                    vim.cmd("undojoin")
                end
                write_string_at_cursor(model.api.decode(chunk)) 
                first_chunk = false
            end
        end,
        on_exit = function()
            if not first_chunk then
                vim.cmd("undojoin")
                write_string_at_cursor("\n")
            end
        end, 
        stdout_buffered = false
    })

    if job_id == 0 then
        error("Error: Invalid arguments for job")
    elseif job_id == -1 then
        error("Error: Job table is invalid")
    end
end

-- Ask / Insert / Modify / Model commands
api.nvim_create_user_command("Ask", function(opts)
    local question = opts.args
    local buf = get_or_create_response_buffer()
    api.nvim_buf_set_lines(buf, 0, -1, false, {})
    write_string_at_cursor(question)
    stream_response_to_buffer(question, buf)
end, {nargs = "+"})

api.nvim_create_user_command("Modify", function(opts)
    -- Get the visual selection range
    local start_pos = fn.getpos("'<")
    local end_pos = fn.getpos("'>")
    local start_line, start_col = start_pos[2], start_pos[3]
    local end_line, end_col = end_pos[2], end_pos[3]

    -- Get the selected text
    local lines = api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
    if #lines == 1 then
        lines[1] = string.sub(lines[1], start_col, end_col)
    else
        lines[1] = string.sub(lines[1], start_col)
        lines[#lines] = string.sub(lines[#lines], 1, end_col)
    end
    local selected_text = table.concat(lines, "\n")

    local prompt = string.format("Modify the following text:\n\n%s\n\nInstructions: %s", selected_text, opts.args)
    local buf = get_or_create_response_buffer()
    api.nvim_buf_set_lines(buf, 0, -1, false, {})
    write_string_at_cursor(prompt)
    stream_response_to_buffer(prompt, buf)
end, {nargs = "+", range = true})

api.nvim_create_user_command("Model", function(opts)
    local model_id = opts.args
    if model_id == "" then
        -- List available models if no argument is provided
        print("Available models:")
        for _, model in ipairs(MODELS) do
            print(string.format("- %s (%s)", model.id, model.name))
        end
        print(string.format("Current model: %s", get_active_model().id))
    else
        -- Set the active model
        if set_active_model(model_id) then
            print(string.format("Switched to model: %s", model_id))
        else
            print(string.format("Invalid model ID: %s", model_id))
        end
    end
end, {nargs = "?"})

-- Set key mappings
M.ask_command_wrapper = function ()
    local buf = api.nvim_get_current_buf()
    local content = api.nvim_buf_get_lines(buf, 0, -1, false)
    local prompt = table.concat(content, "\n")
    if prompt ~= "" then
        stream_response_to_buffer(prompt, buf)
    end
end

api.nvim_set_keymap('n', '.', [[<cmd>lua require('ask').ask_command_wrapper()<CR>]], {noremap = true, silent = true})

return M
