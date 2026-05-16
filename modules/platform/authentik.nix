# Authentik option surface (platform-tier).
# Owns the `myAuthentik` option namespace that app modules contribute
# to. The leaf service (the authentik-nix module that actually runs the
# IDP) is deployed by modules/apps/authentik.nix, which imports this
# module to read the accumulated blueprint contributions.
#
# Aggregators owned here:
#   * extraBlueprints   — list of blueprint dirs merged into authentik
#   * forwardAuthApps   — apps gated by the embedded outpost via Caddy
#                         forward_auth (was modules/apps/arr-auth.nix)
#   * oidcApps          — apps that speak OIDC against authentik directly
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
{ inputs, ... }:
let
  sopsFolder = (builtins.toString inputs.nix-secrets) + "/sops";
in
{
  flake.modules.nixos.myAuthentik =
    {
      config,
      hostSpec,
      lib,
      pkgs,
      ...
    }:
    let
      fwApps = config.myAuthentik.forwardAuthApps;
      fwAppNames = lib.attrNames fwApps;

      inherit (config.myAuthentik) oidcApps;

      restartAuthentik = [
        "authentik.service"
        "authentik-worker.service"
        "authentik-migrate.service"
      ];

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

      outpostEntry = ''
        - model: authentik_outposts.outpost
          identifiers:
            name: authentik Embedded Outpost
          attrs:
            type: proxy
            providers:
              ${outpostProviders}'';

      fwBlueprintContent = ''
        version: 1
        metadata:
          name: forward-auth-apps
        entries:
        ${lib.concatStringsSep "\n\n" ((lib.mapAttrsToList perFwAppEntries fwApps) ++ [ outpostEntry ])}
      '';

      fwBlueprintDir = pkgs.writeTextDir "forward-auth-apps.yaml" fwBlueprintContent;

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
          weight = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
            description = ''
              Sort weight within the group (lower renders first). Null
              defers to the homepage tile default (0).
            '';
          };
        };
      });

      # appRestartUnit is `nullOr (either str (listOf str))` — normalize
      # it to a plain list so consumers don't have to special-case the
      # scalar form.
      appRestartUnits =
        app:
        if app.appRestartUnit == null then
          [ ]
        else if lib.isList app.appRestartUnit then
          app.appRestartUnit
        else
          [ app.appRestartUnit ];

      # Restart units for an app's OIDC sops secret. Always bounces
      # authentik (so the worker sees the new placeholder when the
      # blueprint is re-applied); also bounces the app's own service
      # iff the app reads creds from its env file.
      oidcSecretRestartUnits =
        app: restartAuthentik ++ lib.optionals app.clientCredsInAppEnv (appRestartUnits app);

      mkOidcSecret = _appName: app: {
        sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
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
    in
    {
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
                    type = lib.types.nullOr (lib.types.either lib.types.str (lib.types.listOf lib.types.str));
                    default = null;
                    description = ''
                      Systemd unit (or list of units) to restart when
                      the per-app env file changes. Required when
                      `clientCredsInAppEnv` is true or `extraEnvLines`
                      is non-empty. Leave null for apps with no per-app
                      env file (e.g. audiobookshelf, kavita, seerr —
                      all DB/UI configured). Pass a list when an app
                      ships multiple systemd units that all consume
                      the env file (e.g. paperless-ngx with
                      paperless-{web,scheduler,consumer,task-queue}).
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
                  displayName = lib.mkOption {
                    type = lib.types.str;
                    default = name;
                    description = ''
                      Human-facing app name (homepage tile label).
                      Defaults to the attribute name.
                    '';
                  };
                  href = lib.mkOption {
                    type = lib.types.str;
                    default = "https://${name}.${hostSpec.serverDomain}";
                    description = ''
                      Homepage tile target URL. Defaults to
                      `https://<name>.<serverDomain>`.
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
                };
              }
            )
          );
        };
      };

      config = lib.mkMerge [
        (lib.mkIf (fwApps != { }) {
          myAuthentik.extraBlueprints = [ fwBlueprintDir ];

          myCaddy.apps = lib.mapAttrs (_name: app: {
            inherit (app) host;
            routeConfig =
              if app.proxyConfig == "" then
                ''
                  import authentik_forward_auth
                  reverse_proxy localhost:${toString app.port}
                ''
              else
                ''
                  import authentik_forward_auth
                  reverse_proxy localhost:${toString app.port} {
                    ${app.proxyConfig}
                  }
                '';
          }) fwApps;

          myHomepage.tiles = lib.mapAttrs (
            _name: app:
            {
              inherit (app.homepage) group icon description;
              inherit (app) displayName;
              href = "https://${app.host}";
            }
            // lib.optionalAttrs (app.homepage.weight != null) { inherit (app.homepage) weight; }
          ) (lib.filterAttrs (_: app: app.homepage != null) fwApps);
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
                restartUnits = appRestartUnits app;
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

          systemd.services = {
            authentik.serviceConfig.EnvironmentFile = [
              config.sops.templates."authentik-oidc-apps.env".path
            ];
            authentik-worker.serviceConfig.EnvironmentFile = [
              config.sops.templates."authentik-oidc-apps.env".path
            ];
            authentik-migrate.serviceConfig.EnvironmentFile = [
              config.sops.templates."authentik-oidc-apps.env".path
            ];
          };

          myAuthentik.extraBlueprints = lib.mapAttrsToList (_: app: app.blueprintsDir) oidcApps;

          myHomepage.tiles = lib.mapAttrs (
            _name: app:
            {
              inherit (app.homepage) group icon description;
              inherit (app) displayName href;
            }
            // lib.optionalAttrs (app.homepage.weight != null) { inherit (app.homepage) weight; }
          ) (lib.filterAttrs (_: app: app.homepage != null) oidcApps);
        })
      ];
    };
}
