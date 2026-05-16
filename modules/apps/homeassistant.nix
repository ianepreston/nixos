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
# IoT VLAN access: HA needs L2 reachability on vlan30 for mDNS /
# discovery / broadcast traffic. Topology:
#   enp1s0 (host trunk) ──┬── (untagged mgmt VLAN, host's primary IP)
#                         └── iot (host VLAN sub-iface, no host IP)
#                              └── macvlan child in HA netns (DHCP)
# HA keeps its primary NIC on the default podman bridge so Caddy still
# reaches it on 127.0.0.1:8123 — only the second NIC lives on vlan30.
# DHCP is via netavark's dhcp-proxy so prod and dev pick up distinct
# leases without static-IP bookkeeping in hostSpec; if leases ever
# collide we add an `iotIp` field there and switch ipam to static.
# Caveat: macvlan children are L2-isolated from their parent host, so
# the host kernel can't talk to HA's vlan30 IP (only other vlan30
# devices can). Non-issue for Caddy (uses the bridge); revisit if a
# host-side service ever needs to probe HA on that interface.
_: {
  flake.modules.nixos.homeassistant =
    {
      config,
      hostSpec,
      pkgs,
      ...
    }:
    let
      homeassistantHost = "homeassistant.${hostSpec.serverDomain}";
      port = 8123;
    in
    {
      myAuthentik.oidcApps.homeassistant = {
        blueprintsDir = ./homeassistant-blueprints;
        clientCredsInAppEnv = false;
        displayName = "Home Assistant";
        homepage = {
          group = "Home";
          icon = "home-assistant";
          description = "Smart home";
        };
      };

      networking = {
        # Tagged sub-interface for vlan30 on the host trunk. Host gets
        # no IP here — only HA does, via the macvlan child below.
        vlans.iot = {
          id = 30;
          interface = "enp1s0";
        };
        interfaces.iot.useDHCP = false;
        # NetworkManager would otherwise probe the trunk and fight us
        # for the netdev.
        networkmanager.unmanaged = [ "interface-name:iot" ];
      };

      systemd = {
        # HA writes to /config as root inside the container; we let the
        # container manage ownership and just ensure the host dir exists.
        tmpfiles.rules = [
          "d /var/lib/containers/homeassistant 0750 root root -"
        ];

        services = {
          # netavark ships dhcp-proxy as a subcommand; no NixOS module
          # for it yet, so we run it directly. Listens on
          # /run/podman/nv-proxy.sock and brokers DHCP leases for
          # containers on macvlan networks with `--ipam-driver dhcp`.
          # netavark doesn't unlink the socket on shutdown, so a
          # restart (e.g. across `nixos-rebuild switch`) hits
          # EADDRINUSE and the unit crash-loops; ExecStartPre /
          # ExecStopPost clear it on both sides.
          netavark-dhcp-proxy = {
            description = "netavark DHCP proxy for podman macvlan IPAM";
            wantedBy = [ "multi-user.target" ];
            after = [ "network.target" ];
            serviceConfig = {
              Type = "simple";
              ExecStartPre = "-${pkgs.coreutils}/bin/rm -f /run/podman/nv-proxy.sock";
              ExecStart = "${pkgs.netavark}/bin/netavark dhcp-proxy";
              ExecStopPost = "-${pkgs.coreutils}/bin/rm -f /run/podman/nv-proxy.sock";
              Restart = "on-failure";
            };
          };

          # Idempotent oneshot: bring the iot sub-interface up and
          # create the macvlan podman network if it doesn't exist.
          # Parent is the `iot` netdev; children get DHCP via the proxy.
          podman-network-iot = {
            description = "podman macvlan network on vlan30";
            wantedBy = [ "podman-homeassistant.service" ];
            before = [ "podman-homeassistant.service" ];
            after = [
              "network-online.target"
              "podman.service"
              "sys-subsystem-net-devices-iot.device"
            ];
            wants = [ "network-online.target" ];
            bindsTo = [ "sys-subsystem-net-devices-iot.device" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              ${pkgs.iproute2}/bin/ip link set iot up
              if ! ${pkgs.podman}/bin/podman network exists iot; then
                ${pkgs.podman}/bin/podman network create \
                  --driver macvlan \
                  --opt parent=iot \
                  --ipam-driver dhcp \
                  iot
              fi
            '';
          };

          # Ensure the container service waits on the network and DHCP
          # proxy so podman doesn't try to attach to a non-existent
          # network on boot.
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

      virtualisation.oci-containers.containers.homeassistant = {
        # renovate: datasource=docker depName=ghcr.io/home-assistant/home-assistant
        image = "ghcr.io/home-assistant/home-assistant:2026.5";
        # Two NICs: the default podman bridge for Caddy/host port
        # mapping, and the macvlan on vlan30 for IoT discovery.
        networks = [
          "podman"
          "iot"
        ];
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
