# Authentik - identity provider / SSO
# Uses the nix-community authentik-nix module: native systemd units
# (server, worker, migrate) running under DynamicUser, talking to
# postgres over the unix socket via peer auth and to a localhost Redis.
# Configuration (groups, users, applications, OAuth/proxy providers,
# group bindings) is managed declaratively via authentik blueprints —
# upstream's bundled blueprints plus everything under
# ./authentik-blueprints (and any paths added by other app modules via
# `myAuthentik.extraBlueprints`) are merged into a single dir that
# authentik scans on startup and reconciles periodically.
#
# This module also owns the `myAuthentik` option namespace that app
# modules contribute to. Aggregators:
#   * extraBlueprints   — list of blueprint dirs merged into authentik
#   * forwardAuthApps   — apps gated by the embedded outpost via Caddy
#                         forward_auth
#   * oidcApps          — apps that speak OIDC against authentik directly
#
# `oidcApps` also handles boot-time HTTP readiness: each app's
# `appRestartUnit` is pulled `After=authentik-ready.service` so apps
# that fetch the OIDC discovery URL once at startup (actualbudget,
# miniflux, komga) don't race authentik's Django worker and 502.
# No per-app `After=authentik.service` is needed — adding one would
# be redundant.
#
# Forward-auth specifics: the embedded outpost has a single global
# `providers` list. To avoid two blueprints clobbering it, this module
# renders one merged blueprint per host that owns every registered
# forward-auth app's provider/application/policy-binding *and* the
# outpost's providers list, then contributes the dir via
# `myAuthentik.extraBlueprints`.
#
# OIDC specifics: each registered OIDC app gets one sops secret pair
# (oidc_client_id / oidc_client_secret unless `publicClient`).
# Worker-side env vars (consumed by `!Env` in the per-app blueprint)
# are merged into a single env file stacked once onto authentik's
# units, regardless of how many OIDC apps are registered. Whether the
# app gets its own env file too depends on how it consumes credentials:
# env-reading apps (mealie, miniflux, paperless-ngx, tandoor, komga,
# actualbudget) get one; DB/UI-configured apps (audiobookshelf, kavita,
# seerr) skip it. Apps with non-OIDC env secrets (grimmory's db
# password) opt in via `extraEnvLines`.
#
# Secrets in blueprints (user passwords, OAuth client secrets, token
# values) are passed via `!Env VAR_NAME`; the `VAR_NAME` is rendered
# into the systemd EnvironmentFile from sops, so the secret never lands
# in /nix/store. Add the corresponding env line to
# `sops.templates."authentik.env"` whenever a new `!Env` reference is
# introduced.
{ inputs, ... }:
{
  flake.modules.nixos.authentik =
    {
      config,
      hostSpec,
      lib,
      pkgs,
      ...
    }:
    let
      authentikHost = "authentik.${hostSpec.serverDomain}";
      authentikPort = 9000;
      sopsSecretNames = [
        "secret_key"
        "bootstrap_email"
        "bootstrap_password"
        "bootstrap_token"
        "ian_password"
      ];
      restartAuthentik = [
        "authentik.service"
        "authentik-worker.service"
        "authentik-migrate.service"
      ];

      fwApps = config.myAuthentik.forwardAuthApps;
      fwAppNames = lib.attrNames fwApps;

      inherit (config.myAuthentik) oidcApps;

      ldapEnabled = config.myAuthentik.ldap.enable;
      ldapPort = 3389;

      # One YAML entry block per forward-auth app: provider, application,
      # policy binding. `id:` anchors are used inside this same blueprint
      # by `!KeyOf` so the application can reference its own provider
      # without a managed-name lookup. Entries are indented two spaces
      # so they slot directly under the top-level `entries:` key.
      perFwAppEntries = name: app: ''
        - model: authentik_providers_proxy.proxyprovider
          id: prov-${name}
          identifiers:
            name: ${name}
          attrs:
            mode: forward_single
            external_host: https://${app.host}
            authentication_flow: !Find [authentik_flows.flow, [slug, default-authentication-flow]]
            authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
            invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]

        - model: authentik_core.application
          id: app-${name}
          identifiers:
            slug: ${name}
          attrs:
            name: ${app.displayName}
            provider: !KeyOf prov-${name}
            group: ${app.authentikGroup}
            open_in_new_tab: true
            meta_launch_url: https://${app.host}
            meta_icon: ${app.iconUrl}
            policy_engine_mode: all

        - model: authentik_policies.policybinding
          identifiers:
            target: !KeyOf app-${name}
            order: 0
          attrs:
            group: !Find [authentik_core.group, [name, ${app.authentikGroup}]]
            enabled: true'';

      # The separator must match the column the first item lands at
      # after the indented-string strip. `${outpostProviders}` sits at
      # column 6 in the rendered output, so subsequent items need six
      # leading spaces to share that column — using anything else makes
      # the second item parse as a child of the first.
      outpostProviders = lib.concatMapStringsSep "\n      " (
        n: "- !Find [authentik_providers_proxy.proxyprovider, [name, ${n}]]"
      ) fwAppNames;

      # `config.authentik_host` is the base URL the outpost uses to reach
      # the authentik server; `authentik_host_browser` is the base URL
      # the outpost emits in 302 Location headers for unauthenticated
      # requests. With both unset, the outpost falls back to its bind
      # address (http://0.0.0.0:9000), which a browser can't resolve
      # and which leaks an HTTP hop into otherwise-HTTPS auth flows.
      # The default has been silently broken on every fresh authentik
      # install — hpp-1 only worked because the field was set by hand
      # in the UI before this blueprint existed. Encoding it here makes
      # forward-auth deterministic across hosts (and incidentally lets
      # gatus's external probes follow the redirect over HTTPS, so the
      # cert-expiration condition succeeds).
      outpostEntry = ''
        - model: authentik_outposts.outpost
          identifiers:
            name: authentik Embedded Outpost
          attrs:
            type: proxy
            providers:
              ${outpostProviders}
            config:
              authentik_host: https://authentik.${hostSpec.serverDomain}
              authentik_host_browser: https://authentik.${hostSpec.serverDomain}'';

      fwBlueprintContent = ''
        version: 1
        metadata:
          name: forward-auth-apps
        entries:
        ${lib.concatStringsSep "\n\n" ((lib.mapAttrsToList perFwAppEntries fwApps) ++ [ outpostEntry ])}
      '';

      fwBlueprintDir = pkgs.writeTextDir "forward-auth-apps.yaml" fwBlueprintContent;

      # Pre-render an OIDC app's blueprint dir: copy each *.yaml in and
      # substitute `@serverDomain@` → `hostSpec.serverDomain`. Substitution
      # happens per-contributor here rather than as a sed pass over the
      # final merged dir — that pass would silently mangle any YAML value
      # containing the literal string for an unrelated purpose (closes
      # #154). `fwBlueprintDir` above sidesteps the placeholder entirely
      # by interpolating the domain into the Nix string at write time;
      # any new blueprint-contribution path must do one or the other.
      renderedBlueprintDir =
        name: src:
        pkgs.runCommandLocal "${name}-blueprints-rendered" { } ''
          mkdir $out
          cp -L ${src}/*.yaml $out/
          chmod -R u+w $out
          substituteInPlace $out/*.yaml \
            --replace-quiet '@serverDomain@' '${hostSpec.serverDomain}'
        '';

      homepageSubmodule = lib.types.submodule (_: {
        options = {
          group = lib.mkOption {
            type = lib.types.str;
            description = ''
              Homepage layout group this app appears under. Required:
              no implicit default — set this per app so tiles land in
              the right group instead of all defaulting to one place.
            '';
          };
          icon = lib.mkOption {
            type = lib.types.str;
            description = "homepage icon slug (resolves against dashboard-icons).";
          };
          description = lib.mkOption {
            type = lib.types.str;
            description = "Short blurb shown beneath the app on the homepage tile.";
          };
        };
      });

      # Restart units for an app's OIDC sops secret. Always bounces
      # authentik (so the worker sees the new placeholder when the
      # blueprint is re-applied); also bounces the app's own service
      # iff the app reads creds from its env file.
      oidcSecretRestartUnits =
        app: restartAuthentik ++ lib.optionals app.clientCredsInAppEnv app.appRestartUnit;

      mkOidcSecret = _appName: app: {
        inherit (hostSpec) sopsFile;
        restartUnits = oidcSecretRestartUnits app;
      };

      # Worker-side env line for one OIDC app. Uppercased app name keeps
      # the existing `<APP>_OIDC_CLIENT_*` convention every blueprint
      # references via `!Env`.
      oidcWorkerEnvLines =
        appName: app:
        let
          upper = lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] appName);
          idLine = "${upper}_OIDC_CLIENT_ID=${config.sops.placeholder."${appName}/oidc_client_id"}";
          secretLine = "${upper}_OIDC_CLIENT_SECRET=${
            config.sops.placeholder."${appName}/oidc_client_secret"
          }";
        in
        if app.publicClient then idLine + "\n" else idLine + "\n" + secretLine + "\n";

      # Per-app env file content. Combines configurable client-id/secret
      # env vars (when `clientCredsInAppEnv`) with whatever extra lines
      # the app needs (db password, secret_key, inline-JSON env vars).
      oidcAppEnvContent =
        appName: app:
        let
          idLine = "${app.clientIdVar}=${config.sops.placeholder."${appName}/oidc_client_id"}";
          secretLine = "${app.clientSecretVar}=${config.sops.placeholder."${appName}/oidc_client_secret"}";
          credsBlock =
            if !app.clientCredsInAppEnv then
              ""
            else if app.publicClient then
              idLine + "\n"
            else
              idLine + "\n" + secretLine + "\n";
        in
        credsBlock + app.extraEnvLines;

      oidcWorkerEnvContent = lib.concatStrings (lib.mapAttrsToList oidcWorkerEnvLines oidcApps);

      # Stack upstream blueprints + every contributed dir + this module's
      # local set into a single real-file directory. Copy with `-L` to
      # dereference: authentik's `retrieve_file` calls
      # `Path(...).resolve()` on every blueprint and rejects anything
      # that resolves outside `blueprints_dir`, so `symlinkJoin` (top-level
      # entries are symlinks back to source store paths) makes every
      # apply fail with "Invalid blueprint path".
      #
      # `@serverDomain@` substitution is not done here. Each contributor
      # that uses the placeholder renders its own files first: OIDC app
      # blueprints go through `renderedBlueprintDir` above;
      # `fwBlueprintDir` interpolates the domain via Nix strings. This
      # module's local `./authentik-blueprints/*.yaml` files don't
      # reference the placeholder, so they cp in unmodified.
      mergedBlueprints = pkgs.runCommandLocal "authentik-blueprints-merged" { } ''
        mkdir -p $out
        cp -rL ${config.services.authentik.authentikComponents.staticWorkdirDeps}/blueprints/. $out/
        ${lib.concatMapStringsSep "\n" (p: "cp -rL ${p}/. $out/") config.myAuthentik.extraBlueprints}
        cp -rL ${./authentik-blueprints}/. $out/
        chmod -R u+w $out
      '';
    in
    {
      imports = [
        inputs.authentik-nix.nixosModules.default
      ];

      options.myAuthentik = {
        extraBlueprints = lib.mkOption {
          type = lib.types.listOf lib.types.path;
          default = [ ];
          description = ''
            Extra blueprint directories or files to merge into authentik's
            blueprints_dir alongside the bundled defaults. Each entry is a
            path containing one or more *.yaml blueprint files. Other app
            modules can append their own blueprints here so each app stays
            self-contained.
          '';
        };

        forwardAuthApps = lib.mkOption {
          default = { };
          description = ''
            Apps gated by authentik forward-auth via Caddy. Each entry
            generates an authentik proxy provider + application + policy
            binding (default group: Infrastructure), plus a Caddy route
            and (optionally) a homepage tile. One blueprint owns the
            embedded outpost's `providers` list, so every forward-auth
            app on the host must register through this option rather than
            emitting its own outpost block.
          '';
          type = lib.types.attrsOf (
            lib.types.submodule (
              { name, ... }:
              {
                options = {
                  host = lib.mkOption {
                    type = lib.types.str;
                    default = "${name}.${hostSpec.serverDomain}";
                    description = "External hostname Caddy matches and authentik enforces.";
                  };
                  port = lib.mkOption {
                    type = lib.types.port;
                    description = "Loopback port the upstream container exposes on the host.";
                  };
                  displayName = lib.mkOption {
                    type = lib.types.str;
                    description = "Human-facing app name (authentik tile + homepage label).";
                  };
                  iconUrl = lib.mkOption {
                    type = lib.types.str;
                    default = "https://raw.githubusercontent.com/homarr-labs/dashboard-icons/main/png/${name}.png";
                    description = "Icon URL used on the authentik application tile.";
                  };
                  authentikGroup = lib.mkOption {
                    type = lib.types.str;
                    default = "Infrastructure";
                    description = ''
                      Authentik group whose members can access this app via
                      the policy binding. Defaults to Infrastructure (admin
                      tools); set to Users for end-user-facing apps.
                    '';
                  };
                  proxyConfig = lib.mkOption {
                    type = lib.types.lines;
                    default = "";
                    description = ''
                      Extra directives spliced into the caddy `reverse_proxy`
                      body. Use this to inject `header_up` lines for apps
                      that consume authentik headers (e.g. readeck reading
                      Remote-User from X-authentik-username).
                    '';
                  };
                  bypassAuthPaths = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    default = [ ];
                    example = [
                      "/api/*"
                      "/ping"
                    ];
                    description = ''
                      Caddy `path` patterns that skip forward_auth and reach
                      the upstream directly. Use for apps that ship their
                      own API-key auth on a sub-path (sonarr/radarr at
                      /api/*, RSS calendars at /feed/*) so non-browser
                      clients can authenticate with the app's native scheme
                      instead of getting redirected to the authentik login
                      flow. Empty (default) gates every path through
                      authentik. Patterns follow Caddy `path` matcher
                      semantics: `/foo/*` is a prefix match on `/foo/`,
                      anything without a trailing `*` is an exact match.
                    '';
                  };
                  homepage = lib.mkOption {
                    type = lib.types.nullOr homepageSubmodule;
                    default = null;
                    description = ''
                      Homepage tile metadata. Set to null (default) to
                      skip generating a tile. When set, `group` is
                      required so the tile lands in the right section
                      instead of defaulting to a catch-all.
                    '';
                  };
                };
              }
            )
          );
        };

        ldap = {
          enable = lib.mkEnableOption ''
            authentik's LDAP outpost. Renders the LDAP provider /
            application / ldapservice user blueprint, wires the
            worker-side bind password, and starts `services.authentik-
            ldap` against a sops-templated env file. Used by apps
            (jellyfin) that can only authenticate against authentik
            via LDAP — TV/native clients don't do OIDC redirects, so
            same-credentials login is the goal, not full SSO.

            One-time manual setup is required to capture the outpost
            token: see the Jellyfin section of the README.
          '';
        };

        oidcApps = lib.mkOption {
          default = { };
          description = ''
            Apps that authenticate against Authentik via OIDC directly
            (the app speaks OIDC; we do not use the embedded outpost).
            Each entry generates the sops secret pair, contributes a
            blueprint dir, and stacks a single merged worker env file
            onto Authentik so blueprint `!Env` placeholders resolve.

            Apps that read OIDC creds from env vars also get a per-app
            env file the upstream image consumes. Apps that read OIDC
            creds from their own database (audiobookshelf, kavita,
            seerr) opt out by setting `clientCredsInAppEnv = false`.
          '';
          type = lib.types.attrsOf (
            lib.types.submodule (
              { name, ... }:
              {
                options = {
                  blueprintsDir = lib.mkOption {
                    type = lib.types.path;
                    description = ''
                      Path to a directory of *.yaml blueprint files for
                      this app. The dir is contributed via
                      `myAuthentik.extraBlueprints` and merged into
                      authentik's blueprints_dir.
                    '';
                  };
                  appRestartUnit = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    default = [ ];
                    description = ''
                      Systemd units to restart when the per-app env
                      file changes. Required (non-empty) when
                      `clientCredsInAppEnv` is true or `extraEnvLines`
                      is non-empty. Leave as the empty default for
                      apps with no per-app env file (e.g.
                      audiobookshelf, kavita, seerr — all DB/UI
                      configured). Pass every unit that consumes the
                      env file (e.g. paperless-ngx with
                      paperless-{web,scheduler,consumer,task-queue})
                      so they all bounce on credential rotation.
                    '';
                  };
                  publicClient = lib.mkOption {
                    type = lib.types.bool;
                    default = false;
                    description = ''
                      True for OIDC public clients (PKCE, no
                      client_secret). When true, only oidc_client_id
                      is provisioned; client_secret is omitted from
                      both sops and the env files.
                    '';
                  };
                  clientCredsInAppEnv = lib.mkOption {
                    type = lib.types.bool;
                    default = true;
                    description = ''
                      Whether the per-app env file should include the
                      OIDC client_id (and client_secret unless
                      `publicClient`). Set to false when the app reads
                      these from its own database/UI rather than env.
                    '';
                  };
                  envFileName = lib.mkOption {
                    type = lib.types.str;
                    default = "${name}.env";
                    description = ''
                      Name of the sops template the per-app env file is
                      registered under. Reference it in the upstream
                      service via `config.sops.templates."<name>".path`.
                    '';
                  };
                  clientIdVar = lib.mkOption {
                    type = lib.types.str;
                    default = "OIDC_CLIENT_ID";
                    description = "Env var name the upstream image reads for the OIDC client id.";
                  };
                  clientSecretVar = lib.mkOption {
                    type = lib.types.str;
                    default = "OIDC_CLIENT_SECRET";
                    description = "Env var name the upstream image reads for the OIDC client secret.";
                  };
                  extraEnvLines = lib.mkOption {
                    type = lib.types.lines;
                    default = "";
                    description = ''
                      Extra `KEY=value` lines appended to the per-app
                      env file. Use this for db passwords, secret keys,
                      or inline-JSON env vars whose values come from
                      other sops placeholders. Whatever placeholders
                      this string references must be declared via
                      `extraSecrets`.
                    '';
                  };
                  extraSecrets = lib.mkOption {
                    type = lib.types.attrsOf lib.types.attrs;
                    default = { };
                    description = ''
                      Additional sops secret declarations merged into
                      sops.secrets. Use this for db passwords, signing
                      keys, etc. that the per-app env file references
                      via `extraEnvLines`.
                    '';
                  };
                  homepage = lib.mkOption {
                    type = lib.types.nullOr homepageSubmodule;
                    default = null;
                    description = ''
                      Homepage tile metadata. Set to null (default) to
                      skip generating a tile.
                    '';
                  };
                  displayName = lib.mkOption {
                    type = lib.types.str;
                    default = name;
                    description = ''
                      Human-facing app name (authentik tile + homepage
                      label). Defaults to the attribute name.
                    '';
                  };
                };
              }
            )
          );
        };
      };

      config = lib.mkMerge [
        {
          sops.secrets = builtins.listToAttrs (
            map (n: {
              name = "authentik/${n}";
              value = {
                inherit (hostSpec) sopsFile;
                restartUnits = restartAuthentik;
              };
            }) sopsSecretNames
          );

          # Authentik uses DynamicUser; real on-disk state (UI-uploaded
          # icons, certs, branding assets) lives at /var/lib/private/authentik.
          # Postgres dump covers blueprint-managed objects; this is the
          # gap closer. Restic doesn't follow symlinks, so /var/lib/authentik
          # (a symlink) would capture only the link. Closes #120.
          preservation.preserveAt."/persist".directories = [ "/var/lib/private/authentik" ];
          services.restic.backups.server.paths = [ "/var/lib/private/authentik" ];

          # authentik-nix hardcodes DynamicUser=true across server/worker/
          # migrate (and the optional outpost units) with no exposed user
          # override. We can't cleanly pin a static UID without `mkForce`-ing
          # every unit and tracking the set as the flake evolves.
          #
          # On systemd 258+, DynamicUser + StateDirectory mounts the state
          # dir with `idmapped` (visible in /proc/<pid>/mountinfo). The
          # on-disk uid stays at a fixed sentinel (nobody/65534); the
          # kernel translates that to the dynamic uid (currently 65454)
          # inside the unit's mount namespace, so authentik sees files as
          # its own and writes new ones that land back at 65534 on disk.
          # When the invariant holds, no chown is needed.
          #
          # The hazard is stale state that pre-dates the idmap or got
          # rewritten outside the idmapped mount: files literally owned
          # by 65454 on disk (which is what authentik saw under earlier
          # systemd, or what a `chown -R authentik` run from the host's
          # mount namespace would write). uid 65454 on disk has no reverse
          # mapping, so the kernel surfaces it as the overflow uid (nobody)
          # inside the namespace, and authentik can't write to its own
          # prometheus counters — the failure mode that took hpp-1 down
          # on May 27. The previous `authentik-state-chown` unit was
          # supposed to heal this but ran `Before=authentik.service`
          # (when nss-systemd has no record of the dynamic user), so
          # `id authentik` failed, the guarding `if` silently skipped,
          # and the unit reported success.
          #
          # ExecStartPre runs inside the unit's mount namespace after
          # systemd has set up the idmap and registered the dynamic uid
          # with nss-systemd. `chown authentik:authentik` through the
          # idmapped mount writes the on-disk sentinel uid back, healing
          # any stale 65454 inodes in place. The `+` prefix runs as root
          # so the chown can cross arbitrary ownership boundaries. Migrate
          # runs Before=server/worker, so healing here covers the stack;
          # a chown failure now fails the unit and blocks ExecStart
          # instead of silently letting authentik come up wedged.
          systemd.services.authentik-migrate.serviceConfig.ExecStartPre = [
            "+${pkgs.writeShellScript "authentik-state-chown" ''
              ${pkgs.coreutils}/bin/chown -R authentik:authentik /var/lib/private/authentik
            ''}"
          ];

          # Real readiness boundary for the authentik stack. The three
          # native units (server / worker / migrate) are all Type=simple,
          # so systemd considers them "active" as soon as the process
          # execs — long before Django finishes loading and answers HTTP.
          # Apps that fetch the OIDC discovery URL once at startup hit
          # the Go front-end on :9000, which proxies to a not-yet-listening
          # Django worker and surfaces 502 Bad Gateway. /-/health/ready/
          # returns 200 only after Django can answer, so probing it gives
          # dependents a real readiness gate. Closes #200.
          systemd.services.authentik-ready = {
            description = "Wait for authentik to serve 200 on /-/health/ready/";
            after = [
              "authentik.service"
              "authentik-worker.service"
            ];
            wants = [
              "authentik.service"
              "authentik-worker.service"
            ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              TimeoutStartSec = "180s";
            };
            script = ''
              until ${pkgs.curl}/bin/curl -fsS -o /dev/null \
                -m 3 http://localhost:${toString authentikPort}/-/health/ready/; do
                sleep 2
              done
            '';
          };

          sops.templates."authentik.env" = {
            content = ''
              AUTHENTIK_SECRET_KEY=${config.sops.placeholder."authentik/secret_key"}
              AUTHENTIK_BOOTSTRAP_EMAIL=${config.sops.placeholder."authentik/bootstrap_email"}
              AUTHENTIK_BOOTSTRAP_PASSWORD=${config.sops.placeholder."authentik/bootstrap_password"}
              AUTHENTIK_BOOTSTRAP_TOKEN=${config.sops.placeholder."authentik/bootstrap_token"}
              IAN_PASSWORD=${config.sops.placeholder."authentik/ian_password"}
            '';
            restartUnits = restartAuthentik;
          };

          services = {
            authentik = {
              enable = true;
              environmentFile = config.sops.templates."authentik.env".path;
              # createDatabase = true (default) adds authentik to the shared
              # postgres via ensureDatabases/ensureUsers and points the app at
              # the unix socket; DynamicUser=authentik + peer auth means no
              # role password is required.
              settings = {
                disable_startup_analytics = true;
                avatars = "initials";
                blueprints_dir = "${mergedBlueprints}";
              };
            };

            # Authentik defaults to redis://localhost:6379. Use the unnamed
            # NixOS redis instance (services.redis.servers."") so the default
            # config works as-is.
            redis.servers."" = {
              enable = true;
              port = 6379;
            };

            # Reusable snippet for protected apps on this host: a route
            # block can `import authentik_forward_auth` and the embedded
            # outpost gates the request. The /outpost.goauthentik.io/*
            # routes are reverse-proxied with `handle` (not `handle_path`)
            # so the path prefix is preserved when forwarded to authentik
            # — the outpost serves its login flow at the original URI.
            caddy.extraConfig = ''
              (authentik_forward_auth) {
                forward_auth localhost:${toString authentikPort} {
                  uri /outpost.goauthentik.io/auth/caddy
                  copy_headers X-authentik-username X-authentik-groups X-authentik-entitlements X-authentik-email X-authentik-name X-authentik-uid X-authentik-jwt X-authentik-meta-jwks X-authentik-meta-outpost X-authentik-meta-provider X-authentik-meta-app X-authentik-meta-version
                  trusted_proxies private_ranges
                }
                handle /outpost.goauthentik.io/* {
                  reverse_proxy localhost:${toString authentikPort}
                }
              }
            '';
          };

          myCaddy.apps.authentik = {
            host = authentikHost;
            routeConfig = ''
              reverse_proxy localhost:${toString authentikPort}
            '';
          };

          # User blueprints (names, emails, group bindings) live in the
          # private nix-secrets repo rather than this public flake.
          # `!Env IAN_PASSWORD` still resolves from sops.templates."authentik.env".
          myAuthentik.extraBlueprints = [ "${inputs.nix-secrets}/authentik-blueprints" ];

          myHomepage.tiles.Authentik = {
            group = "Infrastructure";
            href = "https://${authentikHost}";
            icon = "authentik";
            description = "SSO";
          };
        }

        (lib.mkIf (fwApps != { }) {
          myAuthentik.extraBlueprints = [ fwBlueprintDir ];

          myCaddy.apps = lib.mapAttrs (
            _name: app:
            let
              upstream = "localhost:${toString app.port}";
              gatedBlock =
                if app.proxyConfig == "" then
                  ''
                    import authentik_forward_auth
                    reverse_proxy ${upstream}
                  ''
                else
                  ''
                    import authentik_forward_auth
                    reverse_proxy ${upstream} {
                      ${app.proxyConfig}
                    }
                  '';
            in
            {
              inherit (app) host;
              routeConfig =
                if app.bypassAuthPaths == [ ] then
                  gatedBlock
                else
                  # Split into two `handle` blocks: bypassAuthPaths reach
                  # the upstream raw (the app's own auth scheme — typically
                  # an API key — gates them); everything else still goes
                  # through forward_auth. `proxyConfig` is applied only to
                  # the gated block since its main use is forwarding
                  # X-authentik-* headers, which don't exist on bypassed
                  # requests.
                  ''
                    @bypass_auth path ${lib.concatStringsSep " " app.bypassAuthPaths}
                    handle @bypass_auth {
                      reverse_proxy ${upstream}
                    }
                    handle {
                      ${gatedBlock}
                    }
                  '';
            }
          ) fwApps;

          myHomepage.tiles = lib.mapAttrs (_name: app: {
            inherit (app.homepage) group icon description;
            inherit (app) displayName;
            href = "https://${app.host}";
          }) (lib.filterAttrs (_: app: app.homepage != null) fwApps);
        })

        (lib.mkIf (oidcApps != { }) {
          # OIDC client_id/_secret per app, plus any extras the app declares.
          sops.secrets =
            (lib.foldl' lib.mergeAttrs { } (
              lib.mapAttrsToList (
                appName: app:
                {
                  "${appName}/oidc_client_id" = mkOidcSecret appName app;
                }
                // lib.optionalAttrs (!app.publicClient) {
                  "${appName}/oidc_client_secret" = mkOidcSecret appName app;
                }
              ) oidcApps
            ))
            // (lib.foldl' lib.mergeAttrs { } (lib.mapAttrsToList (_: app: app.extraSecrets) oidcApps));

          # Per-app env file. Always declared (lazy) — apps that don't
          # need it (DB/UI-configured) end up with an empty file that
          # nothing references. Filtering eagerly here would force
          # `extraEnvLines` and create a cycle through sops.placeholder.
          sops.templates =
            (lib.mapAttrs' (
              appName: app:
              lib.nameValuePair app.envFileName {
                content = oidcAppEnvContent appName app;
                restartUnits = app.appRestartUnit;
              }
            ) oidcApps)
            //
            # ONE merged worker env file containing <APP>_OIDC_CLIENT_*
            # vars for every registered OIDC app — stacked once onto
            # authentik's units instead of N times.
            {
              "authentik-oidc-apps.env" = {
                content = oidcWorkerEnvContent;
                restartUnits = restartAuthentik;
              };
            };

          systemd.services = lib.mkMerge [
            {
              authentik.serviceConfig.EnvironmentFile = [
                config.sops.templates."authentik-oidc-apps.env".path
              ];
              authentik-worker.serviceConfig.EnvironmentFile = [
                config.sops.templates."authentik-oidc-apps.env".path
              ];
              authentik-migrate.serviceConfig.EnvironmentFile = [
                config.sops.templates."authentik-oidc-apps.env".path
              ];
            }
            # Inject After=authentik-ready.service on every OIDC app's
            # restart units so apps that probe the OIDC discovery URL at
            # startup don't race the Django worker. Apps with empty
            # appRestartUnit (DB/UI-configured: audiobookshelf, kavita,
            # seerr) end up no-op'd through genAttrs and are immune to
            # the race anyway.
            (lib.mkMerge (
              lib.mapAttrsToList (
                _appName: app:
                lib.genAttrs (map (lib.removeSuffix ".service") app.appRestartUnit) (_: {
                  after = [ "authentik-ready.service" ];
                  wants = [ "authentik-ready.service" ];
                })
              ) oidcApps
            ))
          ];

          myAuthentik.extraBlueprints = lib.mapAttrsToList (
            appName: app: renderedBlueprintDir appName app.blueprintsDir
          ) oidcApps;

          myHomepage.tiles = lib.mapAttrs (name: app: {
            inherit (app.homepage) group icon description;
            inherit (app) displayName;
            href = "https://${name}.${hostSpec.serverDomain}";
          }) (lib.filterAttrs (_: app: app.homepage != null) oidcApps);
        })

        # LDAP outpost. Blueprint creates the LDAP provider + app +
        # outpost record; authentik auto-creates the outpost's SA user
        # and API token at save time. The `token_identifier` field on
        # the Outpost model is a computed property, not a writable DB
        # column, so the goauthentik/authentik#9711 workaround of
        # pre-creating the SA + token doesn't actually take effect.
        # We fetch the auto-generated token via the admin API in a
        # NixOS oneshot using the existing bootstrap token, and write
        # it to a runtime env file the outpost reads.
        (lib.mkIf ldapEnabled {
          sops.secrets."authentik/ldap_service_password" = {
            inherit (hostSpec) sopsFile;
            restartUnits = restartAuthentik;
          };

          # Worker-side env so `!Env LDAP_SERVICE_PASSWORD` resolves in
          # the blueprint (the worker is what applies blueprints).
          sops.templates."authentik-ldap-worker.env" = {
            content = ''
              LDAP_SERVICE_PASSWORD=${config.sops.placeholder."authentik/ldap_service_password"}
            '';
            restartUnits = restartAuthentik;
          };

          myAuthentik.extraBlueprints = [ ./authentik-blueprints-ldap ];

          systemd.services = {
            authentik.serviceConfig.EnvironmentFile = [
              config.sops.templates."authentik-ldap-worker.env".path
            ];
            authentik-worker.serviceConfig.EnvironmentFile = [
              config.sops.templates."authentik-ldap-worker.env".path
            ];
            authentik-migrate.serviceConfig.EnvironmentFile = [
              config.sops.templates."authentik-ldap-worker.env".path
            ];

            # Fetch the outpost's auto-generated API token via the
            # admin API (using the existing bootstrap token), and
            # render an env file the outpost reads. Polls until the
            # blueprint has applied and the outpost record exists.
            authentik-ldap-token-fetcher = {
              description = "Fetch authentik LDAP outpost API token and stage env file";
              after = [ "authentik-ready.service" ];
              wants = [ "authentik-ready.service" ];
              wantedBy = [ "authentik-ldap.service" ];
              before = [ "authentik-ldap.service" ];
              path = with pkgs; [
                curl
                jq
                coreutils
              ];
              serviceConfig = {
                Type = "oneshot";
                # Own a private RuntimeDirectory so the env file isn't
                # under authentik-ldap.service's RuntimeDirectory
                # (systemd wipes that one every time the outpost
                # restarts, taking our env file with it). The outpost
                # service reads from this path directly.
                RuntimeDirectory = "authentik-ldap-token";
                RuntimeDirectoryPreserve = "yes";
                RemainAfterExit = true;
                # bootstrap_token is owned by sops-nix as 0400; let
                # this oneshot read it (root, no special user).
                LoadCredential = "bootstrap_token:${config.sops.secrets."authentik/bootstrap_token".path}";
              };
              script = ''
                set -uo pipefail
                BOOTSTRAP_TOKEN="$(cat "$CREDENTIALS_DIRECTORY/bootstrap_token")"
                HOST="http://localhost:${toString authentikPort}"

                # Poll until the outpost exists and has a token_identifier.
                # First deploy: authentik-ready fires when /-/health/ready
                # returns 200, but the worker may still be loading the
                # blueprint, and /api/v3 may briefly 503 while Django
                # initialises. Don't `set -e` over curl — retry instead.
                outpost=""
                for _ in $(seq 1 60); do
                  resp="$(curl -sS \
                    -H "Authorization: Bearer $BOOTSTRAP_TOKEN" \
                    "$HOST/api/v3/outposts/instances/?name__iexact=ldap" \
                    2>/dev/null || true)"
                  outpost="$(echo "$resp" \
                    | jq -r '.results[]? | select(.name == "ldap") | .token_identifier' \
                    2>/dev/null || true)"
                  [ -n "$outpost" ] && [ "$outpost" != "null" ] && break
                  sleep 2
                done
                if [ -z "$outpost" ] || [ "$outpost" = "null" ]; then
                  echo "LDAP outpost not found after 120s" >&2
                  exit 1
                fi

                key=""
                for _ in $(seq 1 10); do
                  resp="$(curl -sS \
                    -H "Authorization: Bearer $BOOTSTRAP_TOKEN" \
                    "$HOST/api/v3/core/tokens/$outpost/view_key/" \
                    2>/dev/null || true)"
                  key="$(echo "$resp" | jq -r '.key // empty' 2>/dev/null || true)"
                  [ -n "$key" ] && break
                  sleep 2
                done
                if [ -z "$key" ]; then
                  echo "Empty token from view_key endpoint" >&2
                  exit 1
                fi

                # RuntimeDirectory= creates /run/authentik-ldap-token
                # with mode 0755 and owner=root. The outpost service
                # runs as a DynamicUser, so we can't chown — make the
                # file world-readable. Token only grants view perms on
                # this outpost+provider; full secret hygiene would need
                # outpost.service forking, not worth it here.
                {
                  printf 'AUTHENTIK_HOST=%s\n' "$HOST"
                  printf 'AUTHENTIK_TOKEN=%s\n' "$key"
                  printf 'AUTHENTIK_INSECURE=true\n'
                  printf 'AUTHENTIK_LISTEN__LDAP=127.0.0.1:%s\n' '${toString ldapPort}'
                } >/run/authentik-ldap-token/env
                chmod 0444 /run/authentik-ldap-token/env
              '';
            };

            # The outpost reads AUTHENTIK_TOKEN at startup; bounce it
            # whenever the token-fetcher refreshes the env file.
            authentik-ldap = {
              after = [
                "authentik-ready.service"
                "authentik-ldap-token-fetcher.service"
              ];
              wants = [
                "authentik-ready.service"
                "authentik-ldap-token-fetcher.service"
              ];
            };
          };

          services.authentik-ldap = {
            enable = true;
            environmentFile = "/run/authentik-ldap-token/env";
          };
        })
      ];
    };
}
