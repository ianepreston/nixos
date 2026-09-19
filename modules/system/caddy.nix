# Caddy - Simple Aspect
# Reverse proxy for server apps.
#
# Cert strategy: a single `*.${serverDomain}` virtualHost. Caddy issues
# one wildcard cert (DNS-01 via Cloudflare) and reuses it for every
# subdomain. Per-app vhosts would each trigger their own ACME order
# under the same registered domain (`ipreston.net`), and Let's Encrypt
# rate-limits to 50 certs/week per registered domain — full rebuilds
# of dev + prod can blow that on a single afternoon. The wildcard
# collapses the certificate count to one per server, no matter how
# many apps are added.
#
# App modules contribute routes via the `myCaddy.apps.<name>` option
# rather than `services.caddy.virtualHosts` directly. Each entry
# becomes a `@<name> host <fqdn>` matcher + `handle @<name> { ... }`
# block inside the wildcard vhost, so adding an app stays a one-attr
# declaration without leaking the routing layout into every module.
_: {
  flake.modules.nixos.caddy =
    {
      config,
      hostSpec,
      inputs,
      lib,
      pkgs,
      ...
    }:
    let
      sopsFolder = "${inputs.nix-secrets}/sops";

      # Credential scrubbing, shared by every logger this module configures.
      #
      # Caddy redacts `Cookie` and `Authorization` itself and nothing else, and
      # the traffic here is not hypothetical — `bypassAuthPaths` (see
      # modules/apps/radarr.nix) exists precisely so non-browser clients
      # authenticate to `/api/*` through this proxy with their native key.
      # Measured on hpp-1's pre-change log: 10.0% of 73.5k records carried a
      # live API key in the query string in plaintext, sabnzbd's among them.
      redactCredentials = ''
        fields {
          # Credential-bearing query params, case-insensitive: Jellyfin's
          # `api_key`, the *arr/sabnzbd `apikey`, and any `*token` /
          # `*secret` / `*password`. `api_?key` carries the literal "api"
          # so an innocent `monkey=` keeps its value; `token` and friends
          # are prefix-tolerant so `access_token` is covered too.
          #
          # Checked against every param name the pre-change log actually
          # contained (31 distinct over 73.5k records): `apikey` was the
          # only credential-shaped one, and this covers it. Deliberately
          # *not* covered is the OIDC `code=` — a single-use, PKCE-bound
          # authorization code already redeemed before the record is
          # queryable, and `code` is too generic a name to blanket-redact
          # without eating legitimate params.
          request>uri regexp "(?i)([?&][^=&]*(api_?key|token|secret|password)=)[^&]*" "''${1}REDACTED"

          # Vendor auth headers Caddy does not redact. Go canonicalises
          # header names, so `X-MediaBrowser-Token` is matched by the
          # capitalisation below, not by its wire spelling. Jellyfin accepts
          # all three of these, and `X-Emby-Authorization` carries the token
          # inside a `Token="..."` parameter rather than as the whole value.
          request>headers>X-Api-Key delete
          request>headers>X-Emby-Token delete
          request>headers>X-Emby-Authorization delete
          request>headers>X-Mediabrowser-Token delete
        }
      '';

      # Access-log sink. Caddy *was* already logging every request — the
      # NixOS module gives each vhost a default
      # `logFormat = "output file ${logDir}/access-<host>.log"` — but into a
      # file nothing reads. So the records existed and were still useless:
      # diagnosing #668 meant reading client IPs out of Jellyfin's
      # `ActivityLogs` table, because a file under /var/log/caddy answers
      # nothing about any other app and is not reachable from the place the
      # question gets asked (#669).
      #
      # Retargeting to stderr puts them in journald, which vector already
      # tails (modules/system/vector.nix) into VictoriaLogs, so they outlive
      # journald's cap and are queryable for 15d with no state directory or
      # rotation policy to own. This replaces the file sink rather than adding
      # to it: two loggers would log every request twice.
      #
      # vector ships the journal line as-is, so a record arrives as one opaque
      # JSON string in `_msg` rather than as columns — unlike the `fw_*` fields
      # vector's own pfsense transform produces. Add `unpack_json` to get
      # fields; this is the #668 question, and it works:
      #   _time:24h "http.log.access" | unpack_json
      #     | filter request.host:="jellyfin.${hostSpec.serverDomain}"
      #     | fields _time, request.client_ip, request.uri, status
      accessLogFormat = ''
        output stderr
        format filter {
          wrap json
          ${redactCredentials}
        }
      '';

      # The default logger handles everything that is not the access log —
      # notably `http.log.error`, which the access logger's `include` does not
      # cover. It writes the raw URI and headers of every failed request, so
      # without the same filter an app restart mid-poll persists an *arr key
      # in cleartext (the 502s in #669's measurement were exactly that shape).
      # `level ERROR` is the module's own default, restated because setting
      # this option replaces it.
      globalLogFormat = ''
        level ERROR
        format filter {
          wrap json
          ${redactCredentials}
        }
      '';

      # gatus probes every app in this vhost once a minute from the host
      # itself, and that is 88.1% of all access records (64,774 of 73,532
      # over 30.7h on hpp-1) describing nothing but the machine talking to
      # itself. #587 is the precedent: these same probes were once >50% of
      # the host journal. Dropping them leaves real clients at p50 0.07/s,
      # max 2.87/s — far enough under `JournalLogRateHigh` (50/s, see
      # modules/system/victoriametrics.nix) that its calibration stands.
      # gatus's own UI and alerts remain the proof the proxy is serving.
      #
      # Both conditions are required. A `User-Agent` is client-controlled, so
      # on its own it would let any caller erase its own access record just by
      # claiming to be gatus — which would defeat #668, the case this logging
      # exists for. Pinning the source to this host's own LAN address closes
      # that: every one of the 64,990 probes measured arrived from it, and
      # real clients arrive from the podman bridge or the LAN. The UA half
      # stays because the host also makes non-probe requests to itself (30 in
      # the same sample), and is wildcarded so a gatus version bump can't
      # silently restore the noise.
      skipGatusProbes = ''
        @gatusProbe {
          header User-Agent Gatus/*
          remote_ip ${hostSpec.serverLanIp}
        }
        log_skip @gatusProbe
      '';
    in
    {
      options.myCaddy.apps = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, ... }:
            {
              options = {
                host = lib.mkOption {
                  type = lib.types.str;
                  default = "${name}.${hostSpec.serverDomain}";
                  defaultText = lib.literalExpression ''"<name>.''${hostSpec.serverDomain}"'';
                  description = "Hostname matched for this app. Defaults to <name>.<serverDomain>.";
                };
                routeConfig = lib.mkOption {
                  type = lib.types.lines;
                  description = ''
                    Caddy directives for this app's `handle` block. Typically a
                    single `reverse_proxy` directive, with `import authentik_forward_auth`
                    prepended for apps that don't speak OIDC themselves.
                  '';
                };
              };
            }
          )
        );
        default = { };
        description = ''
          Apps routed via the wildcard `*.''${hostSpec.serverDomain}` virtualHost.
          One wildcard cert covers every entry here, so adding apps doesn't
          consume Let's Encrypt rate-limit budget.
        '';
      };

      config = {
        services.caddy = {
          enable = true;
          email = hostSpec.email.personal;
          # Caddy with the Cloudflare DNS plugin so the ACME DNS-01
          # challenge can create _acme-challenge TXT records. The hash
          # pins the xcaddy-vendored source tree the plugin list produces;
          # Renovate bumps the plugin version and nothing else, so the hash
          # is regenerated in CI on every renovate branch — the
          # `regen-hash:` marker names the attribute that has to be built to
          # learn it (see scripts/regen-fetch-hashes.sh and #625).
          package = pkgs.caddy.withPlugins {
            plugins = [
              # renovate: datasource=github-tags depName=caddy-dns/cloudflare
              "github.com/caddy-dns/cloudflare@v0.2.4"
            ];
            # regen-hash: nixosConfigurations.hpp-1.config.services.caddy.package.src
            hash = "sha256-dQvk6ezY6TQ1J7PjhCXnThF/SqVgPwBO8/RXzHCY+js=";
          };
          globalConfig = ''
            acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}
          '';

          # Scrub credentials from the error log too; see globalLogFormat.
          logFormat = globalLogFormat;

          virtualHosts."*.${hostSpec.serverDomain}" = {
            # Overrides the module's per-vhost default of a file sink under
            # `services.caddy.logDir`; see accessLogFormat above.
            logFormat = accessLogFormat;

            extraConfig =
              let
                mkRoute = name: app: ''
                  @${name} host ${app.host}
                  handle @${name} {
                    ${app.routeConfig}
                  }
                '';
                routes = lib.concatStringsSep "\n" (lib.mapAttrsToList mkRoute config.myCaddy.apps);
              in
              ''
                ${skipGatusProbes}
                ${routes}
                handle {
                  respond "Unknown service" 404
                }
              '';
          };
        };

        sops.secrets."cloudflare/acme_token" = {
          sopsFile = "${sopsFolder}/server-shared.yaml";
          owner = "caddy";
          restartUnits = [ "caddy.service" ];
        };

        sops.templates."caddy.env" = {
          content = ''
            CLOUDFLARE_API_TOKEN=${config.sops.placeholder."cloudflare/acme_token"}
          '';
          owner = "caddy";
          restartUnits = [ "caddy.service" ];
        };

        systemd.services.caddy.serviceConfig.EnvironmentFile = [
          config.sops.templates."caddy.env".path
        ];

        networking.firewall.allowedTCPPorts = [
          80
          443
        ];
      };
    };
}
