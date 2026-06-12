# Bambuddy - self-hosted command center for Bambu Lab 3D printers.
# Container; not in nixpkgs (Python app with an MQTT/FTP/camera/FFmpeg
# dependency surface) — the "container is the fallback" rule applies.
# Upstream: https://github.com/maziggy/bambuddy. Closes #130.
#
# Auth: native OIDC. Upstream supports standards-compliant OIDC
# (Authentik named, PKCE S256) — so this is `myAuthentik.oidcApps`,
# not forward auth. The twist: bambuddy configures the provider in
# its own web UI (Settings -> Authentication -> SSO / OIDC), not via
# env vars, so this is the Home Assistant pattern: we only stage the
# authentik side via blueprint and set `clientCredsInAppEnv = false`.
# Operator step after first deploy:
#   1. `task secrets:oidc APP=bambuddy` then
#      `task secrets:publish MSG="add bambuddy oidc creds"`.
#   2. After the container is up, read the creds with
#      `task secrets:view:hpp-1` (keys bambuddy.oidc_client_id /
#      bambuddy.oidc_client_secret) and paste them into the SSO/OIDC
#      page. Issuer URL: https://authentik.<serverDomain>/application/o/bambuddy/,
#      scopes `openid email profile`. The blueprint already pins the
#      redirect URI to /api/v1/auth/oidc/callback.
# Until OIDC is configured in the UI, bambuddy uses local accounts —
# same first-boot gap as Home Assistant; the host is private (Caddy +
# Tailscale), so this is acceptable.
#
# Networking: Bambu printers sit on the IoT VLAN (vlan30). Bambuddy
# speaks MQTT/FTP/camera directly to them, so it needs L2 reachability
# on vlan30 exactly like Home Assistant. It attaches the shared `iot`
# macvlan owned by modules/system/iot-network.nix (Home Assistant is
# the other consumer) and orders its container after that stack — this
# module only adds the attach + ordering edges. The web UI stays on the
# default podman bridge so Caddy reaches it on 127.0.0.1:8000. When the host has no
# IoT trunk NIC (test VMs), the macvlan attach is skipped and bambuddy
# runs on the bridge only — printer discovery is lost but the UI comes
# up and is probeable through Caddy.
#
# Proxy Mode (bambuddy's "Virtual Printer" relay) IS enabled on hosts
# with an IoT trunk. It lets a slicer that can't reach vlan30 — every
# workstation here, since the printer VLAN is isolated — print straight
# from OrcaSlicer/Bambu Studio: the slicer talks to bambuddy on the LAN
# IP and bambuddy transparently relays MQTT/FTPS/file/camera to the real
# printer over its macvlan leg. Only MQTT (8883) is TLS-terminated, to
# rewrite the printer's IP to the bind IP in the payloads; everything
# else is a transparent TCP passthrough (the slicer negotiates TLS with
# the printer's real cert end-to-end).
#
# The relay listeners are published on hostSpec.serverLanIp ONLY (not
# loopback, not tailscale0) so the workstation reaches them while the
# rest of the box stays clear; the matching firewall opening is scoped
# to the LAN trunk interface (the untagged mgmt VLAN rides the same NIC
# as the vlan30 sub-iface, so iotTrunkInterface is the LAN NIC too).
# These ports must never go near Caddy. Port set for one VP -> one P1S:
# 3000/3002 (handshake), 8883 (MQTT), 990 + 50000-50100 (FTPS control +
# passive data — proxy forwards the printer's full passive range), 6000
# (file tunnel), 322 (RTSP camera, unused on a P1S but part of the set),
# 2024-2026 (A1/P1S proprietary slicer ports).
#
# Operator steps (one-time, after deploy):
#   1. bambuddy UI -> Virtual Printer -> enable Proxy Mode; set the VP's
#      Bind IP to <serverLanIp> (192.168.10.10 on hpp-1) and bind it to
#      the printer added below.
#   2. In OrcaSlicer/Bambu Studio add the printer in LAN mode by IP:
#      host = <serverLanIp>, access code = the PRINTER's 8-char code
#      (not a bambuddy password). SSDP auto-discovery won't cross the
#      subnet, so add it manually ("bind with access code").
#   3. Slice -> send; bambuddy relays to the printer over vlan30.
#
# Storage: SQLite at /app/data/bambuddy.db plus the print archive
# (3MF/gcode/thumbnails) under /app/data — kept container-local under
# /var/lib/containers/bambuddy and quiesced into the nightly restic
# snapshot via mySqliteQuiesce. PUID/PGID are pinned to
# server-${env}:servers so an eventual NFS archive bind-mount
# (/mnt/content) passes the NAS UID check without a chown dance.
#
# Printer prerequisite (operator, one-time per printer): Settings ->
# Network -> enable "LAN Only Mode", then enable "Developer Mode";
# note the Access Code, IP, and Serial. Add the printer in the
# bambuddy UI with those values.
_: {
  flake.modules.nixos.bambuddy =
    {
      config,
      hostSpec,
      lib,
      ...
    }:
    let
      serverUid = config.users.users."server-${hostSpec.serverEnvironment}".uid;
      serverGid = config.users.groups.servers.gid;
      bambuddyHost = "bambuddy.${hostSpec.serverDomain}";
      # Bambuddy listens on 8000 inside the container; readeck already
      # owns 127.0.0.1:8000 on the host, so publish on a distinct host
      # port and point Caddy at that.
      port = 8000;
      hostPort = 8008;
      iotEnabled = hostSpec.iotTrunkInterface != null;
      # Proxy Mode relay (see header). A module-local switch, not a
      # hostSpec option: every bambuddy host wants it on, and each host
      # relays only to the printers on its own vlan30 segment (MQTT
      # control is a single session per printer, not per fleet), so
      # there's no cross-host variance to parameterize even with hpp-1
      # and amos1 both running it. Gated by iotEnabled: without the
      # vlan30 leg there's no printer to relay to, and serverLanIp is
      # loopback on test VMs.
      proxyMode = true;
      proxyEnabled = iotEnabled && proxyMode;
      lanIp = hostSpec.serverLanIp;
      # One VP -> one P1S. 322 (camera) is unused on a P1S but harmless;
      # 50000-50100 is the printer's full FTPS passive range, which proxy
      # mode forwards transparently.
      proxyTcpPorts = [
        3000
        3002
        322
        990
        6000
        8883
      ];
      proxyTcpPortRanges = [
        {
          from = 2024;
          to = 2026;
        } # A1/P1S proprietary slicer ports
        {
          from = 50000;
          to = 50100;
        } # FTPS passive data
      ];
      # Published on the LAN IP only so the slicer reaches them at
      # <serverLanIp> without exposing tailscale0/loopback.
      proxyPublishes =
        map (p: "${lanIp}:${toString p}:${toString p}") proxyTcpPorts
        ++ map (
          r: "${lanIp}:${toString r.from}-${toString r.to}:${toString r.from}-${toString r.to}"
        ) proxyTcpPortRanges;
    in
    {
      myAuthentik.oidcApps.bambuddy = {
        blueprintsDir = ./bambuddy-blueprints;
        # Creds are pasted into bambuddy's own UI, not read from env.
        clientCredsInAppEnv = false;
        displayName = "Bambuddy";
        homepage = {
          group = "Home";
          icon = "bambu-lab";
          description = "3D printer control";
        };
      };

      myCaddy.apps.bambuddy = {
        host = bambuddyHost;
        routeConfig = ''
          reverse_proxy localhost:${toString hostPort}
        '';
      };

      # Online .backup copy of the SQLite db into /var/backup/sqlite so
      # the nightly restic run has a guaranteed point-in-time consistent
      # copy alongside the live (possibly mid-write) file.
      mySqliteQuiesce.apps.bambuddy.databases = [
        "/var/lib/containers/bambuddy/data/bambuddy.db"
      ];

      # Open the Proxy Mode relay ports on the LAN trunk NIC only (the
      # untagged mgmt VLAN holding serverLanIp rides the same NIC as the
      # vlan30 sub-iface). The publishes above bind to serverLanIp, so
      # this never touches tailscale0/loopback. optionalAttrs keeps the
      # dynamic interface key from being forced when iotTrunkInterface is
      # null (test VMs).
      networking.firewall.interfaces = lib.optionalAttrs proxyEnabled {
        ${hostSpec.iotTrunkInterface} = {
          allowedTCPPorts = proxyTcpPorts;
          allowedTCPPortRanges = proxyTcpPortRanges;
        };
      };

      systemd = {
        tmpfiles.rules = [
          "d /var/lib/containers/bambuddy 0750 ${toString serverUid} ${toString serverGid} -"
          "d /var/lib/containers/bambuddy/data 0750 ${toString serverUid} ${toString serverGid} -"
          "d /var/lib/containers/bambuddy/logs 0750 ${toString serverUid} ${toString serverGid} -"
        ];

        # Order bambuddy after the shared vlan30 macvlan stack (owned by
        # modules/system/iot-network.nix). The `requires` edge is what
        # pulls those units in.
        services = lib.mkIf iotEnabled {
          podman-bambuddy = {
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

      virtualisation.oci-containers.containers.bambuddy = {
        # renovate: datasource=docker depName=ghcr.io/maziggy/bambuddy
        image = "ghcr.io/maziggy/bambuddy:0.2.4.6";
        # Default podman bridge for Caddy/host port mapping; attach the
        # vlan30 macvlan too when the host has an IoT trunk NIC so
        # bambuddy can reach the printers' MQTT/FTP/camera over L2.
        networks = [ "podman" ] ++ lib.optional iotEnabled "iot";
        ports = [
          "127.0.0.1:${toString hostPort}:${toString port}"
        ]
        ++ lib.optionals proxyEnabled proxyPublishes;
        # The image ships a Docker HEALTHCHECK. podman runs it via a
        # transient systemd unit that exits non-zero while the container
        # is still in its "starting" grace window — and any deploy that
        # restarts bambuddy lands switch-to-configuration inside that
        # window, so the transient unit fails the whole switch (and the
        # auto-upgrade timer's exit code) for no real reason. We don't
        # use podman's healthcheck for anything (monitoring is external
        # via Caddy/gatus), so disable it for deterministic deploys.
        extraOptions = [ "--no-healthcheck" ];
        # The image runs as root and drops to PUID:PGID; don't set
        # `user` here or the entrypoint can't fix up ownership.
        volumes = [
          "/var/lib/containers/bambuddy/data:/app/data"
          "/var/lib/containers/bambuddy/logs:/app/logs"
        ];
        environment = {
          TZ = config.time.timeZone;
          PUID = toString serverUid;
          PGID = toString serverGid;
          PORT = toString port;
        };
      };
    };
}
