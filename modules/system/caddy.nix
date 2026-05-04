# Caddy - Simple Aspect
# Reverse proxy for server apps. App modules contribute their own
# services.caddy.virtualHosts entries; this module enables Caddy,
# opens HTTP/HTTPS in the firewall, and configures ACME with Let's
# Encrypt via the Cloudflare DNS-01 challenge.
#
# App virtualHosts should be declared without an "http://" prefix so
# Caddy auto-provisions a TLS cert. The Cloudflare API token comes
# from the host's sops file at cloudflare.acme_token.
{ inputs, ... }:
let
  sopsFolder = (builtins.toString inputs.nix-secrets) + "/sops";
in
{
  flake.modules.nixos.caddy =
    {
      config,
      pkgs,
      hostSpec,
      ...
    }:
    {
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
          hash = "sha256-/ooi0fP9zYzNnafaQqMnr6RmGh2onHrxDWiLE/aYNKI=";
        };
        globalConfig = ''
          acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}
        '';
      };

      sops.secrets."cloudflare/acme_token" = {
        sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
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
}
