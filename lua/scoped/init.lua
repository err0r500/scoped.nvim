-- scoped.nvim: restrict nvim-tree (and optionally Telescope) to a whitelist of folders.
--
-- Per-project config declares only the `allowed` list and calls:
--   require("scoped").apply({ "lua/config", "after" })
-- Revert with require("scoped").revert() or the :Scoped clear command.
--
-- The module is require()-able from any project regardless of cwd as long as
-- it is on the runtimepath.

local M = {}

M._list = {} -- canonical cwd-relative paths, order-preserving
M._bufnr = nil -- scope-list buffer handle, or nil
M._active = false -- whether the scope filter is currently applied
local BUF_NAME = "scoped://list"

-- User-facing options, populated by setup(). Defaults are inert so the plugin
-- works with zero configuration.
M.options = {
  default_keymaps = false, -- set true to bind <leader>s / :ScopedEdit helpers
}

-- abs-or-relative -> cwd-relative, forward-slash, no trailing slash; relative to
-- cwd. Self-contained (no nvim-tree internals) so it survives nvim-tree upgrades.
local function path_relative(path, base)
  local abs = vim.fn.fnamemodify(path, ":p"):gsub("/+$", "")
  base = base:gsub("/+$", "")
  if abs == base then return "." end
  if abs:sub(1, #base + 1) == base .. "/" then
    return abs:sub(#base + 2)
  end
  return abs -- outside base: hand back the absolute path
end

-- abs-or-relative -> cwd-relative, forward-slash, no trailing slash; nil if outside cwd
local function normalize(path)
  if not path or path == "" then return nil end
  local rel = path_relative(path, vim.uv.cwd())
  rel = rel:gsub("\\", "/"):gsub("/+$", "")
  if rel == "" or rel == "." then return nil end
  if rel:sub(1, 1) == "/" then return nil end -- absolute => outside cwd
  return rel
end

local function index_of(path)
  for i, p in ipairs(M._list) do
    if p == path then return i end
  end
end

-- Build an nvim-tree custom filter (returns true to HIDE a node) that keeps a
-- node only when it is inside an allowed prefix, or is an ancestor folder on
-- the path leading to one (so e.g. `lua` stays visible to reach `lua/config`).
local function build_filter(allowed)
  local function keep(rel)
    rel = rel:gsub("\\", "/"):gsub("/+$", "")
    for _, p in ipairs(allowed) do
      if rel == p or rel:sub(1, #p + 1) == p .. "/" then
        return true -- inside an allowed folder
      end
      if p:sub(1, #rel + 1) == rel .. "/" then
        return true -- ancestor on the path to an allowed folder
      end
    end
    return false
  end

  return function(absolute_path)
    local rel = path_relative(absolute_path, vim.uv.cwd())
    return not keep(rel)
  end
end

-- Absolute paths of the allowed folders, relative to the current cwd.
local function scoped_dirs(allowed)
  local cwd = vim.fn.getcwd()
  local dirs = {}
  for _, p in ipairs(allowed) do
    table.insert(dirs, cwd .. "/" .. p)
  end
  return dirs
end

local function has_telescope()
  return pcall(require, "telescope.builtin")
end

-- A copy of the current list.
function M.list()
  return vim.deepcopy(M._list)
end

-- Render M._list into the scope-list buffer, if it is loaded and unmodified
-- (never stomp an in-progress hand edit).
function M._render()
  if not (M._bufnr and vim.api.nvim_buf_is_loaded(M._bufnr)) then return end
  if vim.bo[M._bufnr].modified then return end
  vim.bo[M._bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(M._bufnr, 0, -1, false, vim.deepcopy(M._list))
  vim.bo[M._bufnr].modified = false
end

-- If a scope is active, rebuild the tree filter from the current list and
-- reload, so list edits take effect without a manual re-apply. No-op when no
-- scope is applied. If the list is now empty there is nothing to scope to, so
-- revert instead of hiding the whole tree.
function M._refresh()
  if not M._active then return end
  if #M._list == 0 then
    M.revert()
    return
  end
  local ok_core, core = pcall(require, "nvim-tree.core")
  local explorer = ok_core and core.get_explorer()
  if not explorer then return end
  explorer.filters.custom_function = build_filter(M._list)
  require("nvim-tree.api").tree.reload()
end

function M.add(path)
  local rel = normalize(path)
  if not rel or index_of(rel) then return false end
  table.insert(M._list, rel)
  M._render()
  return true
end

function M.remove(path)
  local rel = normalize(path)
  if not rel then return false end
  local i = index_of(rel)
  if not i then return false end
  table.remove(M._list, i)
  M._render()
  M._refresh() -- auto-update the live tree when removing from an active scope
  return true
end

-- Add the path if absent, remove it if present. Entry point for the tree key.
function M.toggle(path)
  local rel = normalize(path)
  if not rel then
    vim.notify("scoped: path not under cwd", vim.log.levels.WARN)
    return
  end
  if index_of(rel) then
    M.remove(rel)
    vim.notify("scoped: removed " .. rel)
  else
    M.add(rel)
    vim.notify("scoped: added " .. rel)
  end
end

local function create_buffer()
  local buf = vim.api.nvim_create_buf(true, false) -- listed, not scratch
  vim.api.nvim_buf_set_name(buf, BUF_NAME)
  vim.bo[buf].buftype = "acwrite" -- ":w" fires BufWriteCmd, never touches disk
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "scoped"

  -- Commit buffer -> M._list on :w (normalize + dedup each line).
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      local seen, new = {}, {}
      for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        local rel = normalize(line)
        if rel and not seen[rel] then
          seen[rel] = true
          table.insert(new, rel)
        end
      end
      M._list = new
      vim.bo[buf].modified = false
      vim.notify("scoped: list saved (" .. #new .. " paths)")
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function() M._bufnr = nil end,
  })

  return buf
end

-- Open (creating if needed) the editable scope-list buffer in a vertical split.
function M.open_buffer()
  if not (M._bufnr and vim.api.nvim_buf_is_loaded(M._bufnr)) then
    M._bufnr = create_buffer()
  end
  vim.bo[M._bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(M._bufnr, 0, -1, false, vim.deepcopy(M._list))
  vim.bo[M._bufnr].modified = false
  vim.cmd("vsplit")
  vim.api.nvim_win_set_buf(0, M._bufnr)
end

-- Apply the current list. Commits pending buffer edits first so the applied
-- scope matches what is on screen.
function M.apply_current()
  if M._bufnr and vim.api.nvim_buf_is_loaded(M._bufnr) and vim.bo[M._bufnr].modified then
    vim.api.nvim_buf_call(M._bufnr, function() vim.cmd("silent write") end)
  end
  if #M._list == 0 then
    vim.notify("scoped: list is empty, nothing to apply", vim.log.levels.WARN)
    return
  end
  M.apply(M._list)
end

-- Apply the scope: filter the nvim-tree explorer and (if Telescope is present)
-- register the scoped Telescope commands (:ScopedFind / :ScopedGrep), plus
-- :ScopedClear.
function M.apply(allowed)
  -- Seed canonical state from whatever is applied (so direct apply({...}) calls
  -- also populate the editable list), normalized + deduped.
  local seen, norm = {}, {}
  for _, p in ipairs(allowed) do
    local rel = normalize(p)
    if rel and not seen[rel] then
      seen[rel] = true
      table.insert(norm, rel)
    end
  end
  M._list = norm
  allowed = norm
  M._render()

  local ok_core, core = pcall(require, "nvim-tree.core")
  if not ok_core then
    vim.notify("scoped: nvim-tree is required to apply a scope", vim.log.levels.ERROR)
    return
  end

  local api = require("nvim-tree.api")
  api.tree.open()

  local explorer = core.get_explorer()
  if not explorer then
    vim.notify("scoped: NvimTree explorer not available", vim.log.levels.WARN)
    return
  end

  explorer.filters.custom_function = build_filter(allowed)
  explorer.filters.state.custom = true
  explorer.filters.enabled = true
  api.tree.reload()

  M._active = true
  vim.notify("scoped applied: " .. table.concat(allowed, ", "))
end

-- Remove the tree filter and the scoped commands.
function M.revert()
  local ok_core, core = pcall(require, "nvim-tree.core")
  local explorer = ok_core and core.get_explorer()
  if explorer then
    explorer.filters.custom_function = nil
    require("nvim-tree.api").tree.reload()
  end
  M._active = false
  vim.notify("scoped reverted")
end

-- Toggle the active scope: clear it if active, otherwise apply the current list.
function M.toggle_scope()
  if M._active then
    M.revert()
  else
    M.apply_current()
  end
end

-- Subcommands dispatched by the single :Scoped command. Each entry has a `run`
-- handler (receives the remaining args as a list) and an optional `complete`
-- mode for completing its arguments. Keep the table sorted for tidy completion.
local subcommands = {
  add = {
    run = function(args)
      M.add(args[1] and args[1] ~= "" and args[1] or vim.fn.expand("%"))
    end,
    complete = "file",
  },
  apply = {
    run = function() M.apply_current() end,
  },
  clear = {
    run = function() M.revert() end,
  },
  edit = {
    run = function() M.open_buffer() end,
  },
  find = {
    run = function()
      if not has_telescope() then
        vim.notify("scoped: telescope is not available", vim.log.levels.WARN)
        return
      end
      if #M._list == 0 then
        vim.notify("scoped: list is empty, nothing to search", vim.log.levels.WARN)
        return
      end
      require("telescope.builtin").find_files({ search_dirs = scoped_dirs(M._list) })
    end,
  },
  grep = {
    run = function()
      if not has_telescope() then
        vim.notify("scoped: telescope is not available", vim.log.levels.WARN)
        return
      end
      if #M._list == 0 then
        vim.notify("scoped: list is empty, nothing to search", vim.log.levels.WARN)
        return
      end
      require("telescope.builtin").live_grep({ search_dirs = scoped_dirs(M._list) })
    end,
  },
  remove = {
    run = function(args)
      M.remove(args[1] and args[1] ~= "" and args[1] or vim.fn.expand("%"))
    end,
    complete = "file",
  },
}

-- Sorted subcommand names, for completion and error messages.
local function subcommand_names()
  local names = vim.tbl_keys(subcommands)
  table.sort(names)
  return names
end

-- Register the single always-available :Scoped command (works before any
-- apply). Idempotent.
local function register_commands()
  vim.api.nvim_create_user_command("Scoped", function(o)
    local args = vim.deepcopy(o.fargs)
    local name = table.remove(args, 1)
    local sub = name and subcommands[name]
    if not sub then
      vim.notify(
        "scoped: unknown subcommand '" .. (name or "") .. "'\navailable: " ..
          table.concat(subcommand_names(), ", "),
        vim.log.levels.ERROR
      )
      return
    end
    sub.run(args)
  end, {
    nargs = "*",
    desc = "scoped.nvim: add/remove/apply/clear/edit/find/grep",
    complete = function(arglead, cmdline)
      -- Tokens so far (drop the leading "Scoped"); a trailing space yields an
      -- empty final token, which means "completing a fresh argument".
      local tokens = vim.split(vim.trim(cmdline), "%s+")
      table.remove(tokens, 1)
      local completing_subcommand = #tokens == 0
        or (#tokens == 1 and not cmdline:match("%s$"))
      if completing_subcommand then
        return vim.tbl_filter(function(n)
          return n:sub(1, #arglead) == arglead
        end, subcommand_names())
      end
      local sub = subcommands[tokens[1]]
      if sub and sub.complete == "file" then
        return vim.fn.getcompletion(arglead, "file")
      end
      return {}
    end,
  })
end

-- Optional convenience keymaps, off by default. Mirrors a sensible setup; users
-- are free to bind the public functions however they like instead.
local function setup_default_keymaps()
  vim.keymap.set("n", "<leader>s", M.toggle_scope, { desc = "Toggle scope (apply current list / clear)" })

  vim.api.nvim_create_autocmd("FileType", {
    pattern = "NvimTree",
    callback = function()
      vim.keymap.set("n", "<C-\\>", function()
        local node = require("nvim-tree.api").tree.get_node_under_cursor()
        if not node or not node.absolute_path then return end
        M.toggle(node.absolute_path)
      end, { buffer = true, desc = "Toggle node in scoped list" })
    end,
  })
end

-- Entry point for plugin managers. Safe to call zero or one time.
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.options, opts or {})
  register_commands()
  if M.options.default_keymaps then
    setup_default_keymaps()
  end
  return M
end

-- Register the command eagerly too, so `require("scoped")` without setup()
-- still exposes :Scoped (matches the original side-effect-on-require
-- behaviour).
register_commands()

return M
