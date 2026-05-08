# Readeck - read-it-later / bookmark archive
# Native services.readeck from nixpkgs (Go binary under DynamicUser);
# gated by authentik forward-auth (Users group). Readeck does not
# implement OIDC as of 0.22 — its only SSO hook is Forwarded
# Authentication via Remote-User / Remote-Email / Remote-Groups
# headers. Caddy translates the X-authentik-* headers into those
# Remote-* names, and READECK_AUTH_FORWARDED_PROVISIONING auto-creates
# a readeck account the first time each authentik user lands on the
# app.
#
# Remote-Groups is pinned to "user" because readeck only accepts its
# own group names ("user" / "staff" / "admin"); forwarding the raw
# X-authentik-groups value (e.g. "Users") would be rejected. Bootstrap
# an admin account once via the readeck CLI if you need elevated
# access in the UI.
#
# Trusted_proxies is left at the upstream default (RFC1918 + loopback);
# caddy talks to readeck on 127.0.0.1, so the Remote-* headers are
# honoured.
_: {
  flake.modules.nixos.readeck =
    _:
    let
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

      services.readeck.enable = true;

      # Readeck reads env vars on top of its TOML config; reuse the
      # same READECK_* keys that worked under the container so the
      # behaviour is identical (and the migration unit doesn't need
      # to translate semantics into the toml settings format).
      systemd.services.readeck.environment = {
        READECK_SERVER_HOST = "127.0.0.1";
        READECK_SERVER_PORT = toString port;
        READECK_AUTH_FORWARDED_ENABLED = "true";
        READECK_AUTH_FORWARDED_PROVISIONING = "true";
      };

      services.restic.backups.server.paths = [ "/var/lib/readeck" ];

      # Readeck uses DynamicUser, so systemd reowns the StateDirectory
      # tree to the freshly-allocated UID on first start; the move is
      # all we need to do here.
      systemd.services.readeck-migrate-state = {
        description = "Migrate readeck state from container layout";
        before = [ "readeck.service" ];
        wantedBy = [ "readeck.service" ];
        unitConfig.ConditionPathExists = "/var/lib/containers/readeck";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          if [ ! -e /var/lib/readeck ] || [ -z "$(ls -A /var/lib/readeck 2>/dev/null)" ]; then
            rm -rf /var/lib/readeck
            mv /var/lib/containers/readeck /var/lib/readeck
          fi
        '';
      };
    };
}
