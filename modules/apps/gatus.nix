#  Gatus - blackbox endpoint monitoring + public status page.
# Native services.gatus from the nixpkgs this flake tracks (5.36.0;
# unstable is 5.37.0, small lag, stable fine). Complements the
# prometheus white-box stack in modules/system/observability.nix — see
# issue #128 for the failure classes each catches.
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
# outside Caddy, does NOT follow redirects (client.ignore-redirect),
# and asserts:
#   * [STATUS] == any(200, 301, 302, 307, 308)
#       Apps gated by authentik forward-auth respond 302 (redirect to
#       the outpost) for an unauthenticated request — that *is* the
#       healthy response: it confirms Caddy → forward_auth → outpost
#       is alive. A 200 means the app speaks OIDC natively or is
#       publicly exposed. Apps that redirect from their own handler
#       pick their own code — seerr answers 307 to /login — so every
#       redirect form is accepted rather than just 302. Anything else
#       (4xx, 5xx, timeout, bad cert) trips.
#   * [RESPONSE_TIME] < 2000ms (issue spec).
#
# Certificate lifetime is deliberately NOT asserted here. An HTTP
# probe cannot measure it honestly — see `certEndpoints` below and
# issue #758.
#
# The endpoint list is sourced from `config.myCaddy.apps` so it stays
# in sync as apps are added/removed without duplicating the registry.
# Gatus itself appears in the list — probing its own admin route is a
# useful end-to-end check of the forward-auth chain. So does authentik
# (registered by modules/apps/authentik.nix), so there is no separate
# infrastructure-group probe for it.
#
# Alerts route through prometheus: gatus exposes /metrics, prometheus
# scrapes it, and a `gatus_results_endpoint_success == 0` rule fires
# into the existing alertmanager → discord receiver. Wiring lives in
# modules/system/prometheus.nix. Issue #128 originally floated ntfy for
# delivery-path independence; the prometheus path was preferred because
# it reuses the existing alert chain (grouping, silencing, watchdog).
#
# Open items (deferred — call out in PR):
#   * Two-hostname listener split. Gatus 5.x serves UI + status page
#     from the same handler; differentiating "admin" vs "read-only"
#     is purely the Caddy auth layer (forward_auth on gatus.<domain>,
#     none on status.<domain>). If gatus later grows real read-only
#     vs admin handlers, revisit.
#   * Forward-auth redirect *target* assertion. Issue calls out
#     checking the `Location` header matches the outpost URL — gatus
#     supports `[HEADERS].Location == ...` conditions but the exact
#     redirect URL depends on the embedded outpost state. Initial
#     cut accepts any redirect status; tighten later.
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

      # Per-app HTTP probe. Hits the external (caddy-fronted) URL from
      # outside, so DNS + TLS + caddy route + forward-auth chain (if
      # any) are all on the path. A redirect is treated as healthy
      # because forward-auth gated apps redirect unauthenticated
      # requests to the authentik outpost — that redirect IS the
      # signal we want.
      #
      # ignore-redirect stops there instead of walking the whole OIDC
      # login flow. Following it cost five extra requests per probe to
      # learn nothing, and at ~20 gated apps × 1440 probes/day that was
      # 94% of authentik's log bytes and >50% of the entire host
      # journal (closes #587). The asserted [STATUS] is the first
      # response's, which is what we want.
      #
      # It is also what exposed #758. Gatus reads a response body only
      # when some condition references [BODY]; ours never do, so an
      # empty-bodied 302 is trivially fully-consumed and Go returns its
      # connection to the idle pool — where gatus's transport, which
      # leaves IdleConnTimeout at zero (= no limit), keeps it forever.
      # Every subsequent probe then reports the certificate from that
      # one original handshake. Cert assertions moved to
      # `certEndpoints`; ignore-redirect stays, because it is worth
      # >50% of the host journal and the split makes the pooling
      # harmless.
      mkAppEndpoint = name: app: {
        inherit name;
        group = "apps";
        url = "https://${app.host}";
        interval = "60s";
        conditions = [
          "[STATUS] == any(200, 301, 302, 307, 308)"
          "[RESPONSE_TIME] < 2000"
        ];
        client = {
          timeout = "10s";
          ignore-redirect = true;
        };
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

      # Certificate lifetime, measured on a connection that is
      # guaranteed to be fresh.
      #
      # The HTTP probes above cannot do this (#758). Gatus reads the
      # cert off `response.TLS`, which on a reused keep-alive
      # connection is the *original* handshake's state, and its
      # transport pools connections for the process lifetime. On amos1
      # that left 20 of 35 app endpoints counting down 1s/s toward a
      # notAfter that had been retired 28 hours earlier — invisible to
      # `_success`, and enough to drag `min by (group)` under the alert
      # threshold. There is no client-side knob for it: gatus exposes
      # no keep-alive or idle-timeout setting, so the endpoint *type*
      # has to change.
      #
      # `tls://` goes through client.CanPerformTLS, which dials with
      # `tls.DialWithDialer` and closes the connection on return — a
      # fresh handshake every probe, no pool, so a *successful* probe
      # cannot report a superseded certificate.
      #
      # Precisely that and no more. Gatus sets the gauge only when
      # `result.CertificateExpiration != 0`, and the TLS branch returns
      # early on a dial error, so a *failing* probe leaves the last
      # good value in place rather than going absent — the gauge still
      # freezes if the handshake breaks (bad chain, DNS, caddy down).
      # What this fixes is the keep-alive pinning; GatusEndpointDown is
      # what covers a broken probe.
      #
      # One endpoint per *certificate*, not per app: caddy serves a
      # single `*.${serverDomain}` wildcard for every app host (see
      # ../system/caddy.nix), so one subdomain covers all of them.
      # `status.` is the one to probe because it is the public,
      # unauthenticated route — nothing can gate it out from under the
      # probe. Do not use the bare serverDomain: it has an A record
      # but the wildcard does not cover the apex, so caddy answers the
      # handshake with a TLS internal error.
      #
      # This one keeps the 336h assertion that came off the app
      # probes. At 14d remaining on a cert we renew ourselves, caddy's
      # ACME has been failing for over two weeks and a hard probe
      # failure is warranted — and it is now one endpoint failing
      # rather than a cascade across every app.
      #
      # Named for the domain rather than "wildcard" so the alert
      # identifies itself. CertificateExpiringSoon reaches discord as
      # summary + description only (see ../system/alertmanager.nix) and
      # neither carries a host label, so `name` is the one field that
      # can say which host's certificate this is. Gatus sanitizes dots
      # out of the derived key, so the dotted form is safe.
      certEndpoints = [
        {
          name = hostSpec.serverDomain;
          group = "certs";
          url = "tls://${statusHost}:443";
          interval = "60s";
          conditions = [
            "[CONNECTED] == true"
            "[CERTIFICATE_EXPIRATION] > 336h"
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

        # Expose /metrics for prometheus. The scrape job + alert rule on
        # `gatus_results_endpoint_success == 0` live in
        # modules/system/prometheus.nix — gatus failures route through
        # the existing alertmanager → discord receiver, no extra sink.
        metrics = true;

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

        endpoints = appEndpoints ++ externalEndpoints ++ certEndpoints;
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
      myAppState.gatus = {
        stateDir = "/var/lib/gatus";
        user = "gatus";
        group = "gatus";
      };

      myRecovery.apps.gatus = {
        kind = "sqlite";
        order = 60;
        units = [ "gatus.service" ];
        paths = [ "/var/lib/gatus" ];
        sqliteOwner = "gatus";
      };

      # Quiesce the sqlite file before restic snapshots — matches the
      # pattern in 9886a1d for all other sqlite-backed apps.
      mySqliteQuiesce.apps.gatus.databases = [
        "/var/lib/gatus/data.db"
      ];
    };
}
