# Omada Controller - TP-Link SDN controller (switches + APs).
#
# Standing up alongside the UniFi controller (modules/apps/unifi.nix)
# for the UniFi -> Omada hardware swap: both controllers run in
# parallel so TP-Link gear can be adopted and configured before the
# cutover, and UniFi keeps managing the live network until it's done.
# Retire this module's UniFi counterpart, not this one, when the swap
# lands.
#
# In `commonApps`, so hpp-1 and amos1 each run an instance — the same
# arrangement UniFi has had all along. Worth knowing before adopting:
# two controllers on one broadcast domain both answer device discovery,
# so a factory-default switch or AP shows up as pending adoption in
# *both* UIs. Adopt from the one that is meant to own the site (amos1
# for the real network); a device can only be adopted once, and taking
# it in the wrong controller means a factory reset to get it back.
#
# ## Container, not a nixpkgs module
#
# There is no `omada` package or `services.omada*` module in nixpkgs
# (checked 25.11 and unstable), so this is a container per CLAUDE.md's
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
# DNAT — is the gate. That's fine in both directions that matter:
#
#   * The device-facing ports are opened below, plus the management
#     port (8043) scoped to the infra VLAN, which adopted devices
#     need for firmware images (see the firewall block). No general
#     LAN client can reach the management UI directly, so Caddy on
#     loopback is still the sole browser path to it, same as UniFi.
#   * vlan30 can't reach any of it. iot-network.nix installs a deny
#     chain as the *first* rule in nixos-fw for `-i iot`, which runs
#     ahead of every accept here — the `allowedTCPPorts` ones and the
#     appended 8043 rule alike.
#
# ## Port collision with UniFi
#
# UniFi OS Server already holds 0.0.0.0:8843 (its guest portal HTTPS)
# on both servers, and 8843 is also Omada's default
# `PORTAL_HTTPS_PORT` — so with host networking the two cannot both
# take the default. Omada's portal moves to 8844. Everything else
# Omada wants (8043/8044/8088, 19810+27001+29810 UDP, 29811-29817 TCP)
# is unclaimed, so those keep upstream defaults.
#
# Note that Omada persists its ports into its own config on first
# start; changing `PORTAL_HTTPS_PORT` after that needs
# `WEB_CONFIG_OVERRIDE=true` for one boot to make it re-read the env.
#
# ## Auth
#
# Forward-auth (Infrastructure group), the same treatment as UniFi.
# That gates the door: Authentik decides who reaches the controller at
# all, but Omada's own local admin login still sits behind it, so it is
# two logins rather than true SSO.
#
# That is a deliberate stopping point, NOT a limitation of the app.
# Unlike UniFi, Omada does support real SSO — over SAML, not OIDC, and
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
# that would be safe to open up. The cost is that the Omada *mobile
# app* can't be used on the LAN — it connects straight to
# https://<host>:8043, which stays firewalled. Browser only, through
# omada.<serverDomain>.
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
      # deliberately NOT in the flat allowlist — it is opened to the
      # infra VLAN only, in the extraCommands rule below.
      manageHttpsPort = 8043;
      # Guest/user portal HTTPS. Moved off upstream's 8843 because the
      # UniFi container holds that port (see header). Not firewalled
      # open — no guest portal is in use yet; opening it is a separate
      # decision when one is.
      portalHttpsPort = 8844;
      # Device-facing TCP range. 29811-29813 serve v4 firmware, 29814
      # v5, 29815/29816 v5.9+, 29817 v6.0+.
      deviceTcpPorts = lib.range 29811 29817;
      # Every TCP port the container binds on the host under
      # `--network=host`. Feeds the UniFi collision guard below;
      # 8088 is management+portal HTTP (Omada shares one port for
      # both) and 8044 is the v6.3+ upgrade-ES listener.
      hostTcpPorts = [
        8044
        8088
        manageHttpsPort
        portalHttpsPort
      ]
      ++ deviceTcpPorts;
    in
    {
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

      # Device-facing ports. 8044/8088 and the portal (8844) are
      # deliberately absent — Caddy reaches the UI over loopback. Also
      # absent: the controller-discovery ports the Omada phone app uses
      # to find a controller (19810/27001 UDP). The app would then have
      # to reach the management port, which no general LAN client can,
      # so opening discovery for it would still buy nothing.
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
        # Scoped to the infra VLAN rather than opened flat, because 8043
        # is also the browser UI: a flat rule would put Omada's login
        # page on the LAN and lose the authentik forward-auth that
        # omada.<serverDomain> routes through (Omada's own local admin
        # login would still apply — it is the outer layer that goes).
        # Managed devices live on 192.168.15.0/24, so that is the only
        # source that needs it. Source-CIDR rather than an interface
        # name for the same reason as flaresolverr.nix: the LAN NIC is
        # enp1s0 on hpp-1 and enp4s0 on amos1. IPv4-only — the LAN is
        # v4.
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
        '';
        extraStopCommands = ''
          iptables -D nixos-fw -p tcp -s 192.168.15.0/24 --dport ${toString manageHttpsPort} -j nixos-fw-accept || true
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
        # Unlike UniFi, no Host/Origin rewriting is needed here. UniFi's
        # bundled nginx rejects a request whose Origin hostname doesn't
        # match its Host; Omada has no such check — verified on hpp-1,
        # where `curl -k -H 'Host: omada.<domain>' https://127.0.0.1:8043/`
        # and `/login` both answer 200 against a foreign Host.
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

      # Structural guard on the coexistence, for as long as it lasts.
      # Both controllers bind on 0.0.0.0 (UniFi publishes from a bridge,
      # Omada via host networking), so a shared port is a container that
      # silently fails to bind at runtime — not an eval error. Check the
      # two port sets against each other instead. `services.unifi-os-server`
      # only exists where modules/apps/unifi.nix is imported, so guard the
      # lookup; this module has no dependency on UniFi being present and
      # this assertion evaporates once UniFi is retired.
      assertions =
        let
          unifiPorts = lib.filter (p: p != null) (
            lib.attrValues (config.services.unifi-os-server.ports or { })
          );
          collisions = lib.intersectLists hostTcpPorts (unifiPorts ++ [ 11443 ]);
        in
        [
          {
            assertion = collisions == [ ];
            message = ''
              modules/apps/omada.nix: these ports are claimed by both the Omada
              container and unifi-os-server (which binds 0.0.0.0 for its service
              ports and 127.0.0.1:11443 for its Caddy-facing UI):

                ${lib.concatMapStringsSep ", " toString collisions}

              Remap the Omada side — the port env vars are in this module — or
              retire UniFi. Two binds on one port is a runtime failure, not an
              eval one, so this guard is the only thing that catches it.
            '';
          }
        ];
    };
}
