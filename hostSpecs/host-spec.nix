# Specifications For Differentiating Hosts
{
  lib,
  ...
}:
{
  options.hostSpecs = lib.mkOption {
    description = "AttrSet of Host Configuration Options";
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          # Data variables that don't dictate configuration settings
          hostName = lib.mkOption {
            type = lib.types.str;
            description = "The hostname of the host";
          };
          username = lib.mkOption {
            type = lib.types.str;
            description = "The username of the host";
            default = "ipreston";
          };
          home = lib.mkOption {
            type = lib.types.str;
            description = "The home directory of the user";
            default = "/home/ipreston";
          };
          # Configuration Settings
          email = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            description = "The email of the user";
          };
          userFullName = lib.mkOption {
            type = lib.types.str;
            description = "The full name of the user";
            default = "Ian Preston";
          };
          gh_user = lib.mkOption {
            type = lib.types.str;
            description = "GitHub Username";
            default = "ianepreston";
          };
          isMinimal = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Used to indicate a minimal host";
          };
          isMobile = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Used to indicate a laptop or similar host";
          };
          isWork = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Used to indicate a host that uses work resources";
          };
          # Sometimes we can't use pkgs.stdenv.isLinux due to infinite recursion
          isDarwin = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Used to indicate a host that is darwin";
          };
        };
      }
    );
  };
}
