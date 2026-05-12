# Valheim - dedicated server (lloesche/valheim-server container).
# Gameplay is UDP and there's no web UI to put behind Caddy/Authentik,
# so the exposed surface is just the three game UDP ports. They're
# open on every interface (LAN + tailscale0) — joining over LAN is
# the path used from machines without tailscale. The host sits behind
# the home router's NAT, so WAN reachability isn't part of the
# threat model. If hpp-1 ever moves to a routable address, tighten
# this to `networking.firewall.interfaces.<lan>.allowedUDPPortRanges`
# + the tailscale0 rule.
#
# World state and lloesche's automatic world backups (every 2h by
# default into /config/backups inside the container) live under
# /var/lib/containers/valheim/config, which the daily restic snapshot
# in modules/system/server-backups.nix picks up automatically. The
# Steam install of the game itself lives under
# /var/lib/containers/valheim/cache so it lands inside the existing
# `/var/lib/containers/*/cache` restic exclude — it's ~1.5 GB and the
# image re-downloads it on next start if missing.
#
# `--network=host` so the host firewall (INPUT chain) is the real gate
# on the game ports rather than relying on podman's DNAT/FORWARD
# behaviour. UDP > 1024, so the remapped PUID user can bind without
# CAP_NET_BIND_SERVICE.
#
# Adding mods later (BepInEx / Valheim+ / Jotunn):
# Set `BEPINEX = "true"` in the `environment` block below; on next
# start the image installs BepInEx into /config/bepinex. Drop mod
# DLLs into /var/lib/containers/valheim/config/bepinex/plugins/ and
# restart `podman-valheim.service`. Server-side-only mods just need
# the DLL; client-affecting mods need every player to install the
# same mod locally. See
# https://github.com/lloesche/valheim-server-docker#bepinex.
{ inputs, ... }:
let
  sopsFolder = (builtins.toString inputs.nix-secrets) + "/sops";
in
{
  flake.modules.nixos.valheim =
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
      gamePort = 2456;
    in
    {
      sops.secrets."valheim/server_password" = {
        sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
        restartUnits = [ "podman-valheim.service" ];
      };

      sops.templates."valheim.env".content = ''
        SERVER_PASS=${config.sops.placeholder."valheim/server_password"}
      '';

      systemd.tmpfiles.rules = [
        "d /var/lib/containers/valheim 0750 ${toString serverUid} ${toString serverGid} -"
        "d /var/lib/containers/valheim/config 0750 ${toString serverUid} ${toString serverGid} -"
        "d /var/lib/containers/valheim/cache 0750 ${toString serverUid} ${toString serverGid} -"
      ];

      networking.firewall.allowedUDPPortRanges = [
        {
          from = gamePort;
          to = gamePort + 2;
        }
      ];

      virtualisation.oci-containers.containers.valheim = {
        # lloesche tags by date (`latest`, `YYYY-MM-DD`) rather than
        # semver, so pin to the digest of `latest` for reproducibility;
        # renovate tracks `latest` and bumps the digest on its own
        # (see renovate.json's digest manager).
        # renovate: datasource=docker depName=lloesche/valheim-server
        image = "lloesche/valheim-server:latest@sha256:20fde516ce311e6084f82f295c9eb6934af57b357c657937a04f62bdf5946149";
        volumes = [
          "/var/lib/containers/valheim/config:/config"
          "/var/lib/containers/valheim/cache:/opt/valheim"
        ];
        environment = {
          TZ = config.time.timeZone;
          SERVER_NAME = "hpp-valheim";
          WORLD_NAME = "hpp";
          # SERVER_PUBLIC=false keeps the server out of the Steam
          # community browser; tailscale peers join by direct
          # connect-IP entry from the Valheim "Join Game" screen.
          SERVER_PUBLIC = "false";
          PUID = toString serverUid;
          PGID = toString serverGid;
        };
        environmentFiles = [ config.sops.templates."valheim.env".path ];
        extraOptions = [ "--network=host" ];
      };
    };
}
