# Spier & Mackay clearance scraper (https://github.com/ianepreston/spierscraper).
# Container is a oneshot run on a nightly timer that scrapes the
# clearance/odds-and-ends collections and posts Discord embeds for new
# matches; previously ran as a kubernetes CronJob in the old homelab
# repo. No web UI, so no caddy / authentik wiring.
_: {
  flake.modules.nixos.spierscraper =
    {
      config,
      pkgs,
      hostSpec,
      ...
    }:
    let
      # renovate: datasource=docker depName=ghcr.io/ianepreston/spierscraper
      image = "ghcr.io/ianepreston/spierscraper:2026.07.17.1";

      configFile = pkgs.writeText "spierscraper-config.yaml" ''
        filters:
          chinos:
            fits:
              - "Contemporary"
            sizes:
              - "33"
              - "34"
          sport_coats:
            fits:
              - "Contemporary"
            sizes:
              - "34R"
          shirts:
            fits:
              - "Contemporary"
            sizes:
              - "15.5/34"
          outerwear:
            sizes:
              - "M"
              - "L"
          knitwear:
            sizes:
              - "M"
        rate_limit_seconds: 1.5
        cache_ttl_hours: 24
        cache_path: "/data/cache"
      '';
    in
    {
      sops.secrets."discord/spierscraper_webhook" = {
        inherit (hostSpec) sopsFile;
      };

      sops.templates."spierscraper.env" = {
        content = ''
          DISCORD_WEBHOOK_URL=${config.sops.placeholder."discord/spierscraper_webhook"}
        '';
      };

      systemd = {
        tmpfiles.rules = [
          "d /var/lib/containers/spierscraper 0755 root root -"
          "d /var/lib/containers/spierscraper/cache 0755 root root -"
        ];

        services.spierscraper = {
          description = "Spier & Mackay clearance scraper";
          after = [
            "network-online.target"
            "podman.service"
            "flaresolverr.service"
          ];
          wants = [
            "network-online.target"
            # S&M now sit behind Cloudflare, which 403s plain HTTP clients.
            # The scraper primes its session (cookies + UA) through
            # FlareSolverr's headless browser; want it up first.
            "flaresolverr.service"
          ];
          serviceConfig = {
            Type = "oneshot";
            EnvironmentFile = config.sops.templates."spierscraper.env".path;
            ExecStart = pkgs.writeShellScript "spierscraper-run" ''
              exec ${pkgs.podman}/bin/podman run --rm \
                --env DISCORD_WEBHOOK_URL \
                --env FLARESOLVERR_URL=http://host.containers.internal:8191/v1 \
                -v ${configFile}:/config/config.yaml:ro \
                -v /var/lib/containers/spierscraper/cache:/data/cache \
                ${image} \
                -c /config/config.yaml
            '';
          };
        };

        timers.spierscraper = {
          description = "Run spierscraper nightly";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "*-*-* 04:05:00";
            Persistent = true;
            RandomizedDelaySec = "15m";
          };
        };
      };
    };
}
