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
# Networking: Bambu printers sit on the IoT VLAN (vlan30). Bambuddy's
# Virtual Printer (Proxy Mode) relays a slicer's print to the real
# printer, so the slicer must reach bambuddy and bambuddy must reach the
# printer — both over one dedicated, STATIC vlan30 address. Bambuddy
# attaches the `iot-static` macvlan (owned by modules/system/iot-network.nix)
# with a pinned MAC + reserved IP (hostSpec.bambuddyVp{Mac,Ip}). The slicer
# reaches that IP directly over routed mgmt<->vlan30 — there are NO
# host-published relay ports and NO firewall openings, because the macvlan
# child has its own IP/netns, off the host entirely. The web UI stays on
# the default podman bridge so Caddy reaches it on 127.0.0.1:8000. When the
# host has no IoT trunk NIC (test VMs) the macvlan attach is skipped and
# only the bridge UI comes up.
#
# Why Proxy Mode at all (not a direct slicer->printer connection): current
# Bambu firmware gates direct third-party LAN access behind Bambu Connect.
# bambuddy's VP is a protocol shim — it speaks the raw LAN protocol to the
# printer and presents an old-style LAN printer to the slicer. The slicer
# must trust bambuddy's self-signed "Virtual Printer CA" for the
# MQTT-over-TLS leg; that's handled on the workstation by
# modules/programs/orca-slicer.nix.
#
# Operator steps (one-time, after deploy):
#   1. bambuddy UI -> Virtual Printer -> Proxy mode; set the VP's Bind IP /
#      network override to hostSpec.bambuddyVpIp (192.168.30.64 on amos1)
#      and bind it to the printer added below.
#   2. In OrcaSlicer add the printer in LAN mode by IP = bambuddyVpIp,
#      access code = the PRINTER's 8-char code (not a bambuddy password).
#      Add it manually ("bind with access code").
#   3. Slice -> send; bambuddy relays to the printer.
#
# KNOWN ISSUE (see #297): with OrcaSlicer 2.3.2 + network plugin 02.03.00.62,
# detect succeeds but bambuddy rejects the follow-up bind frame ("invalid
# frame") — present on stable 0.2.4.6 and the latest daily, i.e. an upstream
# bambuddy<->OrcaSlicer proxy-mode incompatibility, not a config issue.
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

      systemd = {
        tmpfiles.rules = [
          "d /var/lib/containers/bambuddy 0750 ${toString serverUid} ${toString serverGid} -"
          "d /var/lib/containers/bambuddy/data 0750 ${toString serverUid} ${toString serverGid} -"
          "d /var/lib/containers/bambuddy/logs 0750 ${toString serverUid} ${toString serverGid} -"
        ];

        # Order bambuddy after the static vlan30 macvlan (owned by
        # modules/system/iot-network.nix); the `requires` edge pulls it in.
        # That unit brings up the vlan30 netdev and creates `iot-static`, so
        # it's the only network edge bambuddy needs (no dhcp-proxy — bambuddy
        # uses static IPAM, not DHCP).
        services = lib.mkIf iotEnabled {
          podman-bambuddy = {
            after = [ "podman-network-iot-static.service" ];
            requires = [ "podman-network-iot-static.service" ];
          };
        };
      };

      # bambuddy's VP needs a stable, dedicated vlan30 IP for all its
      # services; we get that by pinning the macvlan MAC and reserving the
      # matching DHCP lease (hostSpec.bambuddyVp{Mac,Ip}). Fail early if an
      # IoT host that runs bambuddy is missing either.
      assertions = lib.optional iotEnabled {
        assertion = hostSpec.bambuddyVpMac != null && hostSpec.bambuddyVpIp != null;
        message = "bambuddy: hostSpec.bambuddyVpMac and bambuddyVpIp must be set on hosts that run bambuddy with IoT access (pinned MAC + reserved vlan30 IP for the VP's dedicated address).";
      };

      virtualisation.oci-containers.containers.bambuddy = {
        # renovate: datasource=docker depName=ghcr.io/maziggy/bambuddy
        image = "ghcr.io/maziggy/bambuddy:0.2.4.7";
        # Default podman bridge for Caddy/host port mapping. The vlan30
        # macvlan is attached via extraOptions below (so its MAC can be
        # pinned), not here.
        networks = [ "podman" ];
        ports = [
          "127.0.0.1:${toString hostPort}:${toString port}"
        ];
        # The image ships a Docker HEALTHCHECK. podman runs it via a
        # transient systemd unit that exits non-zero while the container
        # is still in its "starting" grace window — and any deploy that
        # restarts bambuddy lands switch-to-configuration inside that
        # window, so the transient unit fails the whole switch (and the
        # auto-upgrade timer's exit code) for no real reason. We don't
        # use podman's healthcheck for anything (monitoring is external
        # via Caddy/gatus), so disable it for deterministic deploys.
        # Attach the vlan30 macvlan here (not via `networks`) so we can pin
        # BOTH the IP and the MAC. The VP needs a fixed, dedicated vlan30
        # address; DHCP reservations aren't honored (netavark's DHCP client
        # sends a client-id the router matches on instead of the MAC), so
        # bambuddy rides the host-local/static `iot-static` macvlan (created
        # in iot-network.nix) and requests its reserved IP directly. The MAC
        # is pinned too so the router page still shows a stable entry.
        extraOptions = [
          "--no-healthcheck"
        ]
        ++ lib.optional (
          iotEnabled && hostSpec.bambuddyVpMac != null && hostSpec.bambuddyVpIp != null
        ) "--network=iot-static:ip=${hostSpec.bambuddyVpIp},mac=${hostSpec.bambuddyVpMac}";
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
