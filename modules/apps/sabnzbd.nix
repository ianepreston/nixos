# Sabnzbd - usenet downloader
# Container only; auth/caddy/homepage wired by arr-auth.nix.
#
# Sabnzbd refuses any HTTP request whose Host header doesn't match the
# local hostname or an entry in `host_whitelist`. With Caddy in front,
# the Host header arriving at sabnzbd is the FQDN of the public site,
# which the default config rejects. The home-operations image's
# entrypoint applies SABNZBD__HOST_WHITELIST_ENTRIES on every start —
# so we set the FQDN there instead of seeding the ini ourselves.
# (Image baked-in user is `nobody:nogroup`; we override via `user` so
# writes to /mnt/content/Downloads land with the UID/GID the NAS
# expects.)
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

      systemd.tmpfiles.rules = [
        "d ${stateDir} 0750 ${toString serverUid} ${toString serverGid} -"
      ];

      virtualisation.oci-containers.containers.sabnzbd = {
        # renovate: datasource=docker depName=ghcr.io/home-operations/sabnzbd
        image = "ghcr.io/home-operations/sabnzbd:5.0.1";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        user = "${toString serverUid}:${toString serverGid}";
        volumes = [
          "${stateDir}:/config"
          "/mnt/content/Downloads:/downloads"
        ];
        environment = {
          SABNZBD__PORT = toString port;
          SABNZBD__HOST_WHITELIST_ENTRIES = sabnzbdHost;
          TZ = config.time.timeZone;
        };
      };
    };
}
