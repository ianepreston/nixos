-- Helper function to return python path

local M = {}
--- Resolve Python interpreter for current project
--- Prefers .venv/bin/python, falls back to system python3 or python
function M.get_python()
  local venv = vim.fn.getcwd() .. "/.venv/bin/python"
  if vim.fn.filereadable(venv) == 1 then
    return venv
  end
  return (vim.fn.exepath "python3" ~= "" and vim.fn.exepath "python3") or vim.fn.exepath "python"
end
return M
