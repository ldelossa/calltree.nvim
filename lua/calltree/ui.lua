local tree = require('calltree.tree')
local ct = require('calltree')
local lsp_util = require('calltree.lsp.util')

local M = {}

M.glyphs = {
    expanded= "▼",
    collapsed= "▶"
}

local direction_map = {
    from = {method ="callHierarchy/incomingCalls", buf_name="incomingCalls"},
    to   = {method="callHierarchy/outgoingCalls", buf_name="outgoingCalls"}
}

-- the global calltree buffer
M.buffer_handle = nil
-- the global calltree window
M.win_handle = nil
-- the last tabpage our outline ui was on
M.win_tabpage = nil
-- the active lsp clients attached to the
-- buffer invoking the call tree.
M.active_lsp_clients = nil
-- determines the direction (incoming or outgoing) of calls
-- the calltree is showing.
M.direction = nil
-- the window in which the calltree was invoked.
M.invoking_win_handle = nil
-- the buffer switched to when the user asks for help
M.help_buffer_handle = nil
-- the current sighlight source, reset on jumps
M.jump_higlight_ns = vim.api.nvim_create_namespace("calltree-jump")
M.last_highlighted_buffer = nil

-- idempotent creation and configuration of call tree's ui buffer
local function _setup_buffer()
    if M.buffer_handle == nil then
        local buf = vim.api.nvim_create_buf(false, false)
        if buf == 0 then
            vim.api.nvim_err_writeln("ui.open failed: buffer create failed")
            return
        end
        M.buffer_handle = buf
    end

    -- allow empty calltree buffer
    -- only occurs if CTOpen is called before "nvim.lsp.buf.outgoingCalls" is.
    local buf_name = "empty calltree"
    if M.direction ~= nil then
        buf_name = direction_map[M.direction].buf_name
    end

    -- set buf options
    vim.api.nvim_buf_set_name(M.buffer_handle, buf_name)
    vim.api.nvim_buf_set_option(M.buffer_handle, 'bufhidden', 'hide')
    vim.api.nvim_buf_set_option(M.buffer_handle, 'filetype', 'Calltree')
    vim.api.nvim_buf_set_option(M.buffer_handle, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(M.buffer_handle, 'modifiable', false)
    vim.api.nvim_buf_set_option(M.buffer_handle, 'swapfile', false)

    -- au to clear highlights on window close
    vim.cmd("au BufWinLeave <buffer=" .. M.buffer_handle .. "> lua require('calltree.ui').clear_jump_hl()")

    -- set buffer local keymaps
    local opts = {silent=true}
    vim.api.nvim_buf_set_keymap(M.buffer_handle, "n", "zo", ":CTExpand<CR>", opts)
    vim.api.nvim_buf_set_keymap(M.buffer_handle, "n", "zc", ":CTCollapse<CR>", opts)
    vim.api.nvim_buf_set_keymap(M.buffer_handle, "n", "<CR>", ":CTJump<CR>", opts)
    vim.api.nvim_buf_set_keymap(M.buffer_handle, "n", "f", ":CTFocus<CR>", opts)
    vim.api.nvim_buf_set_keymap(M.buffer_handle, "n", "i", ":CTHover<CR>", opts)
    vim.api.nvim_buf_set_keymap(M.buffer_handle, "n", "s", ":CTSwitch<CR>", opts)
    vim.api.nvim_buf_set_keymap(M.buffer_handle, "n", "?", ":lua require('calltree.ui').help(true)<CR>", opts)
end

-- idempotent creation of the help buffer.
local function _setup_help_buffer()
    if M.help_buffer_handle == nil or not vim.api.nvim_buf_is_valid(M.help_buffer_handle) then
        local buf = vim.api.nvim_create_buf(false, false)
        if buf == 0 then
            vim.api.nvim_err_writeln("ui.help failed: buffer create failed")
            return
        end
        M.help_buffer_handle = buf
        local lines = {
            "CALLTREE HELP:",
            "press 'c' to close",
            "",
            "KEYMAP:",
            "zo      - expand a symbol",
            "zc      - collapse a symbol",
            "return  - jump to symbol",
            "f       - focus the tree on this symbol",
            "s       - switch the symbol from",
            "          incoming/outgoing calls"
        }
        vim.api.nvim_buf_set_lines(M.help_buffer_handle, 0, #lines, false, lines)
    end
    -- set buf options
    vim.api.nvim_buf_set_name(M.help_buffer_handle, "Calltree Help")
    vim.api.nvim_buf_set_option(M.help_buffer_handle, 'bufhidden', 'hide')
    vim.api.nvim_buf_set_option(M.help_buffer_handle, 'filetype', 'Calltree')
    vim.api.nvim_buf_set_option(M.help_buffer_handle, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(M.help_buffer_handle, 'modifiable', false)
    vim.api.nvim_buf_set_option(M.help_buffer_handle, 'swapfile', false)

    -- set buffer local keymaps
    local opts = {silent=true}
    vim.api.nvim_buf_set_keymap(M.help_buffer_handle, "n", "c", ":lua require('calltree.ui').help(false)<CR>", opts)
end

-- help opens the help buffer in the current calltree window
-- if it exists.
M.help = function(open)
    if
        not vim.api.nvim_win_is_valid(M.win_handle) or
        M.win_handle == nil or
        not vim.api.nvim_buf_is_valid(M.buffer_handle) or
        M.buffer_handle == nil
    then
        return
    end
    if not open then
        vim.api.nvim_win_set_buf(M.win_handle, M.buffer_handle)
        return
    end
    _setup_help_buffer()
    vim.api.nvim_win_set_buf(M.win_handle, M.help_buffer_handle)
end

-- idempotent creation and configuration of call tree's ui window.
local function _setup_window()
    local current_tabpage = vim.api.nvim_win_get_tabpage(
        vim.api.nvim_get_current_win()
    )
    if M.win_handle == nil
        or (current_tabpage ~= M.win_tabpage)
        or not vim.api.nvim_win_is_valid(M.win_handle) then
        if M.win_handle ~= nil and vim.api.nvim_win_is_valid(M.win_handle) then
            vim.api.nvim_win_close(M.win_handle, true)
        end

        if ct.config.layout == "left" then
            vim.cmd("topleft vsplit")
        else
            vim.cmd("botright vsplit")
        end

        vim.cmd("vertical resize " ..
                    ct.config.layout_size)

        M.win_handle = vim.api.nvim_get_current_win()
        M.win_tabpage = vim.api.nvim_win_get_tabpage(M.win_handle)
        vim.api.nvim_win_set_buf(M.win_handle, M.buffer_handle)
    end
    vim.api.nvim_win_set_option(M.win_handle, 'number', false)
    vim.api.nvim_win_set_option(M.win_handle, 'cursorline', true)
    vim.api.nvim_buf_set_option(M.buffer_handle, 'textwidth', 0)
    vim.api.nvim_buf_set_option(M.buffer_handle, 'wrapmargin', 0)
    vim.api.nvim_win_set_option(M.win_handle, 'wrap', false)
end

-- open will open the call tree ui
M.open = function()
    _setup_buffer()
    _setup_window()
    if tree.root_node ~= nil then
        M.write_tree({}, tree.root_node)
    end
end

-- close will close the call tree ui
M.close = function()
    if M.win_handle ~= nil then
        if vim.api.nvim_win_is_valid(M.win_handle) then
            vim.api.nvim_win_close(M.win_handle, true)
        end
    end
    M.win_handle = nil
end

-- encodes a tree node into a ui line
-- node : Node - the node to enode into a buffer
--               line.
-- returns string
M.encode_node_to_line = function(node)
    local str = ""
    local glyph
    if node.expanded then
        glyph = M.glyphs["expanded"]
    else
        glyph = M.glyphs["collapsed"]
    end

    local kind = vim.lsp.protocol.SymbolKind[node.kind]

    -- add spacing up to node's depth
    for _=1, node.depth do
        str = str .. " "
    end

    str = str .. glyph .. " " .. node.name .. " "
    if ct.config.icons ~= "none" then
        str = str .. ct.active_icon_set[kind]
    else
        str = str .. "•" .. " " .. kind
    end
    return str
end

-- decodes a ui line into a tree node.
-- line : string - the line to encode into a tree.Node
-- returns tree.Node
M.decode_line_to_node = function(line)
    -- number of characters up to the expand symbol encode
    -- the node's tree depth.
    local depth  = vim.fn.match(line, "[▼▶]")
    if depth == -1 then
        vim.api.nvim_err_writeln("failed to find matching character: " .. depth)
        return
    end

    -- just your normal string parsing to carve out the symbol portion
    -- of the line.
    local symbol_and_type = vim.fn.strcharpart(line, depth+2)
    local symbol_end_idx = vim.fn.stridx(symbol_and_type, " ")
    local symbol = vim.fn.strpart(symbol_and_type, 0, symbol_end_idx)

    for _, node in ipairs(tree.depth_table[depth]) do
        if node.name == symbol then
            return node
        end
    end
    return nil
end

-- write_tree writes the current call hierarchy
-- tree into the ui's buffer.
--
-- preorder traveral will print the outline as a
-- user would expect.
--
-- lines : string[] - recursive accumlator of buffer lines to write
--                  - call this function with an empty table {}
-- node : tree.Node - the node to write to the tree. call this function
--                    with tree.root_node typically.
M.write_tree = function(lines, node)
    -- this is the root - ensure the outline buffer
    -- is setup.
    if node.depth == 0 then
        _setup_buffer()
    end

    table.insert(lines, M.encode_node_to_line(node))

    -- if we are an expanded node or we are the root (always expand)
    -- recurse
    if node.expanded  or node.depth == 0 then
        for _, child in ipairs(node.children) do
            M.write_tree(lines, child)
        end
    end

    -- we are back at the root, all lines are inserted, lets write it out
    -- to the buffer
    if node.depth == 0 then
        vim.api.nvim_buf_set_option(M.buffer_handle, 'modifiable', true)
        vim.api.nvim_buf_set_lines(M.buffer_handle, 0, -1, true, {})
        vim.api.nvim_buf_set_lines(M.buffer_handle, 0, #lines, false, lines)
        vim.api.nvim_buf_set_option(M.buffer_handle, 'modifiable', false)
        _setup_window()
    end
end

-- collapse will collapse a symbol at the current cursor
-- position
M.collapse = function()
    local linenr = vim.api.nvim_win_get_cursor(M.win_handle)
    local line   = vim.api.nvim_get_current_line()
    local node = M.decode_line_to_node(line)
    if node == nil then
        return
    end

    node.expanded = false
    tree.remove_subtree(node, true)

    M.write_tree({}, tree.root_node)
    vim.api.nvim_win_set_cursor(M.win_handle, linenr)
end

-- expand will expand a symbol at the current cursor position
M.expand = function()
    local linenr = vim.api.nvim_win_get_cursor(M.win_handle)
    local line   = vim.api.nvim_get_current_line()
    local node = M.decode_line_to_node(line)
    if node == nil then
        return
    end

    if not node.expanded then
        node.expanded = true
    end

    lsp_util.multi_client_request(
        M.active_lsp_clients,
        direction_map[M.direction].method,
        {item = node.call_hierarchy_obj},
        M.ch_expand_handler(node, linenr, M.direction),
        M.buffer_handle
    )
end

-- focus will reparent the calltree to the symbol under
-- the cursor, creating a calltree with the symbol
-- as root.
M.focus = function()
    local line   = vim.api.nvim_get_current_line()
    local node = M.decode_line_to_node(line)
    if node == nil then
        return
    end

    tree.reparent_node(0, node)

    M.write_tree({}, tree.root_node)
end

-- switch_direction will focus the symbol under the
-- cursor and then invert the call hierarchy direction.
M.switch_direction = function()
    local line = vim.api.nvim_get_current_line()
    local node = M.decode_line_to_node(line)
    if node == nil then
        return
    end

    if M.direction == "from" then
        M.direction = "to"
    else
        M.direction = "from"
    end

    lsp_util.multi_client_request(
        M.active_lsp_clients,
        direction_map[M.direction].method,
        {item = node.call_hierarchy_obj},
        M.ch_switch_handler(M.direction),
        M.buffer_handle
    )
end

-- switch handler is the call_hierarchy handler
-- used when switching directions.
M.ch_switch_handler = function(direction)
    return function(err, result, ctx, _)
        if err ~= nil then
            return
        end
        -- create the root of our call tree, the request which
        -- signaled this response is in ctx.params
        local root = tree.Node.new(ctx.params.item.name,
        0,
        ctx.params.item,
        ctx.params.item.kind)

        -- create the root's children nodes via the response array.
        local children = {}
        for _, call_hierarchy_call in pairs(result) do
          local child = tree.Node.new(
             call_hierarchy_call[direction].name,
             0, -- tree.add_node will set the depth correctly.
             call_hierarchy_call[direction],
             call_hierarchy_call[direction].kind,
             call_hierarchy_call.fromRanges
          )
          table.insert(children, child)
        end

        -- add the new root, its children, and rewrite the
        -- tree (will open the calltree ui if necessary).
        tree.add_node(root, children)
        M.write_tree({}, tree.root_node)
        vim.api.nvim_buf_set_name(M.buffer_handle, direction_map[direction].buf_name)
    end
end

local function set_jump_hl(node)
    M.last_highlighted_buffer = vim.api.nvim_get_current_buf()
    -- set highlght for function itself
    local range = node.call_hierarchy_obj.range
    vim.api.nvim_buf_add_highlight(
        M.last_highlighted_buffer,
        M.jump_higlight_ns,
        ct.config.symbol_hl,
        range["start"].line,
        range["start"].character,
        range["end"].character
    )
    -- apply it to all the references
    if node.references ~= nil then
        for _, ref in ipairs(node.references) do
            vim.api.nvim_buf_add_highlight(
                M.last_highlighted_buffer,
                M.jump_higlight_ns,
                ct.config.symbol_refs_hl,
                ref["start"].line,
                ref["start"].character,
                ref["end"].character
            )
        end
    end
end

-- jump will jump to the source code location of the
-- symbol under the cursor.
M.jump = function()
    M.clear_jump_hl()

    local line = vim.api.nvim_get_current_line()
    local node = M.decode_line_to_node(line)
    if node == nil then
        return
    end
    local location = {
        uri = node.call_hierarchy_obj.uri,
        range = node.call_hierarchy_obj.range
    }

    -- handle jump configuration
    if ct.config.jump_mode == "invoking" then
        if not vim.api.nvim_win_is_valid(M.invoking_win_handle) then
            -- invoking window is gone, split yourself and use
            -- that to jump as a fallback
            vim.cmd('botright vsplit')
            vim.cmd('wincmd l')
            M.invoking_win_handle = vim.api.nvim_get_current_win()
            goto jump
        end
        vim.api.nvim_set_current_win(M.invoking_win_handle)
        goto jump
    end

    if ct.config.jump_mode == "neighbor" then
        local cur_win = vim.api.nvim_get_current_win()
        if ct.config.layout == "left" then
            vim.cmd('wincmd l')
        else
            vim.cmd('wincmd h')
        end
        if cur_win == vim.api.nvim_get_current_win() then
            if ct.config.layout == "left" then
                vim.cmd("botright vsplit")
            else
                vim.cmd("topleft vsplit")
            end
        end
    end

    ::jump::
    vim.lsp.util.jump_to_location(location)
    set_jump_hl(node)
end

M.clear_jump_hl = function()
    if M.last_highlighted_buffer ~= nil then
        vim.api.nvim_buf_clear_namespace(
            M.last_highlighted_buffer,
            M.jump_higlight_ns,
            0,
            -1
        )
    end
end

-- hover will show LSP hover information for the symbol
-- under the cursor.
M.hover = function()
    local line = vim.api.nvim_get_current_line()
    local node = M.decode_line_to_node(line)
    if node == nil then
        return
    end
    local params = {
        textDocument = {
            uri = node.call_hierarchy_obj.uri
        },
        position = {
            line = node.call_hierarchy_obj.range.start.line,
            character = node.call_hierarchy_obj.range.start.character
        }
    }
    vim.lsp.buf_request(M.buffer_handle, "textDocument/hover", params)
end

-- ch_expand_handler is the call_hierarchy handler
-- when expanding an existing node in the calltree.
M.ch_expand_handler = function(node, linenr, direction)
    return function(err, result, _, _)
        if err ~= nil then
            vim.api.nvim_err_writeln(vim.inspect(err))
            return
        end
        if result == nil then
            -- rewrite the tree still to expand node giving ui
            -- feedback that further callers/callees exist
            M.write_tree({}, tree.root_node)
            vim.api.nvim_win_set_cursor(M.win_handle, linenr)
            return
        end

        local children = {}
        for _, call_hierarchy_call in pairs(result) do
            local child = tree.Node.new(
                call_hierarchy_call[direction].name,
                0, -- tree.add_node will compute depth for us
                call_hierarchy_call[direction],
                call_hierarchy_call[direction].kind,
                call_hierarchy_call.fromRanges
            )
            table.insert(children, child)
        end

        tree.add_node(node, children)

        M.write_tree({}, tree.root_node)
        vim.api.nvim_win_set_cursor(M.win_handle, linenr)
    end
end

return M
