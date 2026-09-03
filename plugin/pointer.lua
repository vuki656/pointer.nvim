if vim.g.loaded_pointer then
    return
end

vim.g.loaded_pointer = true

local subcommands = { "clear", "toggle", "next", "prev", "qf", "hover", "style" }

vim.api.nvim_create_user_command("Pointer", function(opts)
    local pointer = require("pointer")
    local name = opts.fargs[1]
    local action = pointer[name]

    if action == nil or not vim.tbl_contains(subcommands, name) then
        vim.notify("Pointer: " .. table.concat(subcommands, "|"), vim.log.levels.WARN)

        return
    end

    action(opts.fargs[2])
end, {
    nargs = "+",
    complete = function(_, line)
        if line:match("^%s*Pointer%s+style%s+") then
            return require("pointer").styles
        end

        return subcommands
    end,
})
