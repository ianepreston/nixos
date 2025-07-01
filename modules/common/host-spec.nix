{
  lib,
  config,
  ...
}:
{
  options.hostSpec = lib.mkOption {
    type = lib.types.attrs;
    description = "Host-specific configuration";
  };
}