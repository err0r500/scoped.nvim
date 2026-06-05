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
  markers = false, -- set true to mark scoped folders inside the nvim-tree
  marker_icon = "●", -- glyph shown next to a scoped folder ("" to omit the icon)
  marker_placement = "right_align", -- "before" | "after" | "right_align"
  marker_highlight = true, -- also tint the scoped folder name (ScopedMarkerName)
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

  -- Hoist cwd out of the per-node closure: the filter is rebuilt on every
  -- apply/refresh, so cwd is fresh, and we avoid a syscall per node.
  local cwd = vim.uv.cwd()
  return function(absolute_path)
    local rel = path_relative(absolute_path, cwd)
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

-- Absolute paths of the current scope roots, keyed for O(1) lookup. Built once
-- per render (see the decorator constructor) so the per-node check is a single
-- table lookup instead of an fnamemodify + cwd + list scan on every node — the
-- difference between snappy and sluggish on large trees. List entries are
-- cwd-relative and inside cwd (normalize() guarantees it), so cwd .. "/" .. rel
-- reconstructs exactly the node.absolute_path nvim-tree builds.
local function scoped_abs_set()
  local cwd = vim.uv.cwd()
  local set = {}
  for _, rel in ipairs(M._list) do
    set[cwd .. "/" .. rel] = true
  end
  return set
end

-- The scoped nvim-tree decorator class, built lazily once nvim-tree is loaded.
-- false once we've determined nvim-tree's Decorator API is unavailable; nil
-- until first checked. The class reads M.options / M._list live on each render.
local ScopedDecorator = nil
local function ensure_decorator()
  if ScopedDecorator ~= nil then return ScopedDecorator end
  local ok, api = pcall(require, "nvim-tree.api")
  if not ok or not api.Decorator then
    ScopedDecorator = false
    return false
  end
  -- Mirrors nvim-tree's builtin decorators: a separate highlight for the glyph
  -- (ScopedMarkerIcon, set in the icon's hl) and for the node name
  -- (ScopedMarkerName, applied when highlight_range is "name").
  local D = api.Decorator:extend()
  function D:new()
    self.enabled = true
    self.highlight_range = M.options.marker_highlight and "name" or "none"
    self.icon_placement = M.options.marker_icon ~= "" and M.options.marker_placement or "none"
    self._scoped = scoped_abs_set() -- snapshot the scope once, reused for every node
  end
  function D:icons(node)
    if M.options.marker_icon ~= "" and node and self._scoped[node.absolute_path] then
      return { { str = M.options.marker_icon, hl = { "ScopedMarkerIcon" } } }
    end
  end
  function D:highlight_group(node)
    if node and self._scoped[node.absolute_path] then return "ScopedMarkerName" end
  end
  ScopedDecorator = D
  return D
end

-- nvim-tree's shared, live decorator list (config.g.renderer.decorators), read
-- by the renderer on every build. Returns nil if nvim-tree is not configured.
local function decorators_list()
  local ok, cfg = pcall(require, "nvim-tree.config")
  if not ok or type(cfg.g) ~= "table" or type(cfg.g.renderer) ~= "table" then
    return nil
  end
  cfg.g.renderer.decorators = cfg.g.renderer.decorators or {}
  return cfg.g.renderer.decorators
end

-- Append the scoped decorator to nvim-tree's decorator list if absent. Returns
-- true only when it was actually inserted (so callers can reload just once).
function M._enable_markers()
  local D = ensure_decorator()
  local list = D and decorators_list()
  if not D or not list then return false end
  for _, d in ipairs(list) do
    if d == D then return false end
  end
  table.insert(list, D) -- additive: drawn over the builtin decorators
  return true
end

-- Re-render the tree so marker changes show. No-op unless markers are enabled
-- (apply/revert already reload, so this covers list edits while displayed).
function M._refresh_markers()
  if not M.options.markers then return end
  local ok, api = pcall(require, "nvim-tree.api")
  if ok then pcall(api.tree.reload) end
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
  M._refresh_markers()
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
  M._refresh_markers()
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
      M._refresh_markers()
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

-- Default marker highlights, following nvim-tree's Icon/Name split convention.
-- Linked to base groups so they track the colorscheme; `default = true` means a
-- user-defined group of the same name wins, so both are fully overridable
-- (e.g. link them to an NvimTree* group if you prefer).
local function define_marker_highlights()
  vim.api.nvim_set_hl(0, "ScopedMarkerIcon", { link = "Special", default = true })
  vim.api.nvim_set_hl(0, "ScopedMarkerName", { link = "Special", default = true })
end

-- Wire up the in-tree markers: define the highlight, register the decorator with
-- nvim-tree, and re-register whenever a tree opens (handles scoped.setup running
-- before nvim-tree.setup, or the tree opening later). Only the run that actually
-- inserts the decorator triggers a reload.
local function setup_markers()
  define_marker_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { callback = define_marker_highlights })
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "NvimTree",
    callback = function()
      if M._enable_markers() then
        local ok, api = pcall(require, "nvim-tree.api")
        if ok then pcall(api.tree.reload) end
      end
    end,
  })
  M._enable_markers() -- best-effort immediate, if nvim-tree is already configured
end

-- Entry point for plugin managers. Safe to call zero or one time.
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.options, opts or {})
  register_commands()
  if M.options.default_keymaps then
    setup_default_keymaps()
  end
  if M.options.markers then
    setup_markers()
  end
  return M
end

-- Register the command eagerly too, so `require("scoped")` without setup()
-- still exposes :Scoped (matches the original side-effect-on-require
-- behaviour).
register_commands()

return M
