local M = {}

local ns = vim.api.nvim_create_namespace("pointer")
local augroup = vim.api.nvim_create_augroup("pointer", { clear = true })
local float_augroup = vim.api.nvim_create_augroup("pointer_float", { clear = true })

local defaults = {
    keymaps = true,
    blend = 0.12,
    bar = "▎",
    style = "box",
    quickfix = true,
    colors = {
        note = "DiagnosticInfo",
        warn = "DiagnosticWarn",
    },
}

local styles = { "chip", "box", "eol", "float", "loud" }

local config = vim.deepcopy(defaults)
local points = {}
local next_id = 1
local hidden = false
local float_win = nil
local last_selection = nil
local configured = false

M.styles = styles

------------------------------------------------------------------------------------------
----------------------------------- COLORS -----------------------------------------------
------------------------------------------------------------------------------------------

local function get_color(group, attr)
    local hl = vim.api.nvim_get_hl(0, { name = group, link = false })

    return hl[attr]
end

local function blend(fg, bg, alpha)
    local function channel(shift)
        local f = bit.band(bit.rshift(fg, shift), 0xff)
        local b = bit.band(bit.rshift(bg, shift), 0xff)

        return math.min(255, math.max(0, math.floor(b + (f - b) * alpha + 0.5)))
    end

    return bit.bor(bit.lshift(channel(16), 16), bit.lshift(channel(8), 8), channel(0))
end

local function resolve_color(value, fallback)
    if type(value) == "string" and value:match("^#%x%x%x%x%x%x$") then
        return tonumber(value:sub(2), 16)
    end

    return get_color(value, "fg") or fallback
end

local function set_colors()
    local normal_bg = get_color("Normal", "bg") or 0x000000
    local normal_fg = get_color("Normal", "fg") or 0xffffff

    local kinds = {
        Note = resolve_color(config.colors.note, 0x569cd6),
        Warn = resolve_color(config.colors.warn, 0xd7ba7d),
    }

    for name, fg in pairs(kinds) do
        local line_bg = blend(fg, normal_bg, config.blend)
        local card_bg = blend(fg, normal_bg, config.blend * 1.6)
        local card_fg = blend(normal_fg, card_bg, 0.75)
        local loud_bg = blend(fg, normal_bg, 0.3)
        local prefix = "Pointer" .. name

        vim.api.nvim_set_hl(0, prefix .. "Line", { bg = line_bg })
        vim.api.nvim_set_hl(0, prefix .. "Sign", { fg = fg, bg = line_bg, bold = true })
        vim.api.nvim_set_hl(0, prefix .. "Number", { fg = fg, bg = line_bg, bold = true })
        vim.api.nvim_set_hl(0, prefix .. "CardBar", { fg = fg, bg = card_bg, bold = true })
        vim.api.nvim_set_hl(0, prefix .. "CardText", { fg = card_fg, bg = card_bg })
        vim.api.nvim_set_hl(0, prefix .. "Chip", { fg = normal_bg, bg = fg, bold = true })
        vim.api.nvim_set_hl(0, prefix .. "Border", { fg = fg })
        vim.api.nvim_set_hl(0, prefix .. "BoxText", { fg = blend(normal_fg, normal_bg, 0.8) })
        vim.api.nvim_set_hl(0, prefix .. "Eol", { fg = fg, italic = true })
        vim.api.nvim_set_hl(0, prefix .. "LoudBar", { fg = fg, bg = loud_bg, bold = true })
        vim.api.nvim_set_hl(0, prefix .. "LoudText", { fg = fg, bg = loud_bg })
    end
end

------------------------------------------------------------------------------------------
----------------------------------- HELPERS ----------------------------------------------
------------------------------------------------------------------------------------------

local function normalize(path)
    return vim.fn.fnamemodify(vim.fs.normalize(path), ":p")
end

local function kind_name(kind)
    return kind == "warn" and "Warn" or "Note"
end

local function loaded_buffers()
    local map = {}

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
            map[normalize(vim.api.nvim_buf_get_name(buf))] = buf
        end
    end

    return map
end

local function find_buf(file)
    return loaded_buffers()[file]
end

