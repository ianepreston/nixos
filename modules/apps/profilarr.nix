# Profilarr - sync custom formats and quality profiles into Sonarr/Radarr
# (https://github.com/Dictionarry-Hub/profilarr). Container only; the
# upstream image has no built-in auth, so the app is gated by authentik
# forward-auth via Caddy. State lives at /var/lib/containers/profilarr,
# covered by the standard /var/lib/containers restic snapshot.
#
# The image's entrypoint expects to start as root: it useradd's appuser
# from PUID/PGID, mkdir+chowns /home/appuser, chowns /config, then
# gosu's to PUID:PGID. So we don't set `user`; we drive the in-image
# user via PUID/PGID env vars set to server-${env}:servers.
_: {
  flake.modules.nixos.profilarr =
    _:
    let
      port = 6868;
    in
    {
      myAuthentik.forwardAuthApps.profilarr = {
        inherit port;
        displayName = "Profilarr";
        homepage = {
          group = "Acquisition";
          icon = "profilarr";
          description = "Sync *arr quality profiles";
        };
      };

      myContainerApp.profilarr = {
        inherit port;
        linuxServer = true;
      };

      virtualisation.oci-containers.containers.profilarr = {
        # renovate: datasource=docker depName=santiagosayshey/profilarr
        image = "santiagosayshey/profilarr:v1.1.5";
        volumes = [
          "/var/lib/containers/profilarr:/config"
        ];
      };
    };
}
