local math = require('math')
local scroll_timer = vim.loop.new_timer()
local lines_to_scroll = 0
local lines_scrolled = 0
local scrolling = false
local guicursor
-- Highlight group to hide the cursor
vim.cmd('highlight NeoscrollHiddenCursor gui=reverse blend=100')


-- Helper function to check if a number is a float
local function is_float(n)
    return math.floor(math.abs(n)) ~= math.abs(n)
end


-- excecute commands to scroll screen [and cursor] up/down one line
-- `execute` is necessary to allow the use of special characters like <C-y>
-- The bang (!) `normal!` in normal ignores mappings
local function scroll_up(scroll_window, scroll_cursor)
    cursor_scroll_input = scroll_cursor and 'gk' or ''
    window_scroll_input = scroll_window and [[\<C-y>]] or ''
    scroll_input = cursor_scroll_input .. window_scroll_input
    return [[exec "normal! ]] .. scroll_input .. [["]]
end
local function scroll_down(scroll_window, scroll_cursor)
    cursor_scroll_input = scroll_cursor and 'gj' or ''
    window_scroll_input = scroll_window and [[\<C-e>]] or ''
    scroll_input = cursor_scroll_input .. window_scroll_input
    return [[exec "normal! ]] .. scroll_input .. [["]]
end


-- Hide cursor during scrolling for a better visual effect
local function hide_cursor()
    if vim.o.termguicolors then
        guicursor = vim.o.guicursor
        vim.o.guicursor = guicursor .. ',a:NeoscrollHiddenCursor'
    end
end


-- Restore hidden cursor during scrolling
local function restore_cursor()
    if vim.o.termguicolors then
        vim.o.guicursor = guicursor
    end
end


-- Count number of folded lines
-- window_line_start < window_line_end
local function get_folded_lines(starting_line, window_lines)
    local line = starting_line
    local window_line = 0
    local folded_lines = 0
    if window_lines < 0 then
        repeat
            local first_folded_line = vim.fn.foldclosed(line)
            if first_folded_line ~= -1 then
                folded_lines = folded_lines + line - first_folded_line
                line = first_folded_line
            end
            line = line - 1
            window_line = window_line - 1
        until(window_line == window_lines - 1)
    else
        repeat
            last_folded_line = vim.fn.foldclosedend(line)
            if last_folded_line ~= -1 then
                folded_lines = folded_lines + last_folded_line - line
                line = last_folded_line
            end
            line = line + 1
            window_line = window_line + 1
        until(window_line == window_lines + 1)
    end
    return folded_lines
end


-- Collect all the necessary window, buffer and cursor data
local function get_data(direction)
    data = {}
    data.buffer_lines = vim.api.nvim_buf_line_count(0)
    data.cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    data.window_height = vim.api.nvim_win_get_height(0)
    data.lines_above_cursor = vim.fn.winline() - 1
    data.lines_below_cursor = data.window_height - (data.lines_above_cursor + 1)
    if direction < 0 then
        local window_lines = -(data.lines_above_cursor + 1)
        data.folded_lines = get_folded_lines(data.cursor_line, window_lines)
        data.win_top_line = data.cursor_line - data.lines_above_cursor - data.folded_lines
    else
        local window_lines = data.lines_below_cursor + 1
        data.folded_lines = get_folded_lines(data.cursor_line, window_lines)
        data.win_bottom_line = data.cursor_line + data.folded_lines + data.lines_below_cursor
        data.last_line = data.buffer_lines - data.folded_lines
    end
    return data
end


-- Window rules for when to stop scrolling
local function window_reached_limit(data, direction, move_cursor)
    if direction < 0 then
        return data.win_top_line == 1
    else
        if move_cursor then
            if vim.g.neoscroll_stop_eof
                and data.win_bottom_line == data.buffer_lines then
                return true
            end
            if vim.g.neoscroll_respect_scrolloff then
                return data.cursor_line == data.last_line - vim.wo.scrolloff
            else
                return data.cursor_line == data.last_line 
            end
        else
            return data.cursor_line == data.last_line
                and data.lines_above_cursor == 0
        end
    end
end


-- Cursor rules for when to stop scrolling
local function cursor_reached_limit(data, direction)
    if direction < 0 then
        if vim.g.neoscroll_respect_scrolloff
                and data.cursor_line == vim.wo.scrolloff then
            return true
        end
        return data.cursor_line == 1
    else
        if vim.g.neoscroll_respect_scrolloff and
                data.cursor_line == data.last_line - vim.wo.scrolloff
            then return true
        end
        return data.cursor_line == data.last_line
    end
end


-- Transforms fraction of window to number of lines
local function get_lines_from_win_fraction(fraction)
    height_fraction = fraction * vim.api.nvim_win_get_height(0)
    return vim.fn.float2nr(vim.fn.round(height_fraction))
end


