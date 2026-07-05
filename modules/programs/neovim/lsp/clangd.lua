-- Note for C/C++: for complex projects like the Linux kernel, clangd relies on a
-- "JSON compilation database". Use https://github.com/rizsotto/Bear to "wrap" the
-- build process and autogenerate compile_commands.json.
local opts = {
  cmd = {
    "clangd",
    "--offset-encoding=utf-16",
  },
}

return opts
