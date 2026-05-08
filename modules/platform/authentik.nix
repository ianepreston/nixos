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
#
# Forward-auth specifics: the embedded outpost has a single global
# `providers` list. To avoid two blueprints clobbering it, this module
# renders one merged blueprint per host that owns every registered
# forward-auth app's provider/application/policy-binding *and* the
# outpost's providers list, then contributes the dir via
# `myAuthentik.extraBlueprints`.
_: {
  flake.modules.nixos.myAuthentik =
    {
      config,
      hostSpec,
      lib,
      pkgs,
      ...
    }:
    let
      apps = config.myAuthentik.forwardAuthApps;
      appNames = lib.attrNames apps;

      # One YAML entry block per app: provider, application, policy
      # binding. `id:` anchors are used inside this same blueprint by
      # `!KeyOf` so the application can reference its own provider
      # without a managed-name lookup. Entries are indented two spaces
      # so they slot directly under the top-level `entries:` key.
      perAppEntries = name: app: ''
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
      ) appNames;

      outpostEntry = ''
        - model: authentik_outposts.outpost
          identifiers:
            name: authentik Embedded Outpost
          attrs:
            type: proxy
            providers:
              ${outpostProviders}'';

      blueprintContent = ''
        version: 1
        metadata:
          name: forward-auth-apps
        entries:
        ${lib.concatStringsSep "\n\n" ((lib.mapAttrsToList perAppEntries apps) ++ [ outpostEntry ])}
      '';

      blueprintDir = pkgs.writeTextDir "forward-auth-apps.yaml" blueprintContent;

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
      };

      config = lib.mkIf (apps != { }) {
        myAuthentik.extraBlueprints = [ blueprintDir ];

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
        }) apps;

        myHomepage.services = lib.foldl' (
          acc: name:
          let
            app = apps.${name};
          in
          if app.homepage == null then
            acc
          else
            let
              entry = {
                ${app.displayName} = {
                  href = "https://${app.host}";
                  inherit (app.homepage) icon description;
                };
              };
            in
            acc
            // {
              ${app.homepage.group} = (acc.${app.homepage.group} or [ ]) ++ [ entry ];
            }
        ) { } appNames;
      };
    };
}
