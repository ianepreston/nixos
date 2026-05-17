#  Gatus - blackbox endpoint monitoring + public status page.
# Native services.gatus from nixpkgs 25.11 (5.31.0; unstable is 5.35.0,
# small lag, stable fine). Complements the prometheus white-box stack
# in modules/system/observability.nix — see issue #128 for the failure
# classes each catches.
#
# Two-hostname split, both pointing at the same listener:
#   * gatus.<domain>  — admin/config view, gated by authentik
#                       forward-auth (Infrastructure group) via
#                       myAuthentik.forwardAuthApps.gatus.
#   * status.<domain> — public read-only status page, NO auth.
#                       Load-bearing: if authentik is what broke, you
#                       need the status page reachable to see that.
#                       Gatus serves both UI and the read-only status
#                       page from the same port; the distinction is
#                       purely the Caddy route, with auth omitted.
#
# Probe strategy. Each endpoint hits https://<app>.<serverDomain> from
# outside Caddy and asserts:
#   * [STATUS] == any(200, 302)
#       Apps gated by authentik forward-auth respond 302 (redirect to
#       the outpost) for an unauthenticated request — that *is* the
#       healthy response: it confirms Caddy → forward_auth → outpost
#       is alive. A 200 means the app speaks OIDC natively or is
#       publicly exposed. Anything else (5xx, timeout, bad cert) trips.
#   * [RESPONSE_TIME] < 2000ms (issue spec).
#   * [CERTIFICATE_EXPIRATION] > 336h (14d).
#
# The endpoint list is sourced from `config.myCaddy.apps` so it stays
# in sync as apps are added/removed without duplicating the registry.
# Gatus itself appears in the list — probing its own admin route is a
# useful end-to-end check of the forward-auth chain.
#
# Open items (deferred — call out in PR):
#   * Alerts. Issue recommends ntfy.sh for delivery-path independence
#     from alertmanager+discord. Not wired in this first cut; probes
#     surface failures via the status page only. Add ntfy receiver in
#     a follow-up after confirming probe coverage is right.
#   * Two-hostname listener split. Gatus 5.x serves UI + status page
#     from the same handler; differentiating "admin" vs "read-only"
#     is purely the Caddy auth layer (forward_auth on gatus.<domain>,
#     none on status.<domain>). If gatus later grows real read-only
#     vs admin handlers, revisit.
#   * Forward-auth redirect *target* assertion. Issue calls out
#     checking the `Location` header matches the outpost URL — gatus
#     supports `[HEADERS].Location == ...` conditions but the exact
#     redirect URL depends on the embedded outpost state. Initial
#     cut accepts any 302; tighten later.
_: {
  flake.modules.nixos.gatus =
    {
      config,
      hostSpec,
      lib,
      ...
    }:
    let
      port = 8084;
      uid = 894;
      gatusHost = "gatus.${hostSpec.serverDomain}";
      statusHost = "status.${hostSpec.serverDomain}";

      authentikHost = "authentik.${hostSpec.serverDomain}";

      # Per-app HTTP probe. Hits the external (caddy-fronted) URL from
      # outside, so DNS + TLS + caddy route + forward-auth chain (if
      # any) are all on the path. 302 is treated as healthy because
      # forward-auth gated apps redirect unauthenticated requests to
      # the authentik outpost — that redirect IS the signal we want.
      mkAppEndpoint = name: app: {
        inherit name;
        group = "apps";
        url = "https://${app.host}";
        interval = "60s";
        conditions = [
          "[STATUS] == any(200, 302)"
          "[RESPONSE_TIME] < 2000"
          "[CERTIFICATE_EXPIRATION] > 336h"
        ];
        client.timeout = "10s";
      };

      # Authentik itself isn't in myCaddy.apps (it's wired via
      # services.authentik-nix's own caddy hook), so probe it
      # explicitly. Same shape as app probes.
      authentikEndpoint = {
        name = "authentik";
        group = "infrastructure";
        url = "https://${authentikHost}/";
        interval = "60s";
        conditions = [
          "[STATUS] == 200"
          "[RESPONSE_TIME] < 2000"
          "[CERTIFICATE_EXPIRATION] > 336h"
        ];
        client.timeout = "10s";
      };

      # External dependency probes — these are the meta-monitoring
      # layer: if healthchecks.io or discord is what broke, the
      # alertmanager → discord path can't tell us about it.
      externalEndpoints = [
        {
          name = "healthchecks-io";
          group = "external";
          url = "https://healthchecks.io/";
          interval = "5m";
          conditions = [
            "[STATUS] == 200"
            "[CERTIFICATE_EXPIRATION] > 336h"
          ];
          client.timeout = "10s";
        }
        {
          name = "discord";
          group = "external";
          url = "tcp://discord.com:443";
          interval = "5m";
          conditions = [
            "[CONNECTED] == true"
          ];
          client.timeout = "10s";
        }
      ];

      appEndpoints = lib.mapAttrsToList mkAppEndpoint config.myCaddy.apps;

      gatusSettings = {
        web.port = port;
        # Bind loopback only; caddy handles tls + public exposure.
        # Gatus's `web.address` controls the listen interface.
        web.address = "127.0.0.1";

        # SQLite storage so uptime history survives restarts. Path is
        # inside the StateDirectory (/var/lib/gatus) the systemd unit
        # already creates.
        storage = {
          type = "sqlite";
          path = "/var/lib/gatus/data.db";
        };

        # Default behavior: surface 1d of uptime per endpoint on the
        # status page. Tunable later.
        ui = {
          title = "${hostSpec.hostName} status";
          header = "Homelab status";
        };

        endpoints = appEndpoints ++ [ authentikEndpoint ] ++ externalEndpoints;
      };
    in
    {
      # Pin a static uid/gid so /var/lib/gatus ownership survives the
      # ephemeral-root rollback. DynamicUser=true would otherwise
      # reshuffle the uid across boots and preservation would restore
      # stale ownership on the persisted state dir (see 71ddb68).
      users.users.gatus = {
        inherit uid;
        group = "gatus";
        isSystemUser = true;
      };
      users.groups.gatus.gid = uid;

      services.gatus = {
        enable = true;
        settings = gatusSettings;
      };

      # Override DynamicUser → static. Upstream module hardens with
      # AmbientCapabilities=CAP_NET_RAW for ping (we don't use ICMP
      # probes yet, but keep the cap so adding them later doesn't
      # need a unit edit), NoNewPrivileges=true, etc. Re-add the
      # implied hardening DynamicUser used to provide.
      systemd.services.gatus.serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = "gatus";
        Group = "gatus";
        StateDirectory = "gatus";
        RemoveIPC = true;
        ProtectHome = "read-only";
        RestrictSUIDSGID = true;
      };

      # Admin host: forward-auth gated, full UI access.
      myAuthentik.forwardAuthApps.gatus = {
        host = gatusHost;
        inherit port;
        displayName = "Gatus";
        # No homepage tile here — the public status page (below) is
        # the entry point we want surfaced on the homepage.
      };

      # Public status host: plain caddy route, no forward auth. Same
      # backend as the admin host; differentiation is auth only.
      # Routes through caddy so cert + tls match the rest of the
      # estate; gatus's read-only status page is safe to expose
      # unauthenticated.
      myCaddy.apps.status = {
        host = statusHost;
        routeConfig = ''
          reverse_proxy localhost:${toString port}
        '';
      };

      myHomepage.tiles.Status = {
        group = "Infrastructure";
        href = "https://${statusHost}";
        icon = "gatus";
        description = "endpoint status";
      };

      # Persistence: sqlite uptime history lives here. Static uid
      # pinned above so preservation can restore correct ownership.
      preservation.preserveAt."/persist".directories = [
        {
          directory = "/var/lib/gatus";
          user = "gatus";
          group = "gatus";
          mode = "0700";
        }
      ];

      services.restic.backups.server.paths = [ "/var/lib/gatus" ];

      # Quiesce the sqlite file before restic snapshots — matches the
      # pattern in 9886a1d for all other sqlite-backed apps.
      mySqliteQuiesce.apps.gatus.databases = [
        "/var/lib/gatus/data.db"
      ];
    };
}