-- Check if the window and the cursor can be scrolled further
local function who_scrolls(direction, move_cursor)
    local scroll_window, scroll_cursor, data
    data = get_data(direction)
    scroll_window = not window_reached_limit(data, direction, move_cursor)
    if not move_cursor then
        scroll_cursor = false
    elseif scroll_window then
        scroll_cursor = true
    elseif vim.g.neoscroll_cursor_scrolls_alone then
        scroll_cursor = not cursor_reached_limit(data, direction)
    else
        scroll_cursor = false
    end
    return scroll_window, scroll_cursor
end


-- Scroll one line in the given direction
local function scroll_one_line(direction, scroll_window, scroll_cursor)
    if direction > 0 then
        lines_scrolled = lines_scrolled + 1
        vim.cmd(scroll_down(scroll_window, scroll_cursor))
    else
        lines_scrolled = lines_scrolled - 1
        vim.cmd(scroll_up(scroll_window, scroll_cursor))
    end
end


-- Finish scrolling
local function finish_scrolling(move_cursor)
    if vim.g.neoscroll_hide_cursor == true and move_cursor then
        restore_cursor()
    end
    lines_scrolled = 0
    lines_to_scroll = 0
    scroll_timer:stop()
    scrolling = false
end


neoscroll = {}


-- Scrolling function
-- lines: number of lines to scroll or fraction of window to scroll
-- move_cursor: scroll the window and the cursor simultaneously 
-- time_step: time (in miliseconds) between one line scroll and the next one
neoscroll.scroll = function(lines, move_cursor, time_step)
    -- If lines is a fraction of the window transform it to lines
    if is_float(lines) then
        lines = get_lines_from_win_fraction(lines)
    end
    -- If still scrolling just modify the amount of lines to scroll
    if scrolling then
        lines_to_scroll = lines_to_scroll + lines
        return
    end

    -- Check if the window and the cursor are allowed to scroll in that direction
    local scroll_window, scroll_cursor = who_scrolls(lines, move_cursor)

    -- If neither the window nor the cursor are allowed to scroll finish early
    if not scroll_window and not scroll_cursor then return end

    -- Start scrolling
    scrolling = true

    --Hide cursor line 
    if vim.g.neoscroll_hide_cursor and move_cursor then
        hide_cursor()
    end

    --assign the number of lines to scroll
    lines_to_scroll = lines

    -- Callback function triggered by scroll_timer
    local function scroll_callback()
        direction = lines_to_scroll - lines_scrolled
        if direction == 0 then
            finish_scrolling(move_cursor)
        else
            scroll_window, scroll_cursor = who_scrolls(direction, move_cursor)
            if not scroll_window and not scroll_cursor then
                finish_scrolling(move_cursor)
            else
                scroll_one_line(direction, scroll_window, scroll_cursor)
            end
        end
    end

    -- Scroll the first line
    scroll_one_line(lines, scroll_window, scroll_cursor)

    -- Start timer to scroll the rest of the lines
    scroll_timer:start(time_step, time_step, vim.schedule_wrap(scroll_callback))
end


-- Helper function for mapping keys
neoscroll.map = function(mode, keymap, lines, move_cursor, time_step)
    local prefix = mode == 'x' and '<cmd>lua ' or ':lua '
    local suffix = '<CR>'
    local args = lines .. ', ' .. move_cursor .. ', ' .. time_step
    local lua_cmd = 'neoscroll.scroll(' .. args .. ')'
    local cmd = prefix .. lua_cmd .. suffix
    vim.api.nvim_set_keymap(mode, keymap, cmd, {silent=true})
end


-- Default mappings
neoscroll.set_mappings = function()
    neoscroll.map('n', '<C-u>', '-vim.wo.scroll', 'true', '8')
    neoscroll.map('x', '<C-u>', '-vim.wo.scroll', 'true', '8')
    neoscroll.map('n', '<C-d>',  'vim.wo.scroll', 'true', '8')
    neoscroll.map('x', '<C-d>',  'vim.wo.scroll', 'true', '8')
    neoscroll.map('n', '<C-b>', '-vim.api.nvim_win_get_height(0)', 'true', '7')
    neoscroll.map('x', '<C-b>', '-vim.api.nvim_win_get_height(0)', 'true', '7')
    neoscroll.map('n', '<C-f>',  'vim.api.nvim_win_get_height(0)', 'true', '7')
    neoscroll.map('x', '<C-f>',  'vim.api.nvim_win_get_height(0)', 'true', '7')
    neoscroll.map('n', '<C-y>', '-0.10', 'false', '20')
    neoscroll.map('x', '<C-y>', '-0.10', 'false', '20')
    neoscroll.map('n', '<C-e>',  '0.10', 'false', '20')
    neoscroll.map('x', '<C-e>',  '0.10', 'false', '20')
end


return neoscroll
