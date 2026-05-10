# Specifications For Differentiating Hosts
{
  lib,
  ...
}:
{
  options.hostSpecs = lib.mkOption {
    description = "AttrSet of Host Configuration Options";
    type = lib.types.attrsOf (
      lib.types.submodule (
        { config, ... }:
        {
          options = {
            # Data variables that don't dictate configuration settings
            hostName = lib.mkOption {
              type = lib.types.str;
              description = "The hostname of the host";
            };
            hostNameFile = lib.mkOption {
              type = lib.types.str;
              description = "The filename for host specific configs";
              default = config.hostName;
            };
            username = lib.mkOption {
              type = lib.types.str;
              description = "The username of the host";
              default = "ipreston";
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
            serverEnvironment = lib.mkOption {
              type = lib.types.nullOr (
                lib.types.enum [
                  "dev"
                  "prod"
                ]
              );
              default = null;
              description = "Server environment: \"dev\" => server-dev (1029), \"prod\" => server-prod (1030). null on non-server hosts.";
            };
            serverDomain = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Base domain under which this host exposes apps (e.g. \"dnix.ipreston.net\"). Apps compose \"<app>.\${serverDomain}\". null on non-server hosts.";
            };
            serverLanIp = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Static LAN IPv4 address for this server. Used by apps that need to advertise an L3 address other clients on the same subnet can reach (e.g. UniFi OS Server's inform URL). null on non-server hosts.";
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
            home = lib.mkOption {
              type = lib.types.str;
              description = "The home directory of the user";
              default = if config.isDarwin then "/Users/${config.username}" else "/home/${config.username}";
            };
          };
        }
      )
    );
  };
}
