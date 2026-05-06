# Home Assistant - smart-home automation hub
# Container; OIDC against authentik gated to the Home group. HA core
# has no native OIDC client — the auth_oidc HACS custom component
# (https://github.com/christiaangoossens/hass-oidc-auth) is the path
# we're targeting, so this module only stages the authentik side
# (provider/application/policy binding via blueprint, plus the env
# file so the worker can resolve `!Env` at apply time). After first
# boot, install HACS, install "OIDC Auth Provider", and feed it the
# client_id / client_secret from `homeassistant/oidc_client_*` in
# sops; the blueprint already pins the redirect URI to
# /auth/oidc/callback.
#
# Reverse proxy: HA needs `http.use_x_forwarded_for: true` and
# `trusted_proxies: 127.0.0.1` in `configuration.yaml` for the
# Caddy-proxied requests to be trusted, otherwise login fails with
# "400: Bad Request". configuration.yaml is owned by HA and edited
# through the UI, so it's not declaratively managed here — set this
# manually on first boot.
#
# IoT VLAN access (vlan30) is intentionally out of scope. When it's
# needed, options are: (a) attach a podman macvlan/ipvlan network to
# a VLAN sub-interface on the host and add it to the container's
# `networks`/`extraOptions`; (b) flip to host networking and create
# the VLAN interface on the host. Bridge mode with localhost port
# mapping (current setup) does not give the container L2 access to
# vlan30.
{ inputs, ... }:
let
  sopsFolder = (builtins.toString inputs.nix-secrets) + "/sops";
in
{
  flake.modules.nixos.homeassistant =
    {
      config,
      hostSpec,
      ...
    }:
    let
      homeassistantHost = "homeassistant.${hostSpec.serverDomain}";
      port = 8123;
      restartAuthentik = [
        "authentik.service"
        "authentik-worker.service"
        "authentik-migrate.service"
      ];
    in
    {
      sops.secrets = {
        "homeassistant/oidc_client_id" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          restartUnits = restartAuthentik;
        };
        "homeassistant/oidc_client_secret" = {
          sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          restartUnits = restartAuthentik;
        };
      };

      sops.templates."homeassistant-authentik.env" = {
        content = ''
          HOMEASSISTANT_OIDC_CLIENT_ID=${config.sops.placeholder."homeassistant/oidc_client_id"}
          HOMEASSISTANT_OIDC_CLIENT_SECRET=${config.sops.placeholder."homeassistant/oidc_client_secret"}
        '';
        restartUnits = restartAuthentik;
      };

      myAuthentik.extraBlueprints = [ ./homeassistant-blueprints ];

      systemd = {
        # HA writes to /config as root inside the container; we let the
        # container manage ownership and just ensure the host dir exists.
        tmpfiles.rules = [
          "d /var/lib/containers/homeassistant 0750 root root -"
        ];

        services = {
          authentik.serviceConfig.EnvironmentFile = [
            config.sops.templates."homeassistant-authentik.env".path
          ];
          authentik-worker.serviceConfig.EnvironmentFile = [
            config.sops.templates."homeassistant-authentik.env".path
          ];
          authentik-migrate.serviceConfig.EnvironmentFile = [
            config.sops.templates."homeassistant-authentik.env".path
          ];
        };
      };

      virtualisation.oci-containers.containers.homeassistant = {
        # renovate: datasource=docker depName=ghcr.io/home-assistant/home-assistant
        image = "ghcr.io/home-assistant/home-assistant:2025.11";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        volumes = [
          "/var/lib/containers/homeassistant:/config"
          "/run/dbus:/run/dbus:ro"
        ];
        environment = {
          TZ = config.time.timeZone;
        };
      };

      myCaddy.apps.homeassistant = {
        host = homeassistantHost;
        routeConfig = ''
          reverse_proxy localhost:${toString port}
        '';
      };

      myHomepage.services.Infrastructure = [
        {
          "Home Assistant" = {
            href = "https://${homeassistantHost}";
            icon = "home-assistant";
            description = "Smart home";
          };
        }
      ];
    };
}
