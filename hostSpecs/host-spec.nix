# Specifications For Differentiating Hosts
{
  inputs,
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
            iotTrunkInterface = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Name of the physical NIC that carries the tagged IoT VLAN (vlan30) for Home Assistant's macvlan child. Host-specific because predictable interface names depend on PCI topology. null on hosts that don't run HA, or that run HA without IoT VLAN access (e.g. test VMs).";
            };
            bambuddyVpMac = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Pinned MAC for bambuddy's Virtual Printer macvlan leg on vlan30. podman assigns a fresh random MAC on every container re-creation, which re-rolls the DHCP lease and drifts the VP's IP — breaking the proxy's bind and the slicer's by-IP device entry. Pinning the MAC (paired with a DHCP reservation matching bambuddyVpIp) keeps the dedicated address stable, which bambuddy requires. null on hosts that don't run bambuddy with IoT access.";
            };
            bambuddyVpIp = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "The DHCP-reserved vlan30 address bambuddy's Virtual Printer binds (reserved against bambuddyVpMac on the router). bambuddy requires a dedicated, stable IP per VP for all services (MQTT/FTP/SSDP/Bind); this is the single source for it — set the VP Bind IP and the slicer's printer IP to this. null on hosts that don't run bambuddy with IoT access.";
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
            sopsFile = lib.mkOption {
              type = lib.types.path;
              description = "Path to the per-host sops YAML file in the nix-secrets repo.";
              default = "${inputs.nix-secrets}/sops/${config.hostName}.yaml";
              defaultText = lib.literalExpression "\"\${inputs.nix-secrets}/sops/\${config.hostName}.yaml\"";
            };
          };
        }
      )
    );
  };
}
