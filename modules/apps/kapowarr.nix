# Kapowarr - comics manager (alternative to mylar3)
# Container only; auth/caddy/homepage wired by apps/authentik.nix. Upstream
# image isn't a linuxserver build, so we set the runtime user via
# `--user` directly rather than via PUID/PGID env vars.
_: {
  flake.modules.nixos.kapowarr =
    _:
    let
      port = 5656;
    in
    {
      myAuthentik.forwardAuthApps.kapowarr = {
        inherit port;
        displayName = "Kapowarr";
        # No upstream icon in dashboard-icons yet; fall back to repo favicon.
        iconUrl = "https://raw.githubusercontent.com/Casvt/Kapowarr/master/frontend/static/img/favicon.svg";
        homepage = {
          group = "Acquisition";
          icon = "https://raw.githubusercontent.com/Casvt/Kapowarr/master/frontend/static/img/favicon.svg";
          description = "Comics manager";
        };
      };

      # `/app/logs` inside the image is owned by kapowarr's bundled
      # default user; with `--user` overridden to server-${env}:servers
      # the bundled user can't write there, so mount the logs dir off
      # of the host state tree to keep them writable (and conveniently
      # included in the /var/lib/containers restic snapshot).
      myContainerApp.kapowarr = {
        inherit port;
        stateDirs = [
          "/var/lib/containers/kapowarr"
          "/var/lib/containers/kapowarr/db"
          "/var/lib/containers/kapowarr/logs"
        ];
      };

      virtualisation.oci-containers.containers.kapowarr = {
        # renovate: datasource=docker depName=mrcas/kapowarr
        image = "mrcas/kapowarr:v1.3.1";
        volumes = [
          "/var/lib/containers/kapowarr/db:/app/db"
          "/var/lib/containers/kapowarr/logs:/app/logs"
          "/mnt/content/Comics:/content"
          "/mnt/content/Downloads:/app/temp_downloads"
        ];
      };
    };
}
