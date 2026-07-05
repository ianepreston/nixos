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
# `trusted_proxies: 10.88.0.1` (the podman bridge gateway) in
# `configuration.yaml`, otherwise login fails with "400: Bad
# Request". Caddy proxies to 127.0.0.1:8123, but netavark SNATs the
# ingress to the bridge gateway before it reaches the container, so
# HA sees the source as 10.88.0.1 — not 127.0.0.1.
# configuration.yaml is owned by HA and edited through the UI, so
# it's not declaratively managed here — set this manually on first
# boot.
#
# DHCP discovery: the container is not granted `CAP_NET_RAW`, so
# `aiodhcpwatcher` can't open AF_PACKET and spams "Operation not
# permitted" if the `dhcp` integration is loaded. Workaround in
# `configuration.yaml` on first boot: replace `default_config:` with
# its expanded dependency list minus `dhcp` (see
# components/default_config/manifest.json in the running container
# for the current list). SSDP/mDNS discovery via the macvlan still
# covers the bulk of IoT devices. Closes #201.
#
# IoT VLAN access: HA needs L2 reachability on vlan30 for mDNS /
# discovery / broadcast traffic. The vlan30 macvlan + dhcp-proxy stack
# is shared infrastructure owned by modules/system/iot-network.nix
# (Bambuddy is the other consumer); see that module for the topology
# and the L2-isolation caveats. HA just attaches the `iot` macvlan as a
# second NIC and orders its container after the shared units — its
# primary NIC stays on the default podman bridge so Caddy still reaches
# it on 127.0.0.1:8123. When hostSpec.iotTrunkInterface is null
# (quickemu test VMs) the stack is skipped and HA runs on the bridge
# only — discovery via vlan30 is lost but the container still starts.
_: {
  flake.modules.nixos.homeassistant =
    {
      config,
      hostSpec,
      lib,
      ...
    }:
    let
      homeassistantHost = "homeassistant.${hostSpec.serverDomain}";
      port = 8123;
      iotEnabled = hostSpec.iotTrunkInterface != null;
    in
    {
      # MQTT broker user. ACL grants HA full access — HA bridges every
      # publisher's topic via its own auto-discovery prefix and re-emits
      # state on the entity-level topics, so a narrower ACL would just
      # mean maintaining a per-publisher list here. Operator workflow
      # after first deploy: read the password with
      # `task secrets:view:hpp-1` (key: homeassistant.mqtt_password) and
      # paste it into HA's MQTT integration setup (Configuration →
      # Devices & Services → Add Integration → MQTT; broker
      # `10.88.0.1`, port `1883`, username `homeassistant`).
      # configuration.yaml is operator-owned (see comment above), so the
      # broker URL/credentials are not declaratively pushed.
      myMosquitto.users.homeassistant.acl = [ "readwrite #" ];

      myAuthentik.oidcApps.homeassistant = {
        blueprintsDir = ./homeassistant-blueprints;
        clientCredsInAppEnv = false;
        homepage = {
          group = "Home";
          icon = "home-assistant";
          description = "Smart home";
        };
        displayName = "Home Assistant";
      };

      systemd = {
        # HA writes to /config as root inside the container; we let the
        # container manage ownership and just ensure the host dir exists.
        tmpfiles.rules = [
          "d /var/lib/containers/homeassistant 0750 root root -"
        ];

        # Order the container after the shared vlan30 macvlan stack
        # (owned by modules/system/iot-network.nix) so podman doesn't
        # try to attach to a non-existent network on boot. The
        # `requires` edge is what pulls those units in.
        services = lib.mkIf iotEnabled {
          podman-homeassistant = {
            after = [
              "netavark-dhcp-proxy.service"
              "podman-network-iot.service"
            ];
            requires = [
              "netavark-dhcp-proxy.service"
              "podman-network-iot.service"
            ];
          };
        };
      };

      # Not migrated to myContainerApp: home-assistant runs as root
      # in-container, so myContainerApp's user/PUID/PGID identity model
      # doesn't apply — it keeps its own ports/TZ instead.
      virtualisation.oci-containers.containers.homeassistant = {
        # renovate: datasource=docker depName=ghcr.io/home-assistant/home-assistant
        image = "ghcr.io/home-assistant/home-assistant:2026.7";
        # Default podman bridge for Caddy/host port mapping; when the
        # host has an IoT trunk NIC configured, also attach the macvlan
        # on vlan30 for discovery traffic.
        networks = [ "podman" ] ++ lib.optional iotEnabled "iot";
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
    };
}