local function pick_window(buf)
    local win = buf and vim.fn.bufwinid(buf) or -1

    if win ~= -1 then
        return win
    end

    local current = vim.api.nvim_get_current_win()

    if vim.bo[vim.api.nvim_win_get_buf(current)].buftype == "" then
        return current
    end

    for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.bo[vim.api.nvim_win_get_buf(candidate)].buftype == "" then
            return candidate
        end
    end

    return current
end

local function window_geometry(buf)
    local info = vim.fn.getwininfo(pick_window(buf))[1]

    if info == nil then
        return math.max(20, vim.o.columns), 0
    end

    return math.max(20, info.width), info.textoff
end

local function wrap(text, width)
    local lines = {}

    for _, paragraph in ipairs(vim.split(text, "\n", { plain = true })) do
        local current = ""

        for word in paragraph:gmatch("%S+") do
            while vim.fn.strdisplaywidth(word) > width do
                if current ~= "" then
                    table.insert(lines, current)
                    current = ""
                end

                table.insert(lines, vim.fn.strcharpart(word, 0, width))
                word = vim.fn.strcharpart(word, width)
            end

            if current == "" then
                current = word
            elseif vim.fn.strdisplaywidth(current .. " " .. word) > width then
                table.insert(lines, current)
                current = word
            else
                current = current .. " " .. word
            end
        end

        table.insert(lines, current)
    end

    return lines
end

local function pad(text, width)
    local fill = width - vim.fn.strdisplaywidth(text)

    return text .. string.rep(" ", math.max(0, fill))
end

------------------------------------------------------------------------------------------
----------------------------------- RENDER -----------------------------------------------
------------------------------------------------------------------------------------------

local function current_range(point)
    if point.buf == nil or not vim.api.nvim_buf_is_valid(point.buf) or point.mark == nil then
        return point.line, point.end_line
    end

    local mark = vim.api.nvim_buf_get_extmark_by_id(point.buf, ns, point.mark, { details = true })

    if #mark == 0 then
        return point.line, point.end_line
    end

    local end_row = mark[3] and mark[3].end_row or mark[1]

    return mark[1] + 1, math.max(end_row, mark[1]) + 1
end

local function detach(point)
    point.line, point.end_line = current_range(point)

    if point.buf and point.mark and vim.api.nvim_buf_is_valid(point.buf) then
        vim.api.nvim_buf_del_extmark(point.buf, ns, point.mark)
    end

    point.buf = nil
    point.mark = nil
end

local function build_virt_lines(point, name, width, textoff)
    local style = config.style
    local bar_prefix = pad(config.bar, textoff)
    local body_width = width - textoff

    if style == "chip" then
        local function card_line(chunks)
            local line = { { bar_prefix, "Pointer" .. name .. "CardBar" } }
            local used = 0

            for _, chunk in ipairs(chunks) do
                table.insert(line, chunk)
                used = used + vim.fn.strdisplaywidth(chunk[1])
            end

            table.insert(line, { string.rep(" ", math.max(0, body_width - used)), "Pointer" .. name .. "CardText" })

            return line
        end

        local label = point.kind == "warn" and " ▲ WARN " or " ● NOTE "
        local lines = {
            card_line({}),
            card_line({ { label, "Pointer" .. name .. "Chip" } }),
            card_line({}),
        }

        for _, chunk in ipairs(wrap(point.text, body_width)) do
            table.insert(lines, card_line({ { chunk, "Pointer" .. name .. "CardText" } }))
        end

        table.insert(lines, card_line({}))

        return lines
    end

    if style == "box" then
        local inner = math.max(10, math.min(body_width - 4, 100))
        local border = "Pointer" .. name .. "Border"
        local blank = string.rep(" ", textoff)
        local lines = {
            { { blank }, { "╭" .. string.rep("─", inner + 2) .. "╮", border } },
        }

        for _, chunk in ipairs(wrap(point.text, inner)) do
            table.insert(lines, {
                { blank },
                { "│ ", border },
                { pad(chunk, inner), "Pointer" .. name .. "BoxText" },
                { " │", border },
            })
        end

        table.insert(lines, { { blank }, { "╰" .. string.rep("─", inner + 2) .. "╯", border } })

        return lines
    end

    if style == "loud" then
        local lines = {
            {
                { bar_prefix, "Pointer" .. name .. "LoudBar" },
                { pad("", body_width), "Pointer" .. name .. "LoudText" },
            },
        }

        for _, chunk in ipairs(wrap(point.text, body_width)) do
            table.insert(lines, {
                { bar_prefix, "Pointer" .. name .. "LoudBar" },
                { pad(chunk, body_width), "Pointer" .. name .. "LoudText" },
            })
        end

        return lines
    end

    return nil
