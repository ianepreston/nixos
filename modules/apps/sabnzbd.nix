# Sabnzbd - usenet downloader
# Container only; auth/caddy/homepage wired by arr-auth.nix.
#
# Sabnzbd refuses any HTTP request whose Host header doesn't match the
# local hostname or an entry in `host_whitelist`. With Caddy in front,
# the Host header arriving at sabnzbd is the FQDN of the public site,
# which the default config rejects. Seed the ini once on first start
# with that hostname in `host_whitelist` so the very first request
# through caddy isn't denied. Subsequent edits via sabnzbd's UI persist
# and aren't clobbered — the bootstrap script is a no-op when the file
# already exists.
_: {
  flake.modules.nixos.sabnzbd =
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
      port = 8080;
      stateDir = "/var/lib/containers/sabnzbd";
      sabnzbdHost = "sabnzbd.${hostSpec.serverDomain}";
    in
    {
      myArrAuth.apps.sabnzbd = {
        inherit port;
        displayName = "Sabnzbd";
        homepageDescription = "Usenet downloader";
      };

      systemd = {
        tmpfiles.rules = [
          "d ${stateDir} 0750 ${toString serverUid} ${toString serverGid} -"
        ];

        services.podman-sabnzbd.preStart = ''
          ini=${stateDir}/sabnzbd.ini
          if [ ! -f "$ini" ]; then
            cat > "$ini" <<EOF
          __version__ = 19
          [misc]
          host = 0.0.0.0
          port = ${toString port}
          host_whitelist = ${sabnzbdHost}
          api_key =
          EOF
            chown ${toString serverUid}:${toString serverGid} "$ini"
            chmod 0600 "$ini"
          fi
        '';
      };

      virtualisation.oci-containers.containers.sabnzbd = {
        # renovate: datasource=docker depName=lscr.io/linuxserver/sabnzbd
        image = "lscr.io/linuxserver/sabnzbd:5.0.1";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        volumes = [
          "${stateDir}:/config"
          "/mnt/content/Downloads:/downloads"
        ];
        environment = {
          PUID = toString serverUid;
          PGID = toString serverGid;
          TZ = config.time.timeZone;
        };
      };
    };
}
