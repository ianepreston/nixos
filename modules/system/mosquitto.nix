# Mosquitto - MQTT broker for the IoT message bus
# Single shared broker on each server. App modules contribute users
# (creds + ACLs) via `myMosquitto.users.<name>`, mirroring the
# myPostgresApp / myAuthentik.oidcApps aggregator pattern:
#
#   myMosquitto.users.homeassistant = {
#     acl = [ "readwrite #" ];          # HA bridges every topic
#   };
#   myMosquitto.users.hoymiles = {
#     acl = [ "readwrite hoymiles/#" ];
#   };
#
# Each user gets a sops secret at "<name>/mqtt_password" provisioned
# automatically (`task secrets:secret APP=<name> KEY=mqtt_password`).
# The upstream mosquitto module wraps each user's passwordFile through
# `mosquitto_passwd -U` at activation so the on-disk passwd file is
# hashed; sops just supplies the cleartext.
#
# Network exposure: bind to 0.0.0.0:1883 with no firewall openings.
# The host firewall blocks the port on every external NIC; podman0 is
# in trustedInterfaces (see oci-containers.nix), so containers on the
# default bridge reach the broker via 10.88.0.1:1883 — same model as
# postgres/mariadb. Apps on macvlan networks (vlan30) keep their
# default-bridge NIC so this bridge route still applies. For ad-hoc
# debugging, ssh into the broker host and use 127.0.0.1:1883. No
# public Caddy route — MQTT is not an HTTP service.
_: {
  flake.modules.nixos.mosquitto =
    {
      config,
      hostSpec,
      lib,
      ...
    }:
    let
      apps = config.myMosquitto.users;
    in
    {
      options.myMosquitto.users = lib.mkOption {
        default = { };
        description = ''
          Mosquitto users contributed by app modules. Each entry
          provisions a sops secret for the user's password and renders
          a username/ACL pair onto the single shared listener.
        '';
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, ... }:
            {
              options = {
                acl = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  description = ''
                    Mosquitto ACL strings for this user (e.g.
                    `"readwrite hoymiles/#"`). Empty list grants the
                    user no topics — equivalent to disabling them.
                  '';
                  example = [ "readwrite hoymiles/#" ];
                };
                secretName = lib.mkOption {
                  type = lib.types.str;
                  default = "${name}/mqtt_password";
                  description = ''
                    sops secret name for this user's password.
                    Defaults to "<name>/mqtt_password".
                  '';
                };
                username = lib.mkOption {
                  type = lib.types.str;
                  default = name;
                  description = ''
                    MQTT username. Defaults to the attribute name.
                  '';
                };
              };
            }
          )
        );
      };

      config = lib.mkIf (apps != { }) {
        services.mosquitto = {
          enable = true;
          listeners = [
            {
              port = 1883;
              # 0.0.0.0 — host firewall + tailscale0 / podman0 trust
              # gates the actual surface (see top-of-file comment).
              address = null;
              users = lib.mapAttrs' (
                _name: app:
                lib.nameValuePair app.username {
                  passwordFile = config.sops.secrets.${app.secretName}.path;
                  inherit (app) acl;
                }
              ) apps;
            }
          ];
        };

        sops.secrets = lib.mapAttrs' (
          _name: app:
          lib.nameValuePair app.secretName {
            inherit (hostSpec) sopsFile;
            # mosquitto reads the file through systemd LoadCredential at
            # activation, then re-runs mosquitto_passwd -U on the merged
            # file. Owner=mosquitto so the LoadCredential read succeeds.
            owner = "mosquitto";
            restartUnits = [ "mosquitto.service" ];
          }
        ) apps;

        # /var/lib/mosquitto/mosquitto.db is the broker's persistent
        # session/subscription/retained-message store (binary BTree, not
        # sqlite — no quiesce hook needed). Preserve on impermanence;
        # back up with the rest of the server state.
        preservation.preserveAt."/persist".directories = [
          {
            directory = "/var/lib/mosquitto";
            user = "mosquitto";
            group = "mosquitto";
            mode = "0700";
          }
        ];

        services.restic.backups.server.paths = [ "/var/lib/mosquitto" ];
      };
    };
}
