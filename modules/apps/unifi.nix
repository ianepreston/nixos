# UniFi OS Server - Ubiquiti network controller.
# Container (podman) deployed via the upstream rcambrj/unifi-os-server
# flake module. UniFi OS Server has no OIDC support, so the web UI is
# gated by Authentik forward-auth (Infrastructure group only) via
# `myAuthentik.forwardAuthApps`. Adoption traffic from APs/switches
# can't traverse forward-auth, so the device-facing service ports
# stay open directly on the firewall.
#
# `uosSystemIP` is the inform address embedded in adoption URLs
# (`http://<ip>:8080/inform`), so it has to be the LAN address that
# UniFi devices on the same subnet can reach — not 127.0.0.1, and not
# the tailscale IP. Sourced from `hostSpec.serverLanIp` so dev and
# prod each get their own static address.
#
# The container's UI port (container 443) is rebound to loopback only
# via `extraPorts` so Caddy's forward-auth gate is the only path in;
# `ports.ui = null` disables the upstream module's default 0.0.0.0
# publish for that port. The HTTPS upstream uses a self-signed cert,
# so the Caddy `transport http { tls; tls_insecure_skip_verify }`
# block is required for the proxy to talk to it.
#
# APs are adopted with the upstream-default
# `set-inform http://<serverLanIp>:8080/inform`. Sabnzbd, which used to
# own :8080 on this host, has been moved to :18080 so UniFi can keep
# the default inform port (matches every doc / mobile-app assumption).
{ inputs, ... }:
{
  flake.modules.nixos.unifi =
    {
      config,
      hostSpec,
      lib,
      pkgs,
      ...
    }:
    {
      imports = [ inputs.unifi-os-server.nixosModules.unifi-os-server ];

      assertions = [
        {
          assertion = hostSpec.serverLanIp != null;
          message = "modules/apps/unifi.nix requires hostSpec.serverLanIp (the inform address advertised to UniFi devices).";
        }
      ];

      services.unifi-os-server = {
        enable = true;
        # Bypass the upstream module's `package` default, which reads
        # `pkgs.system` and trips the nixpkgs deprecation warning
        # ('system' renamed to 'stdenv.hostPlatform.system'). Setting
        # the option here means the default's body is never evaluated.
        package = inputs.unifi-os-server.packages.${pkgs.stdenv.hostPlatform.system}.unifi-os-server;
        uosSystemIP = hostSpec.serverLanIp;
        openFirewallUiPort = false;
        openFirewallServicePorts = true;
        ports.ui = null;
        extraPorts = [ "127.0.0.1:11443:443" ];
      };

      # Upstream sets `imageFile` to a string path; nixos-25.11's
      # oci-containers tightened that option to `nullOr package`. Wrap
      # the tar in a derivation so the type checker is happy without
      # forking the upstream module.
      virtualisation.oci-containers.containers.unifi-os-server.imageFile = lib.mkForce (
        pkgs.runCommandLocal "unifi-os-server-image.tar" { } ''
          cp ${config.services.unifi-os-server.package}/image.tar $out
        ''
      );

      # UniFi state lives at /var/lib/unifi-os-server (the upstream
      # module's `stateDir` default), NOT under /var/lib/containers —
      # the controller's mongodb data, adoption keys, and site config
      # all sit there. The wholesale `/var/lib/containers` preservation
      # entry in preservation-server.nix doesn't cover it, so add an
      # explicit one. Owner stays root:root because the upstream
      # tmpfiles rules create the tree as root and bind-mount it into
      # the container.
      preservation.preserveAt."/persist".directories = [ "/var/lib/unifi-os-server" ];

      myAuthentik.forwardAuthApps.unifi = {
        port = 11443;
        displayName = "UniFi";
        iconUrl = "https://raw.githubusercontent.com/homarr-labs/dashboard-icons/main/png/unifi.png";
        # `versions 1.1` keeps WebSocket upgrades happy — Caddy's
        # default ALPN-negotiates HTTP/2 with the upstream (it supports
        # both), but WS upgrade is an HTTP/1.1-only concept and the
        # negotiation interferes with it. The Host/Origin overrides
        # exist because the upstream nginx enforces a same-origin check
        # on WS requests (`if ($provided_ws_origin != $expected_ws_origin)
        # { return 500; }` in /usr/share/unifi-core/http/websocket.conf)
        # that compares `$host` to the parsed `$http_origin` hostname.
        # Without these, the check fails and `/api/ws/system` returns 500,
        # leaving the SPA stuck on a blank page.
        proxyConfig = ''
          transport http {
            tls
            tls_insecure_skip_verify
            versions 1.1
          }
          header_up Host {http.request.host}
          header_up Origin https://{http.request.host}
        '';
        homepage = {
          group = "Infrastructure";
          icon = "unifi";
          description = "Network controller";
        };
      };
    };
}
