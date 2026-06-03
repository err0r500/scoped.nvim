# scoped.nvim

Restrict [nvim-tree](https://github.com/nvim-tree/nvim-tree.lua) — and
optionally [Telescope](https://github.com/nvim-telescope/telescope.nvim) — to a
whitelist of folders. Useful in large monorepos where you only want to see and
search the handful of directories you're actually working in.

Maintain a per-project list of "allowed" folders. When a scope is active:

- the nvim-tree explorer hides everything outside the allowed folders (ancestor
  folders on the path to an allowed folder stay visible so you can navigate to
  them);
- `:ScopedFind` / `:ScopedGrep` run Telescope `find_files` / `live_grep`
  restricted to those folders.

The list is editable as a plain buffer (`:ScopedEdit`), or built up
interactively by toggling nodes in the tree.

## Requirements

- Neovim 0.9+
- [nvim-tree.lua](https://github.com/nvim-tree/nvim-tree.lua) (required)
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) (optional —
  enables `:ScopedFind` / `:ScopedGrep`)

> **Note:** the nvim-tree filter is implemented against nvim-tree's explorer
> internals (`nvim-tree.core`, `explorer.filters`). It is tested against current
> nvim-tree; a major nvim-tree refactor may require an update here.

## Installation

### lazy.nvim

```lua
{
  "<your-username>/scoped.nvim",
  dependencies = { "nvim-tree/nvim-tree.lua" }, -- + telescope.nvim if you want :ScopedFind/:ScopedGrep
  opts = {
    default_keymaps = true, -- optional: bind <leader>s and <C-\> in the tree
  },
}
```

### packer.nvim

```lua
use({
  "<your-username>/scoped.nvim",
  requires = { "nvim-tree/nvim-tree.lua" },
  config = function()
    require("scoped").setup({ default_keymaps = true })
  end,
})
```

`setup()` is optional. The commands below are registered at startup either way;
`setup()` only matters if you want the bundled `default_keymaps`.

## Commands

| Command        | Description                                              |
| -------------- | -------------------------------------------------------- |
| `:ScopedEdit`  | Open the editable scope-list buffer (one path per line)  |
| `:ScopedAdd`   | Add a path (defaults to the current file) to the list    |
| `:ScopedApply` | Apply the current list (filter tree + register commands) |
| `:ScopedClear` | Remove the scope (only exists while a scope is active)   |
| `:ScopedFind`  | Telescope `find_files` scoped to allowed folders         |
| `:ScopedGrep`  | Telescope `live_grep` scoped to allowed folders          |

## Usage

### Declare a scope from your project config

Drop something like this in a per-project `.nvim.lua` / `exrc` file:

```lua
require("scoped").apply({ "lua/config", "after" })
```

### Build a scope interactively

1. `:ScopedEdit` to open the list buffer, type folder paths (cwd-relative, one
   per line), and `:w` to commit.
2. Or, with `default_keymaps`, hover a node in nvim-tree and press `<C-\>` to
   toggle it in the list.
3. `:ScopedApply` (or `<leader>s`) to apply.

### Toggle on/off

`require("scoped").toggle_scope()` (bound to `<leader>s` under
`default_keymaps`) applies the current list if no scope is active, or clears the
active scope otherwise.

## Default keymaps

Enabled only when you pass `default_keymaps = true`:

| Key        | Mode / context  | Action                                  |
| ---------- | --------------- | --------------------------------------- |
| `<leader>s`| normal          | `toggle_scope` (apply current / clear)  |
| `<C-\>`    | nvim-tree node  | toggle the node under cursor in the list|

Prefer to roll your own? Skip `default_keymaps` and map the public functions:

```lua
local scoped = require("scoped")
vim.keymap.set("n", "<leader>ss", scoped.toggle_scope)
vim.keymap.set("n", "<leader>se", scoped.open_buffer)
```

## Lua API

```lua
local scoped = require("scoped")

scoped.apply({ "src", "tests" }) -- apply a scope directly
scoped.revert()                  -- remove the active scope
scoped.toggle_scope()            -- apply current list / clear
scoped.add(path)                 -- add a path to the list
scoped.remove(path)              -- remove a path from the list
scoped.toggle(path)              -- add if absent, remove if present
scoped.list()                    -- copy of the current list
scoped.open_buffer()             -- open the editable list buffer
```

Paths are normalized to cwd-relative, forward-slash form; paths outside the cwd
are rejected.

## License

MIT
