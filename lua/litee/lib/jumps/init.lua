local config    = require('litee.lib.config').config
local lib_util  = require('litee.lib.util')
local lib_hi    = require('litee.lib.highlights')

local M = {}

-- the current highlight source, reset on jumps
M.jump_higlight_ns = vim.api.nvim_create_namespace("calltree-jump")
-- the buffer we highlighted last.
M.last_highlighted_buffer = nil

-- move_or_create will a attempt to move from the
-- calltree ui window to the nearest editor window
--
-- if the move fails, assumingly because no other window
-- exists, a new window will be created.
--
-- layout : string - the current configured layout.
-- returns
--   bool : whether a new window was created or not
local function move_or_create(orientation) 
    local cur_win = vim.api.nvim_get_current_win()
    if orientation == "left" then
        vim.cmd('wincmd l')
    elseif orientation == "right" then
        vim.cmd('wincmd h')
    elseif orientation == "top" then
        vim.cmd('wincmd j')
    elseif orientation == "bottom" then
        vim.cmd('wincmd k')
    end
    if cur_win == vim.api.nvim_get_current_win() then
        if orientation == "left" then
            vim.cmd("botright vsplit")
            return true
        elseif orientation == "right" then
            vim.cmd("topleft vsplit")
            return true
        elseif orientation == "top" then
            vim.cmd("topleft split")
            return true
        elseif orientation == "bottom" then
            vim.cmd("topleft split")
            return true
        end
    end
    return false
end

-- jump_tab will open a new tab then jump to the symbol
function M.jump_tab(location, node)
    M.set_jump_hl(false, nil)
    vim.cmd("tabedit " .. location.uri)
    vim.cmd("set nocursorline")
    vim.lsp.util.jump_to_location(location)
    M.set_jump_hl(true, node)
end

-- jump_split will open a new split then jump to the symbol
function M.jump_split(split, location, node)
    M.set_jump_hl(false, nil)
    if not move_or_create(config["panel"].orientation) then
        vim.cmd(split)
    end
    vim.lsp.util.jump_to_location(location)
    M.set_jump_hl(true, node)
end

-- jump_neighbor will jump to the symbol using the
-- closest left or right window.
--
-- a window will be created if it does not exist.
--
-- location : table - an LSP location object usable by
-- lsp.jump_to_location
--
-- layout : string - calltree's configured layout option
--
-- node : tree.Node - the node being highlighted
function M.jump_neighbor(location, node)
    M.set_jump_hl(false, nil)
    move_or_create(config["panel"].orientation)
    vim.lsp.util.jump_to_location(location)
    M.set_jump_hl(true, node)
end

-- jump_invoking will jump to the symbol using the
-- window that initially invoked the calltree.
--
-- a window is created and seen as the new invoking window
-- if the original invoking window has been closed.
--
-- location : table - an LSP location object usable by
-- lsp.jump_to_location
--
-- win_handle : window_handle - the previous invoking window
-- handle.
--
-- node : tree.Node - the node being highlighted
-- returns:
--  wind_handle : window_handle - a valid window_handle
--  for the invoking window.
function M.jump_invoking(location, win_handle, node)
    M.set_jump_hl(false, nil)
    if not vim.api.nvim_win_is_valid(win_handle) then
        if config["panel"].orientation == "left" then
            vim.cmd("botright vsplit")
        elseif config["panel"].orientation == "right" then
            vim.cmd("topleft vsplit")
        elseif config["panel"].orientation == "top" then
            vim.cmd("topleft split")
        elseif config["panel"].orientation == "bottom" then
            vim.cmd("topleft split")
        end
        win_handle = vim.api.nvim_get_current_win()
    end
    vim.api.nvim_set_current_win(win_handle)
    vim.lsp.util.jump_to_location(location)
    M.set_jump_hl(true, node)
    return win_handle
end

-- set_jump_hl will highlight the symbol and
-- any references to the symbol if set == true.
--
-- set : bool - if false highlights any previously created
-- jump highlights will be removed.
--
-- node : tree.Node - the node being highlighted
function M.set_jump_hl(set, node)
    if not set then
        if M.last_highlighted_buffer ~= nil then
            vim.api.nvim_buf_clear_namespace(
                M.last_highlighted_buffer,
                M.jump_higlight_ns,
                0,
                -1
            )
        end
        return
    end

    M.last_highlighted_buffer = vim.api.nvim_get_current_buf()

    -- set highlght for function itself
    local location = lib_util.resolve_location(node)
    if location == nil then
        return
    end
    local range = location.range

    vim.api.nvim_buf_add_highlight(
        M.last_highlighted_buffer,
        M.jump_higlight_ns,
        lib_hi.hls.SymbolJumpHL,
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
                lib_hi.hls.SymbolJumpRefsHL,
                ref["start"].line,
                ref["start"].character,
                ref["end"].character
            )
        end
    end
end

return M
