# Radarr - movie management
# Native services.radarr from nixpkgs (system user `radarr` overridden
# to the shared server-${env}:servers user so writes back to the
# NFS-mounted Movies share land with the UID/GID the NAS expects).
# auth/caddy/homepage wiring is generated from
# `myAuthentik.forwardAuthApps.radarr` by modules/platform/authentik.nix.
#
# `dataDir` is pinned to /var/lib/radarr (instead of the upstream
# default /var/lib/radarr/.config/Radarr) to match the container's
# /config layout 1:1 — see modules/apps/sonarr.nix for the same
# rationale.
#
# Cross-app URL after migration: containerized peers reach radarr at
# `host.containers.internal:7878`; native peers use `localhost:7878`.
_: {
  flake.modules.nixos.radarr =
    { hostSpec, ... }:
    {
      myAuthentik.forwardAuthApps.radarr = {
        port = 7878;
        displayName = "Radarr";
        homepage = {
          group = "Acquisition";
          icon = "radarr";
          description = "Movie manager";
        };
      };

      services.radarr = {
        enable = true;
        user = "server-${hostSpec.serverEnvironment}";
        group = "servers";
        dataDir = "/var/lib/radarr";
      };

      services.restic.backups.server.paths = [ "/var/lib/radarr" ];

      systemd.services.radarr-migrate-state = {
        description = "Migrate radarr state from container layout";
        before = [ "radarr.service" ];
        wantedBy = [ "radarr.service" ];
        unitConfig.ConditionPathExists = "/var/lib/containers/radarr";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          if [ ! -e /var/lib/radarr ] || [ -z "$(ls -A /var/lib/radarr 2>/dev/null)" ]; then
            rm -rf /var/lib/radarr
            mv /var/lib/containers/radarr /var/lib/radarr
          fi
        '';
      };
    };
}
