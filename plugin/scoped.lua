-- Eagerly register the always-available commands so :ScopedApply / :ScopedEdit
-- / :ScopedAdd exist at startup even without an explicit setup() call.
-- Guarded so it only runs once.
if vim.g.loaded_scoped then
  return
end
vim.g.loaded_scoped = true

require("scoped")
