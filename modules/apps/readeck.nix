# Readeck - read-it-later / bookmark archive
# Container; gated by authentik forward-auth (Users group). Readeck
# does not implement OIDC as of 0.22 — its only SSO hook is
# Forwarded Authentication via Remote-User / Remote-Email /
# Remote-Groups headers. Caddy translates the X-authentik-* headers
# the embedded outpost copies in into those Remote-* names, and
# READECK_AUTH_FORWARDED_PROVISIONING auto-creates a readeck account
# the first time each authentik user lands on the app.
#
# Remote-Groups is pinned to "user" because readeck only accepts its
# own group names ("user" / "staff" / "admin"); forwarding the raw
# X-authentik-groups value (e.g. "Users") would be rejected. Bootstrap
# an admin account once via `podman exec readeck readeck user add -u
# <name> -g admin -p <pass>` if you need elevated access in the UI.
#
# Trusted_proxies is left at the upstream default (RFC1918 + loopback).
# Caddy talks to the container over the podman bridge so its source IP
# is the bridge gateway (e.g. 10.88.0.1), not 127.0.0.1; pinning
# trusted_proxies to 127.0.0.1 made readeck 403 every forwarded-auth
# request. The container's published port is already locked to
# 127.0.0.1:8000 on the host, so non-local clients can't reach it.
_: {
  flake.modules.nixos.readeck =
    {
      config,
      hostSpec,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
      port = 8000;
    in
    {
      myAuthentik.forwardAuthApps.readeck = {
        inherit port;
        displayName = "Readeck";
        authentikGroup = "Users";
        homepage = {
          group = "Consumption";
          icon = "readeck";
          description = "Read-it-later";
        };
        proxyConfig = ''
          header_up Remote-User {http.request.header.X-authentik-username}
          header_up Remote-Email {http.request.header.X-authentik-email}
          header_up Remote-Groups user
        '';
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/containers/readeck 0750 ${toString serverUid} ${toString serverGid} -"
      ];

      virtualisation.oci-containers.containers.readeck = {
        # renovate: datasource=docker depName=codeberg.org/readeck/readeck
        image = "codeberg.org/readeck/readeck:0.22.3";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        user = "${toString serverUid}:${toString serverGid}";
        volumes = [
          "/var/lib/containers/readeck:/readeck"
        ];
        environment = {
          TZ = config.time.timeZone;
          READECK_SERVER_HOST = "0.0.0.0";
          READECK_SERVER_PORT = toString port;
          READECK_AUTH_FORWARDED_ENABLED = "true";
          READECK_AUTH_FORWARDED_PROVISIONING = "true";
        };
      };
    };
}
