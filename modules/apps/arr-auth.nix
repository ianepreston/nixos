# Shared forward-auth wiring for the *arr / acquisition stack.
# Each app declares itself via `myArrAuth.apps.<name>` with a port and a
# few display fields; this module generates the matching authentik
# blueprint (proxyprovider + application + policy binding) and the caddy
# route + homepage entry. The embedded outpost's `providers` list is
# rendered from the full set of registered apps so a single blueprint
# owns it — adding a new app extends the list rather than fighting a
# previous blueprint that overwrote it.
#
# Apps gated this way don't speak OIDC themselves. Authentik's embedded
# outpost handles the auth handshake via Caddy's forward_auth, then
# proxies the original request through to the upstream. Access is
# restricted to the Infrastructure group via a policy binding.
_: {
  flake.modules.nixos.arr-auth =
    {
      config,
      hostSpec,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (config.myArrAuth) apps;
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
          name: arr-stack
        entries:
        ${lib.concatStringsSep "\n\n" ((lib.mapAttrsToList perAppEntries apps) ++ [ outpostEntry ])}
      '';

      blueprintDir = pkgs.writeTextDir "arr-stack.yaml" blueprintContent;
    in
    {
      options.myArrAuth.apps = lib.mkOption {
        default = { };
        description = ''
          Apps gated by authentik forward-auth. Each entry generates a
          proxy provider + application + group policy binding (default
          group: Infrastructure), plus a caddy route and a homepage tile.
          One blueprint owns the embedded outpost's `providers` list, so
          every forward-auth app on the host must register through this
          option rather than emitting its own outpost block.
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
                homepageGroup = lib.mkOption {
                  type = lib.types.str;
                  default = "Acquisition";
                  description = "homepage layout group this app appears under.";
                };
                homepageIcon = lib.mkOption {
                  type = lib.types.str;
                  default = name;
                  description = "homepage icon slug (resolves against dashboard-icons).";
                };
                homepageDescription = lib.mkOption {
                  type = lib.types.str;
                  description = "Short blurb shown beneath the app on the homepage tile.";
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
              };
            }
          )
        );
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
            entry = {
              ${app.displayName} = {
                href = "https://${app.host}";
                icon = app.homepageIcon;
                description = app.homepageDescription;
              };
            };
          in
          acc
          // {
            ${app.homepageGroup} = (acc.${app.homepageGroup} or [ ]) ++ [ entry ];
          }
        ) { } appNames;
      };
    };
}
