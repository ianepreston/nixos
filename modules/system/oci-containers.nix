# OCI containers - Simple Aspect
# Podman backend for virtualisation.oci-containers. Backend-agnostic
# container declarations live in their own service modules.
#
# `myContainerApp.<name>` is the container analogue of `myCaddy.apps`
# (see caddy.nix): app modules declare the low-level plumbing that every
# containerized app repeats — the /var/lib/containers/<app> tmpfiles
# rules, the 127.0.0.1 host-port bind, the runtime user identity, and
# the TZ env — as a one-attr declaration here, and this module emits the
# corresponding `systemd.tmpfiles.rules` + `oci-containers.containers.*`
# fragments. App modules keep only what's genuinely app-specific (image,
# volumes, extra env). The `my`-prefix marks an option owned by this
# flake (vs upstream `virtualisation.*`).
_: {
  flake.modules.nixos.oci-containers =
    {
      config,
      hostSpec,
      lib,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
    in
    {
      options.myContainerApp = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, config, ... }:
            {
              options = {
                port = lib.mkOption {
                  type = lib.types.nullOr lib.types.port;
                  default = null;
                  description = ''
                    Host port to publish on 127.0.0.1. Left null for apps that
                    don't publish a host port at all (e.g. valheim, which uses
                    `--network=host` and opens UDP game ports on the firewall
                    directly) — no `ports` entry is emitted in that case.
                  '';
                };
                containerPort = lib.mkOption {
                  type = lib.types.nullOr lib.types.port;
                  default = config.port;
                  defaultText = lib.literalExpression "config.port";
                  description = "Port the app listens on inside the container. Defaults to `port`.";
                };
                stateDirs = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ "/var/lib/containers/${name}" ];
                  defaultText = lib.literalExpression ''[ "/var/lib/containers/''${name}" ]'';
                  description = ''
                    Host directories to create (0750, owned by stateDirOwner:stateDirGroup)
                    for this container's persistent state. Multi-subdir apps list every
                    subdir they bind-mount.
                  '';
                };
                stateDirOwner = lib.mkOption {
                  type = lib.types.str;
                  default = toString serverUid;
                  defaultText = lib.literalExpression "toString serverUid";
                  description = "Owner for the stateDirs tmpfiles rules. Defaults to the server user's uid.";
                };
                stateDirGroup = lib.mkOption {
                  type = lib.types.str;
                  default = toString serverGid;
                  defaultText = lib.literalExpression "toString serverGid";
                  description = "Group for the stateDirs tmpfiles rules. Defaults to the servers gid.";
                };
                tzEnv = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Emit `TZ = config.time.timeZone` in the container environment.";
                };
                manageUser = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = ''
                    Whether this module sets the container's runtime user identity.
                    Set false for images that take their uid/gid via app-specific env
                    vars the module doesn't model (e.g. grimmory's USER_ID/GROUP_ID) —
                    the app module then sets those itself.
                  '';
                };
                linuxServer = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = ''
                    Emit PUID/PGID env (server uid/gid) instead of a container
                    `user =` override, for images that start as root and drop
                    privileges themselves (linuxserver.io-style entrypoints).
                    Only meaningful when `manageUser` is true.
                  '';
                };
              };
            }
          )
        );
        default = { };
        description = ''
          Containerized apps' shared plumbing: per-app state dirs, the
          127.0.0.1 host-port bind, runtime user identity, and TZ. Mirrors
          `myCaddy.apps` — one declaration per app, emitted into
          `systemd.tmpfiles.rules` and `virtualisation.oci-containers.containers`.
        '';
      };

      config = {
        virtualisation = {
          podman = {
            enable = true;
            dockerCompat = true;
            defaultNetwork.settings.dns_enabled = true;
          };
          oci-containers.backend = "podman";

          # Per-app container fragments contributed via `myContainerApp.<name>`.
          # Each entry merges with the app module's own container definition
          # (image, volumes, extra env), which stays in the app module.
          oci-containers.containers = lib.mapAttrs (
            _: app:
            lib.mkMerge [
              (lib.optionalAttrs (app.port != null) {
                ports = [ "127.0.0.1:${toString app.port}:${toString app.containerPort}" ];
              })
              (lib.optionalAttrs (app.manageUser && app.linuxServer) {
                environment = {
                  PUID = toString serverUid;
                  PGID = toString serverGid;
                };
              })
              (lib.optionalAttrs (app.manageUser && !app.linuxServer) {
                user = "${toString serverUid}:${toString serverGid}";
              })
              (lib.optionalAttrs app.tzEnv {
                environment.TZ = config.time.timeZone;
              })
            ]
          ) config.myContainerApp;
        };

        # Containers on the default podman bridge reach host services
        # (postgres, etc.) via host.containers.internal -> 10.88.0.1.
        # Trust the bridge so the firewall doesn't drop those packets.
        networking.firewall.trustedInterfaces = [ "podman0" ];
        # Podman isn't allowed to forward packets from podman0 to the actual NIC by default
        boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
        boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;

        # Parent directory for all containerized app state. Apps create their
        # own subdirs (/var/lib/containers/<app>) owned by the server user,
        # which lets a single backup path cover every app automatically.
        # Per-app subdirs come from `myContainerApp.<name>.stateDirs`.
        systemd.tmpfiles.rules = [
          "d /var/lib/containers 0755 root root -"
        ]
        ++ lib.concatLists (
          lib.mapAttrsToList (
            _: app: map (dir: "d ${dir} 0750 ${app.stateDirOwner} ${app.stateDirGroup} -") app.stateDirs
          ) config.myContainerApp
        );
      };
    };
}
