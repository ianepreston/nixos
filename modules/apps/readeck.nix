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
#
# READECK_SECRET_KEY is sourced from sops via environmentFile. Without
# it readeck generates a key on first run and tries to persist it back
# to its config TOML — but the nixpkgs module passes the toml from
# /nix/store, so the write fails (EROFS) and the service crashloops.
{ inputs, ... }:
let
  sopsFolder = (builtins.toString inputs.nix-secrets) + "/sops";
in
{
  flake.modules.nixos.readeck =
    {
      config,
      hostSpec,
      lib,
      ...
    }:
    let
      port = 8000;
      uid = 893;
    in
    {
      sops.secrets."readeck/secret_key" = {
        sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
        restartUnits = [ "readeck.service" ];
      };

      sops.templates."readeck.env" = {
        content = ''
          READECK_SECRET_KEY=${config.sops.placeholder."readeck/secret_key"}
        '';
        restartUnits = [ "readeck.service" ];
      };

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

      services.readeck = {
        enable = true;
        environmentFile = config.sops.templates."readeck.env".path;
      };

      # Readeck reads env vars on top of its TOML config; using
      # READECK_* keys keeps the wiring identical to what worked
      # under the container without re-expressing the semantics in
      # the toml settings format.
      systemd.services.readeck.environment = {
        READECK_SERVER_HOST = "127.0.0.1";
        READECK_SERVER_PORT = toString port;
        READECK_AUTH_FORWARDED_ENABLED = "true";
        READECK_AUTH_FORWARDED_PROVISIONING = "true";
      };

      users.users.readeck = {
        inherit uid;
        group = "readeck";
        isSystemUser = true;
      };
      users.groups.readeck.gid = uid;

      # Override DynamicUser → static "readeck". Upstream already pins
      # most hardening explicitly (NoNewPrivileges, PrivateTmp,
      # ProtectSystem=full, …); only the bits that DynamicUser used to
      # imply but the unit doesn't set need to be re-added.
      systemd.services.readeck.serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = "readeck";
        Group = "readeck";
        RemoveIPC = true;
        ProtectHome = "read-only";
        RestrictSUIDSGID = true;
      };

      preservation.preserveAt."/persist".directories = [
        {
          directory = "/var/lib/readeck";
          user = "readeck";
          group = "readeck";
          mode = "0700";
        }
      ];

      services.restic.backups.server.paths = [ "/var/lib/readeck" ];

      mySqliteQuiesce.apps.readeck.databases = [
        "/var/lib/readeck/data/db.sqlite3"
      ];
    };
}
