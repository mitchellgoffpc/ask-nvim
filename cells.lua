local M = {}

function M.execute_code_block()
    local bufnr = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local code_block = {}
    local in_code_block = false
    local language = ""

    for _, line in ipairs(lines) do
        if line:match("^```(.*)$") then
            if in_code_block then
                in_code_block = false
                break
            else
                in_code_block = true
                language = line:match("^```(.*)$")
            end
        elseif in_code_block then
            table.insert(code_block, line)
        end
    end

    if #code_block > 0 then
        local output_bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_option(output_bufnr, 'buftype', 'nofile')
        vim.api.nvim_buf_set_option(output_bufnr, 'swapfile', false)
        vim.api.nvim_buf_set_option(output_bufnr, 'bufhidden', 'wipe')

        -- Use botright vsplit to open the new window on the right side
        vim.cmd('botright vsplit')
        vim.api.nvim_win_set_buf(0, output_bufnr)

        local code = table.concat(code_block, "\n")
        local temp_file = os.tmpname()
        local file = io.open(temp_file, "w")
        file:write(code)
        file:close()

        local cmd = ""
        if language == "python" then
            cmd = "python " .. temp_file
        elseif language == "lua" then
            cmd = "lua " .. temp_file
        else
            vim.api.nvim_buf_set_lines(output_bufnr, 0, -1, false, {"Unsupported language: " .. language})
            return
        end

        local output = vim.fn.system(cmd)
        os.remove(temp_file)

        vim.api.nvim_buf_set_lines(output_bufnr, 0, -1, false, vim.split(output, "\n"))
    else
        print("No code block found")
    end
end

function M.setup()
    vim.api.nvim_set_keymap('n', '<C-CR>', '<cmd>lua require("cells").execute_code_block()<CR>', { noremap = true, silent = true })
end

return M
