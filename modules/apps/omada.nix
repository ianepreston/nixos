# Omada Controller - TP-Link SDN controller (switches + APs).
#
# Standing up alongside the UniFi controller (modules/apps/unifi.nix)
# for the UniFi -> Omada hardware swap: both controllers run in
# parallel so TP-Link gear can be adopted and configured before the
# cutover, and UniFi keeps managing the live network until it's done.
# Dev-only for now (modules/profiles/server-apps.nix `devOnlyApps`) —
# promote to `commonApps` when amos1 is ready to hold the real site.
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
#   * Only the device-facing ports are opened below. The management
#     UI (8043) stays closed, so Caddy on loopback is still the sole
#     path to it, same as UniFi.
#   * vlan30 can't reach any of it. iot-network.nix installs a deny
#     chain as the *first* rule in nixos-fw for `-i iot`, which runs
#     ahead of every `allowedTCPPorts` accept.
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
# Omada has no OIDC, so the web UI is gated by Authentik forward-auth
# (Infrastructure group) exactly like UniFi. No `bypassAuthPaths`:
# Omada's API is session-cookie based rather than API-key based, so
# there is no route that carries its own auth to safely open up. The
# cost is that the Omada *mobile app* can't be used on the LAN — it
# connects straight to https://<host>:8043, which stays firewalled.
# Browser only, through omada.<serverDomain>.
#
# Adoption traffic never goes near Caddy, so forward-auth doesn't
# interfere with it — the device-facing ports are opened directly.
_: {
  flake.modules.nixos.omada =
    { config, lib, ... }:
    let
      # Management HTTPS — the UI Caddy proxies to. Upstream default;
      # deliberately NOT in the firewall allowlist.
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

      # Device-facing ports only. Management (8043/8044/8088) and the
      # portal (8844) are deliberately absent — Caddy reaches those over
      # loopback. Also absent: the controller-discovery ports the Omada
      # phone app uses to find a controller (19810/27001 UDP). The app
      # would then have to reach the management port, which is closed,
      # so opening discovery for it would buy nothing.
      networking.firewall = {
        # 29810 is how a factory-default device finds the controller;
        # it arrives as a broadcast, which the allowlist accept matches
        # before nixos-fw-log-refuse drops non-unicast traffic.
        allowedUDPPorts = [ 29810 ];
        allowedTCPPorts = deviceTcpPorts;
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