end

local function render(point, buf)
    detach(point)

    if hidden then
        return
    end

    local name = kind_name(point.kind)
    local style = config.style
    local line_count = vim.api.nvim_buf_line_count(buf)
    local width, textoff = window_geometry(buf)
    local line = math.min(point.line, line_count)
    local end_line = math.min(math.max(point.end_line, line), line_count)

    local opts = {
        end_row = end_line - 1,
        sign_text = config.bar,
        sign_hl_group = "Pointer" .. name .. "Sign",
        number_hl_group = "Pointer" .. name .. "Number",
        priority = 50,
    }

    if style ~= "loud" then
        opts.line_hl_group = "Pointer" .. name .. "Line"
    end

    local virt_lines = build_virt_lines(point, name, width, textoff)

    if virt_lines then
        opts.virt_lines = virt_lines
        opts.virt_lines_above = true
        opts.virt_lines_leftcol = true
    end

    if style == "eol" then
        local summary = point.text:gsub("\n", " ")
        local code = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
        local room = width - textoff - vim.fn.strdisplaywidth(code) - 6

        if vim.fn.strdisplaywidth(summary) > room then
            summary = vim.fn.strcharpart(summary, 0, math.max(10, room - 1)) .. "…"
        end

        opts.virt_text = { { "  ◆ " .. summary, "Pointer" .. name .. "Eol" } }
        opts.virt_text_pos = "eol"
    end

    point.buf = buf
    point.mark = vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, opts)
end

local function render_buf(buf)
    if vim.bo[buf].buftype ~= "" then
        return
    end

    local file = normalize(vim.api.nvim_buf_get_name(buf))

    for _, point in ipairs(points) do
        if point.file == file then
            render(point, buf)
        end
    end
end

local function render_all()
    local buffers = loaded_buffers()

    for _, point in ipairs(points) do
        local buf = buffers[point.file]

        if buf then
            render(point, buf)
        else
            detach(point)
        end
    end
end

------------------------------------------------------------------------------------------
----------------------------------- FLOAT ------------------------------------------------
------------------------------------------------------------------------------------------

local function close_float()
    vim.api.nvim_clear_autocmds({ group = float_augroup })

    if float_win and vim.api.nvim_win_is_valid(float_win) then
        vim.api.nvim_win_close(float_win, true)
    end

    float_win = nil
end

