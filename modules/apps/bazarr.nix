# Bazarr - subtitles for sonarr/radarr libraries
# Native services.bazarr from nixpkgs (system user `bazarr` overridden
# to the shared server-${env}:servers user so NFS reads/writes against
# /mnt/content land with the UID/GID the NAS expects). auth/caddy/
# homepage wiring is generated from `myAuthentik.forwardAuthApps.bazarr`
# by modules/platform/authentik.nix.
#
# Cross-app URL after migration: peers reaching bazarr from a still-
# containerized service need `host.containers.internal:6767`; native
# peers use `localhost:6767`. The NFS mounts (/mnt/content/{TV,Movies})
# are inherited from server-${env} via standard host paths — no
# bind-mounts needed because bazarr runs in the host namespace.
_: {
  flake.modules.nixos.bazarr =
    { hostSpec, ... }:
    {
      myAuthentik.forwardAuthApps.bazarr = {
        port = 6767;
        displayName = "Bazarr";
        homepage = {
          group = "Acquisition";
          icon = "bazarr";
          description = "Subtitle manager";
        };
      };

      services.bazarr = {
        enable = true;
        user = "server-${hostSpec.serverEnvironment}";
        group = "servers";
      };

      services.restic.backups.server.paths = [ "/var/lib/bazarr" ];

      # One-shot migration from the previous container layout
      # (/var/lib/containers/bazarr -> /var/lib/bazarr). Files keep
      # their server-${env}:servers ownership, which matches the
      # overridden user/group on the new service.
      systemd.services.bazarr-migrate-state = {
        description = "Migrate bazarr state from container layout";
        before = [ "bazarr.service" ];
        wantedBy = [ "bazarr.service" ];
        unitConfig.ConditionPathExists = "/var/lib/containers/bazarr";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          if [ ! -e /var/lib/bazarr ] || [ -z "$(ls -A /var/lib/bazarr 2>/dev/null)" ]; then
            rm -rf /var/lib/bazarr
            mv /var/lib/containers/bazarr /var/lib/bazarr
          fi
        '';
      };
    };
}
