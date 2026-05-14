local M = {
  symbol = "│",
  options = { try_as_border = true },
  draw = {
    delay = 0,
    animation = function()
      return 0
    end,
  },
}
return M