local function open_float(point)
    close_float()

    local name = kind_name(point.kind)
    local width = math.min(80, vim.o.columns - 10)
    local lines = wrap(point.text, width)
    local buf = vim.api.nvim_create_buf(false, true)

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"

    local longest = 1

    for _, text in ipairs(lines) do
        longest = math.max(longest, vim.fn.strdisplaywidth(text))
    end

    float_win = vim.api.nvim_open_win(buf, false, {
        relative = "cursor",
        row = 1,
        col = 0,
        width = longest,
        height = math.max(1, #lines),
        style = "minimal",
        border = "rounded",
        title = point.kind == "warn" and " ▲ warn " or " ● note ",
        title_pos = "left",
    })

    vim.wo[float_win].winhighlight = "Normal:Pointer"
        .. name
        .. "CardText,FloatBorder:Pointer"
        .. name
        .. "Border,FloatTitle:Pointer"
        .. name
        .. "Border"
    vim.wo[float_win].wrap = true

    vim.api.nvim_create_autocmd({ "CursorMoved", "BufLeave", "InsertEnter" }, {
        group = float_augroup,
        once = true,
        callback = close_float,
    })
end

------------------------------------------------------------------------------------------
----------------------------------- NAVIGATION -------------------------------------------
------------------------------------------------------------------------------------------

local function point_at_cursor()
    local file = normalize(vim.api.nvim_buf_get_name(0))
    local cursor = vim.api.nvim_win_get_cursor(0)[1]

    for _, point in ipairs(points) do
        if point.file == file then
            local line, end_line = current_range(point)

            if cursor >= line and cursor <= end_line then
                return point
            end
        end
    end

    return nil
end

local function focus(point)
    local buf = find_buf(point.file)

    vim.api.nvim_set_current_win(pick_window(buf))

    if buf == nil then
        vim.cmd.edit(vim.fn.fnameescape(point.file))
        buf = vim.api.nvim_get_current_buf()
    elseif buf ~= vim.api.nvim_get_current_buf() then
        vim.api.nvim_set_current_buf(buf)
    end

    local line = current_range(point)

    vim.api.nvim_win_set_cursor(0, { math.min(line, vim.api.nvim_buf_line_count(buf)), 0 })
    vim.cmd("normal! zz")

    if config.style == "float" or config.style == "eol" then
        vim.schedule(function()
            open_float(point)
        end)
    end
end

local function index_at_cursor()
    local file = normalize(vim.api.nvim_buf_get_name(0))
    local cursor = vim.api.nvim_win_get_cursor(0)[1]
    local before, before_line, after, after_line = nil, nil, nil, nil

    for index, point in ipairs(points) do
        if point.file == file then
            local line, end_line = current_range(point)

            if cursor >= line and cursor <= end_line then
                return index, index
            end

            if line < cursor and (before_line == nil or line > before_line) then
                before, before_line = index, line
            end

            if line > cursor and (after_line == nil or line < after_line) then
                after, after_line = index, line
            end
        end
    end

    return before, after
end

local function step(direction)
    if #points == 0 then
        vim.notify("pointer: nothing to jump to", vim.log.levels.INFO)

        return
    end

    local before, after = index_at_cursor()
    local index

    if before == after and before ~= nil then
        index = before + direction
    elseif direction > 0 then
        index = after or (before and before + 1) or 1
    else
        index = before or (after and after - 1) or #points
    end

    index = ((index - 1) % #points) + 1

    focus(points[index])
end

------------------------------------------------------------------------------------------
----------------------------------- API --------------------------------------------------
------------------------------------------------------------------------------------------

function M.add(opts)
    if type(opts.file) ~= "string" then
        error("point.file must be a string", 0)
    end

    if type(opts.text) ~= "string" then
        error("point.text must be a string", 0)
    end

    local line = tonumber(opts.line)

    if line == nil then
        error("point.line must be a number", 0)
    end

    line = math.max(1, math.floor(line))

    local point = {
        id = next_id,
        file = normalize(opts.file),
        line = line,
        end_line = math.max(line, math.floor(tonumber(opts.end_line) or line)),
        text = opts.text,
        kind = opts.kind == "warn" and "warn" or "note",
        buf = nil,
        mark = nil,
    }

    if vim.fn.filereadable(point.file) == 0 then
        error("not a readable file: " .. point.file, 0)
    end

    local buf = find_buf(point.file)

    if buf then
        render(point, buf)
    end

    next_id = next_id + 1
    table.insert(points, point)

    return point.id
end

function M.point(list, should_focus)
    if hidden then
        hidden = false
        render_all()
    end

    local ids = {}

    for _, item in ipairs(list) do
        table.insert(ids, M.add(item))
    end

    if should_focus ~= false and #ids > 0 then
        local first = #points - #ids + 1

        if config.quickfix then
            M.qf(first)
        end

        focus(points[first])
    end

    return ids
end

function M.clear()
    close_float()

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) then
            vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        end
    end

    points = {}
end

function M.toggle()
    close_float()
    hidden = not hidden
    render_all()
end

function M.next()
    step(1)
end

function M.prev()
    step(-1)
end

function M.hover()
    local point = point_at_cursor()

    if point then
        open_float(point)
    end
end

function M.style(name)
    if not vim.tbl_contains(styles, name) then
        vim.notify("pointer: styles are " .. table.concat(styles, ", "), vim.log.levels.WARN)

        return
    end

    config.style = name
    close_float()
    render_all()
end

function M.list()
    local result = {}

    for _, point in ipairs(points) do
        local line, end_line = current_range(point)

        table.insert(result, {
            id = point.id,
            file = point.file,
            line = line,
            end_line = end_line,
            text = point.text,
            kind = point.kind,
        })
    end

    return result
end

function M.qf(index)
    local items = {}

    for _, point in ipairs(M.list()) do
        table.insert(items, {
            filename = point.file,
            lnum = point.line,
            text = string.format("[%s] %s", point.kind, (point.text:gsub("\n", " "))),
        })
    end

    vim.fn.setqflist({}, " ", { title = "Pointer", items = items, idx = index or 1 })
    vim.cmd.copen()
end

function M.where()
    local win = pick_window(nil)
    local buf = vim.api.nvim_win_get_buf(win)
    local result = {
        file = vim.api.nvim_buf_get_name(buf),
        cursor_line = vim.api.nvim_win_get_cursor(win)[1],
    }

    if last_selection and last_selection.buf == buf and vim.api.nvim_buf_is_valid(buf) then
        local finish = math.min(last_selection.end_line, vim.api.nvim_buf_line_count(buf))

        result.selection = {
            line = last_selection.line,
            end_line = finish,
            text = table.concat(vim.api.nvim_buf_get_lines(buf, last_selection.line - 1, finish, false), "\n"),
        }
    end

    return result
end

function M.rpc(payload)
    if not configured then
        M.setup()
    end

    local ok, request = pcall(vim.json.decode, payload, { luanil = { object = true, array = true } })

    if not ok or type(request) ~= "table" then
        return vim.json.encode({ error = "invalid request" })
    end

    local handlers = {
        point = function(params)
            return { ids = M.point(params.points or {}, params.focus) }
        end,
        clear = function()
            M.clear()

            return { cleared = true }
        end,
        where = M.where,
        list = M.list,
    }

    local handler = handlers[request.method]

    if handler == nil then
        return vim.json.encode({ error = "unknown method " .. tostring(request.method) })
    end

    local success, result = pcall(handler, request.params or {})

    if not success then
        return vim.json.encode({ error = tostring(result) })
    end

    return vim.json.encode(result)
end

function M.setup(opts)
    config = vim.tbl_deep_extend("force", defaults, opts or {})
    configured = true

    if not vim.tbl_contains(styles, config.style) then
        vim.notify("pointer: styles are " .. table.concat(styles, ", "), vim.log.levels.WARN)
        config.style = defaults.style
    end

    set_colors()

    vim.api.nvim_clear_autocmds({ group = augroup })

    vim.api.nvim_create_autocmd("ColorScheme", { group = augroup, callback = set_colors })

    vim.api.nvim_create_autocmd("BufWinEnter", {
        group = augroup,
        callback = function(event)
            render_buf(event.buf)
        end,
    })

    vim.api.nvim_create_autocmd("BufUnload", {
        group = augroup,
        callback = function(event)
            for _, point in ipairs(points) do
                if point.buf == event.buf then
                    detach(point)
                end
            end
        end,
    })

    vim.api.nvim_create_autocmd("VimResized", { group = augroup, callback = render_all })

    vim.api.nvim_create_autocmd("WinResized", {
        group = augroup,
        callback = function()
            local seen = {}

            for _, win in ipairs(vim.v.event.windows or {}) do
                if vim.api.nvim_win_is_valid(win) then
                    local buf = vim.api.nvim_win_get_buf(win)

                    if not seen[buf] then
                        seen[buf] = true
                        render_buf(buf)
                    end
                end
            end
        end,
    })

    vim.api.nvim_create_autocmd("ModeChanged", {
        group = augroup,
        pattern = "[vV\x16]*:*",
        callback = function(event)
            last_selection = {
                buf = event.buf,
                line = vim.fn.line("'<"),
                end_line = vim.fn.line("'>"),
            }
        end,
    })

    if config.keymaps then
        vim.keymap.set("n", "]a", M.next, { desc = "[Pointer] Next point" })
        vim.keymap.set("n", "[a", M.prev, { desc = "[Pointer] Previous point" })
    end
end

return M
