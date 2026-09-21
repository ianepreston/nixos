# Omada Controller - TP-Link SDN controller (switches + APs).
#
# Omada is the permanent network controller. It is in `prodOnlyApps`, so
# amos1 runs the sole instance: there is one physical network and a dev
# controller has no subject. A second controller on the same broadcast domain
# would also answer device discovery, making a factory-default switch or AP
# appear in both UIs and risking adoption into the wrong controller.
#
# If a second instance is ever wanted for testing, put it somewhere
# that cannot see the LAN's discovery broadcasts — the collision above
# is the reason, not the resource cost.
#
# ## Container, not a nixpkgs module
#
# There is no `omada` package or `services.omada*` module in nixpkgs
# (checked 25.11 and unstable), so this is a container per AGENTS.md's
# "App packaging" fallback. `mbentley/omada-controller` is the image
# everyone uses; it bundles the controller JAR plus its embedded
# MongoDB and is the only image upstream's own docs point at.
#
# v6 requires MongoDB 8, which needs AVX on amd64. Both servers are
# fine (hpp-1: i5-7500T, amos1: Ryzen 7 5800X); upstream ships
# `mongodb8_cpu_support_check.sh` if a future host is in doubt.
#
# The `-openj9` tag is the same controller on the OpenJ9 JVM, which
# upstream measures at 30-50% lower memory than HotSpot. Java is the
# whole workload here, so that's the variant worth taking.
#
# ## `--network=host`
#
# Omada devices find their controller by broadcasting to
# 255.255.255.255:29810 (and the controller answers on the same
# socket). A podman bridge with published ports never sees a
# broadcast frame, so under the usual `myContainerApp` treatment every
# switch and AP would need its inform URL set by hand first (upstream
# documents that path in DEVICE_ADOPTION.md). Host networking is
# upstream's recommended mode and is what makes zero-touch adoption
# work; valheim.nix already establishes the pattern here.
#
# The tradeoff is that the container binds every one of its ports on
# 0.0.0.0 rather than 127.0.0.1, so the host firewall — not podman's
# DNAT — is the gate. What that gate lets through:
#
#   * The device-facing ports, opened below, plus the management port
#     (8043), which is where adopted devices fetch firmware images
#     from. It is scoped to the infra VLAN and the trusted LAN — the
#     two places adopted devices sit; see the firewall block for why
#     the scope has to be both. Caddy on loopback is not the sole browser
#     path to the UI: a LAN client can reach the
#     login page directly, which costs the authentik layer in front of
#     omada.<serverDomain>. Omada's own admin login still applies.
#   * vlan30 can't reach any of it. iot-network.nix installs a deny
#     chain as the *first* rule in nixos-fw for `-i iot`, which runs
#     ahead of every accept here — the `allowedTCPPorts` ones and the
#     appended 8043 rule alike.
#
# ## Web ports are declared here, not in the controller
#
# The portal uses its upstream default, 8843. Getting it to stay there needs
# `WEB_CONFIG_OVERRIDE=true` **permanently**, which is not what the variable's
# name suggests, so it is worth spelling out.
#
# The `*_PORT` environment variables only reach `omada.properties`, which the
# entrypoint rewrites on every start. That file is inside the container (only
# `data` and `logs` are volumes), and its own header says the values "will be
# overwritten" once the controller is initialized — by the controller's own
# copy in mongo, `systemsetting.web_port_setting`, which is what it actually
# binds from. `web.config.override` is the switch that makes properties win
# over that stored copy.
#
# It is not a one-boot migration flag, because the controller never writes the
# resolved value back: mongo keeps reading the old port forever. Measured on
# amos1 while retiring the other controller (#714) — with the override set the
# listener moved 8844 -> 8843 while mongo still read 8844, and with it removed
# properties still read 8843 but the listener came back up on 8844.
#
# The consequence to know about: a web port changed in the Omada UI is reverted
# on the next container start. That is the right direction for a port this
# module declares, but it does mean the UI is not where to change one.
#
# ## Auth
#
# Forward-auth (Infrastructure group) gates the browser door: Authentik
# decides who reaches the controller at
# all, but Omada's own local admin login still sits behind it, so it is
# two logins rather than true SSO.
#
# That is a deliberate stopping point, NOT a limitation of the app.
# Omada does support real SSO — over SAML, not OIDC, and
# authentik documents the integration
# (https://integrations.goauthentik.io/networking/omada-controller/).
# The endpoint is present on this build: `POST /sso/saml/login` on the
# management port answers 405-not-POST rather than 404 on 6.3.0.44.
# TP-Link lists the Software Controller as supported.
#
# What it would take, and why it isn't done here yet:
#
#   * A third shape alongside `myAuthentik.{oidcApps,forwardAuthApps}`
#     — a SAML provider plus four custom property mappings (givenname,
#     surname, username, usergroup_name) and one application
#     entitlement per Omada SAML user group.
#   * A bidirectional bootstrap that can't be fully declared. The
#     provider's Audience is the controller's Entity ID and the relay
#     state is base64 of `<resourceId>_<omadacId>`, all of which the
#     controller *generates at first run* — omadacId here is
#     b17086d5de94da4b6c847b58e9cc3923, and a rebuilt controller gets a
#     new one. Same class of problem as the manyfold OIDC bootstrap.
#   * Omada binds one SAML user group per user, so authentik
#     entitlement names have to match Omada group names exactly,
#     case-sensitively.
#   * Forward-auth would need a `/sso/saml/*` bypass to let authentik's
#     ACS POST reach the controller, or be dropped entirely — the two
#     layers are redundant once SAML is live.
#
# Doing that against a controller that hasn't run its setup wizard, on
# a site with no adopted devices, would be building against IDs that
# don't exist yet. Tracked in #520, gated on the controller being
# stable on amos1 with devices adopted.
#
# No `bypassAuthPaths` today: Omada's API is session-cookie based
# rather than API-key based, so there is no route carrying its own auth
# that would be safe to open up. That no longer keeps the Omada *mobile
# app* off the LAN, though — it connects straight to
# https://<host>:8043, which #673 opened to the LAN, so only the
# controller-discovery ports still stand between the app and a working
# connection (see the port block below). Nothing here uses the app, so
# the browser path through omada.<serverDomain> is still the only one
# exercised.
#
# Adoption traffic never goes near Caddy, so forward-auth doesn't
# interfere with it — the device-facing ports are opened directly.
#
# ## Don't trust the audit log for unattended events
#
# The controller's audit log (Log → Audit Log in the UI) records
# nothing for anything its own scheduler does. Every `auto_site_upgrade`
# / `plan_site_upgrade` run instead emits a pair of
#
#   WARN c.t.s.o.m.c.a.a(): Audit Log send failed Error.OmadacId ...,
#   auditLogKey DEVICE_ROLLING_UPGRADE, operator System, ip
#
# to the application log and drops the record on the floor (#585). The
# failing writes are exactly the ones with an empty `ip`: across the
# 85 records the controller *did* store over two weeks, every single
# one carries `operator: admin` and a client address, and an upgrade
# started by hand from the UI audits fine — including its failures.
# Upstream defect in the vendor's Java application; nothing here
# causes it and nothing here can fix it.
#
# Two consequences worth knowing before reaching for that log:
#
#   * A scheduled upgrade that fails leaves no trace a person would
#     look at. That is how #584 ran nightly for four days unnoticed.
#     `OmadaFirmwareUpgradeFailed` in ../system/log-alerts.nix is the
#     detector that replaces it, keyed on the application log instead.
#   * The WARN itself is not a failure signal — it fires on
#     successful unattended upgrades too. Read it as "the scheduler
#     touched firmware", nothing more.
#
# Re-check on controller bumps: if a later `mbentley/omada-controller`
# tag stops emitting these, this section and the alert's premise both
# go stale. Last confirmed present on 6.3.0.44-openj9.
_: {
  flake.modules.nixos.omada =
    { config, lib, ... }:
    let
      # Management HTTPS — the UI Caddy proxies to, and the port
      # adopted devices pull firmware images from. Upstream default;
      # deliberately NOT in the flat allowlist — it is source-scoped to
      # the infra VLAN and the trusted LAN in the extraCommands rule
      # below, which is where the exposure is argued.
      manageHttpsPort = 8043;
      # Guest/user portal HTTPS. Not firewalled open — no guest portal is in
      # use yet; opening it is a separate decision when one is.
      portalHttpsPort = 8843;
      # Device-facing TCP range. 29811-29813 serve v4 firmware, 29814
      # v5, 29815/29816 v5.9+, 29817 v6.0+.
      deviceTcpPorts = lib.range 29811 29817;
    in
    {
      myObservability.monitoredSystemdUnits = [ "podman-omada" ];

      myObservability.logRuleGroups.omada.groups = [
        {
          name = "omada-firmware";
          type = "vlogs";
          interval = "5m";
          rules = [
            {
              # The terminal controller WARN carries both the failed device
              # and the stage; the audit log does not record unattended
              # upgrades, so this is deliberately log-derived.
              alert = "OmadaFirmwareUpgradeFailed";
              expr = ''
                unit:="podman-omada.service" "status sent to frontend is DEVICE_FILE_DOWNLOAD_FAIL"
                  | extract "mac:<omada_mac> source status is"
                  | extract "finished upgrade process in <omada_stage>,"
                  | stats by (host, omada_mac, omada_stage) count() as failures
              '';
              labels.severity = "warning";
              annotations = {
                summary = "Omada firmware upgrade failed for {{ $labels.omada_mac }} ({{ $labels.omada_stage }})";
                description = "The Omada controller on {{ $labels.host }} gave up upgrading {{ $labels.omada_mac }} {{ $value }} time(s) in 5 minutes, in stage {{ $labels.omada_stage }}. Adopted devices fetch the image from the controller over 8043, so start with whether this one can still reach it — see the firewall block in modules/apps/omada.nix. Do not expect the controller's audit log to corroborate: it records nothing for scheduled upgrades.";
              };
            }
          ];
        }
      ];

      myContainerApp.omada = {
        # No `port`: `--network=host` means there is nothing to publish,
        # and the UI reaches Caddy over loopback on manageHttpsPort.
        port = null;
        stateDirs = [
          "/var/lib/containers/omada"
          "/var/lib/containers/omada/data"
          "/var/lib/containers/omada/logs"
        ];
        # The image's entrypoint starts as root, reconciles PUSERNAME/
        # PGROUP to PUID/PGID, chowns its data dirs, then `gosu`es down —
        # the linuxserver.io shape, so PUID/PGID env rather than a
        # `--user` override.
        linuxServer = true;
      };

      # The intentionally small local contract for controller consumers.
      # Keep container details private so they can change without requiring
      # consumers to inspect virtualisation.oci-containers directly.
      myServiceEndpoints.omada = {
        url = "https://127.0.0.1:${toString manageHttpsPort}";
        unit = "podman-omada.service";
      };

      virtualisation.oci-containers.containers.omada = {
        # renovate: datasource=docker depName=mbentley/omada-controller
        image = "mbentley/omada-controller:6.3.0.44-openj9";
        volumes = [
          "/var/lib/containers/omada/data:/opt/tplink/EAPController/data"
          "/var/lib/containers/omada/logs:/opt/tplink/EAPController/logs"
          # Rendered by the preStart below; see the "Log volume" section
          # in the header. Must be writable — the entrypoint chowns the
          # whole properties dir on every start.
          "/run/omada/log4j2.properties:/opt/tplink/EAPController/properties/log4j2.properties"
        ];
        environment = {
          MANAGE_HTTPS_PORT = toString manageHttpsPort;
          PORTAL_HTTPS_PORT = toString portalHttpsPort;
          # Permanent, not a migration flag — without it the controller binds
          # the web ports from its own mongo copy and ignores the two above.
          # See the header.
          WEB_CONFIG_OVERRIDE = "true";
          # Cap the JVM. With `--network=host` there is no container
          # memory limit for the JVM to size against, so it falls back to
          # a fraction of the host's 31 GB — far more than a homelab site
          # needs, on a box that also runs Home Assistant, Jellyfin and
          # the arrs. Upstream's tuning doc uses 128m/512m for a 2 GB
          # pod; doubled here since this isn't that constrained.
          JAVA_MIN_HEAP_SIZE = "128m";
          JAVA_MAX_HEAP_SIZE = "1024m";
        };
        extraOptions = [
          "--network=host"
          # Upstream is explicit that the embedded MongoDB needs a long
          # shutdown grace or the database can be left corrupt (`docker
          # stop -t 60`). podman's default is 10s. The generated unit's
          # TimeoutStopSec is already 120, so this fits under it.
          "--stop-timeout=60"
        ];
      };

      # Quiet the idle firmware-upgrade poller (closes #588).
      #
      # `LocalFirmwareUpgradeMonitor` runs on a 5-second tick and logs
      # four lines every tick whether or not an upgrade is in flight.
      # That was 85,230 lines/day on amos1 — 90.7% of everything this
      # container writes and, by line count, the #2 producer in the
      # whole journal. One of the four is at WARN, so a level filter
      # alone would leave a third of it behind.
      #
      # The cut is by logger name instead. Verified against the jars in
      # the running image rather than inferred from log4j's abbreviated
      # `%c{1.}` names: `device-firmware-upgrade-port-local-1.1.14.jar`
      # holds exactly `com.tplink.smb.device.firmware.upgrade.local.
      # {TokenBucket,monitor.LocalFirmwareUpgradeMonitor}`, and nothing
      # else logs from that package. Everything #584/#586 rely on sits
      # outside it — `BaseFirmwareUpgradeMonitor` and
      # `FirmwareUpgradeRepositoryImpl` are `...upgrade.core.*` (the
      # sibling is `core`, not the `common` the issue guessed), and
      # `DeviceUpgradeStaticTask` (`DEVICE_FILE_DOWNLOAD_FAIL`) plus the
      # audit-log warner are `com.tplink.smb.omada.*`. Pinning
      # `...upgrade.local` at `error` therefore drops 85,194 of the
      # 85,230 noise lines and keeps every detector, including any
      # genuine ERROR the quieted package might emit.
      #
      # Why patch the file rather than filter downstream: the loggers
      # write to a RollingFile appender and the entrypoint `tail -F`s
      # `logs/server.log` to stdout, so cutting at the logger removes
      # the lines from journald, from the 4 GB ring, and from
      # VictoriaLogs at once. A vector transform (the
      # `drop_cadvisor_libpod_noise` shape) would only reach the last.
      #
      # Why a rendered file rather than an env var: neither override
      # path works on this image, both checked against a throwaway
      # container on hpp-1. `LOG4J_CONFIGURATION_FILE` (including
      # log4j2's comma-separated composite form) is discarded because
      # Spring Boot re-initializes logging from the classpath copy after
      # startup, and Spring's own `logging.level.*` is not honoured
      # either. Overwriting the classpath file is what actually takes.
      #
      # Why /run and not the store: `fix_permissions` in the entrypoint
      # `chown -R`s the whole properties dir on every start (it fires on
      # each boot today), and the script runs under `set -e` — a
      # read-only store mount makes that chown fail and the container
      # never starts. So the file has to be writable.
      #
      # Re-extracting upstream's copy out of the image on every start,
      # rather than vendoring one, means an image bump carries its own
      # log4j2 changes through and the stanza below stays the only part
      # that is ours. If a bump ever moves or renames that file the
      # extraction fails, ExecStartPre fails and the container stays
      # down — deliberately loud rather than fail-soft, because a
      # fail-soft path would have to bind-mount a file podman would then
      # create as an empty *directory* over the live config. Down is
      # caught by SystemdUnitFailed within 5m; a directory mounted over
      # log4j2.properties would take the controller's logging with it.
      systemd.services.podman-omada = {
        preStart = ''
          set -euo pipefail

          conf=/run/omada/log4j2.properties

          podman run --rm --network=none --entrypoint cat \
            ${config.virtualisation.oci-containers.containers.omada.image} \
            /opt/tplink/EAPController/properties.defaults/log4j2.properties >"$conf"

          cat >>"$conf" <<'EOF'

          # Appended by modules/apps/omada.nix - see #588.
          logger.fwlocal.name = com.tplink.smb.device.firmware.upgrade.local
          logger.fwlocal.type = asyncLogger
          logger.fwlocal.level = error
          logger.fwlocal.additivity = false
          logger.fwlocal.appenderRef.rolling.ref = RollingFile
          EOF
        '';
      };

      # Device-facing ports. 8044/8088 and the portal (8843) are
      # deliberately absent — Caddy reaches the UI over loopback. Also
      # absent: the controller-discovery ports the Omada phone app uses
      # to find a controller (19810/27001 UDP). Those stay closed
      # because nothing here uses the phone app, not because they would
      # be useless — since #673 opened 8043 to the LAN, a LAN client can
      # reach the management port, so discovery is now the only thing
      # the app would still be missing. Open them if the app is ever
      # wanted; leave them closed until then.
      networking.firewall = {
        # 29810 is how a factory-default device finds the controller;
        # it arrives as a broadcast, which the allowlist accept matches
        # before nixos-fw-log-refuse drops non-unicast traffic.
        allowedUDPPorts = [ 29810 ];
        allowedTCPPorts = deviceTcpPorts;

        # Firmware images: adopted devices fetch them from the
        # controller on the management port, not from TP-Link's CDN
        # (#584). The controller downloads the image itself, caches it
        # under data/device-firmware/, and serves it over 8043 — so
        # with 8043 closed every upgrade failed. The device SYNs, is
        # dropped (silently: logRefusedConnections is off), stalls in
        # FILE_DOWNLOAD_START, and the controller times it out at ten
        # minutes with STAGE_DOWNVAL_TIMEOUT ->
        # DEVICE_FILE_DOWNLOAD_FAIL. Adoption, config push and
        # telemetry all ride 29811-29817, which is why everything else
        # worked and only upgrades broke.
        #
        # Scoped by source CIDR rather than opened flat, and the scope
        # is a decision, not an inventory: 8043 is also the browser UI,
        # so every source allowed here reaches Omada's login page
        # directly, outside the authentik forward-auth that
        # omada.<serverDomain> routes through (Omada's own local admin
        # login still applies — it is the outer layer that goes).
        #
        # Both the infra VLAN and the trusted LAN are allowed, because
        # managed devices sit on both: the switches carry a management
        # VLAN (mvlan_bridge_vlan 15, i.e. 192.168.15.0/24), the APs
        # carry none and manage untagged off the LAN (192.168.10.0/24).
        # The infra VLAN alone was the original scope and it broke every
        # AP firmware upgrade the day APs were adopted (#673) — silently,
        # ten minutes per attempt, with no refused-connection log to find
        # it by. Per-device /32 accepts would have fixed those two APs
        # and rebuilt the same trap for the next device adopted onto the
        # LAN, so the LAN is allowed whole and the SSO layer on 8043 is
        # knowingly given up for LAN clients. flaresolverr.nix has the
        # same LAN-scoped shape; the difference worth naming is that
        # flaresolverr is not a credentialed admin UI and this is.
        #
        # Source-CIDR rather than an interface name for the same reason
        # as flaresolverr.nix: the LAN NIC is enp1s0 on hpp-1 and enp4s0
        # on amos1. IPv4-only — the LAN is v4.
        #
        # vlan30 stays out regardless: iot-network.nix inserts its deny
        # chain at position 1 in nixos-fw, ahead of anything appended
        # here.
        #
        # Not opened: 8044, the v6.3+ upgrade-ES listener. No traffic to
        # it was seen during a failing upgrade, so it goes untouched
        # until a capture shows the device wants it.
        extraCommands = ''
          iptables -A nixos-fw -p tcp -s 192.168.15.0/24 --dport ${toString manageHttpsPort} -j nixos-fw-accept
          iptables -A nixos-fw -p tcp -s 192.168.10.0/24 --dport ${toString manageHttpsPort} -j nixos-fw-accept
        '';
        extraStopCommands = ''
          iptables -D nixos-fw -p tcp -s 192.168.15.0/24 --dport ${toString manageHttpsPort} -j nixos-fw-accept || true
          iptables -D nixos-fw -p tcp -s 192.168.10.0/24 --dport ${toString manageHttpsPort} -j nixos-fw-accept || true
        '';
      };

      myAuthentik.forwardAuthApps.omada = {
        port = manageHttpsPort;
        displayName = "Omada";
        # The controller only speaks HTTPS on the management port (8088
        # exists solely to 302 you to 8043), and the cert is the
        # self-signed one it generates on first boot — hence `tls` +
        # `tls_insecure_skip_verify`. `versions 1.1` because the UI is
        # websocket-driven for live device state, and Caddy would
        # otherwise ALPN-negotiate HTTP/2 upstream, where WS upgrade
        # doesn't exist.
        #
        # The controller accepts Caddy's upstream Host and Origin headers, so
        # this route needs no header rewriting.
        proxyConfig = ''
          transport http {
            tls
            tls_insecure_skip_verify
            versions 1.1
          }
        '';
        homepage = {
          group = "Infrastructure";
          icon = "omada";
          description = "TP-Link network controller";
        };
      };

    };
}
