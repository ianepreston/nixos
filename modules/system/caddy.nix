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
          # pins the plugin closure; bump it when the plugin version
          # changes (build will print the expected value).
          package = pkgs.caddy.withPlugins {
            plugins = [
              # renovate: datasource=github-tags depName=caddy-dns/cloudflare
              "github.com/caddy-dns/cloudflare@v0.2.4"
            ];
            hash = "sha256-bzMqxWTqrJ1skZmRTXyEMCKStXpljbqe5r0Ve2cnBfM=";
          };
          globalConfig = ''
            acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}
          '';

          virtualHosts."*.${hostSpec.serverDomain}".extraConfig =
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
              ${routes}
              handle {
                respond "Unknown service" 404
              }
            '';
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
