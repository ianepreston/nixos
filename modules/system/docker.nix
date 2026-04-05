# Docker - Simple Aspect
# Docker rootless mode
_: {
  flake.modules.nixos.docker =
    { hostSpec, ... }:
    {
      virtualisation.docker = {
        enable = true;
        rootless = {
          enable = true;
          setSocketVariable = true;
        };
      };
      users.users.${hostSpec.username}.extraGroups = [ "docker" ];
    };
}
