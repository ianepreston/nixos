# Sonarr - TV management
# Native services.sonarr from nixpkgs (system user `sonarr` overridden
# to the shared server-${env}:servers user so writes back to the
# NFS-mounted TV share land with the UID/GID the NAS expects).
# auth/caddy/homepage wiring is generated from
# `myAuthentik.forwardAuthApps.sonarr` by modules/platform/authentik.nix.
#
# `dataDir` is pinned to /var/lib/sonarr (instead of the upstream
# default /var/lib/sonarr/.config/NzbDrone) to match the container's
# /config layout 1:1 — that lets the migration unit be a plain `mv`
# rather than a relocate-and-restructure step.
#
# Cross-app URL after migration: containerized peers (e.g. prowlarr's
# applications list) need to reference `host.containers.internal:8989`;
# native peers use `localhost:8989`.
_: {
  flake.modules.nixos.sonarr =
    { hostSpec, ... }:
    {
      myAuthentik.forwardAuthApps.sonarr = {
        port = 8989;
        displayName = "Sonarr";
        homepage = {
          group = "Acquisition";
          icon = "sonarr";
          description = "TV manager";
        };
      };

      services.sonarr = {
        enable = true;
        user = "server-${hostSpec.serverEnvironment}";
        group = "servers";
        dataDir = "/var/lib/sonarr";
      };

      services.restic.backups.server.paths = [ "/var/lib/sonarr" ];

      systemd.services.sonarr-migrate-state = {
        description = "Migrate sonarr state from container layout";
        before = [ "sonarr.service" ];
        wantedBy = [ "sonarr.service" ];
        unitConfig.ConditionPathExists = "/var/lib/containers/sonarr";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          if [ ! -e /var/lib/sonarr ] || [ -z "$(ls -A /var/lib/sonarr 2>/dev/null)" ]; then
            rm -rf /var/lib/sonarr
            mv /var/lib/containers/sonarr /var/lib/sonarr
          fi
        '';
      };
    };
}
