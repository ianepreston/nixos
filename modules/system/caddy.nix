# Caddy - Simple Aspect
# Reverse proxy for server apps. App modules contribute their own
# services.caddy.virtualHosts entries; this module just enables Caddy
# and opens the HTTP/HTTPS firewall ports.
#
# HTTP-only for now: site addresses should be prefixed with "http://"
# (e.g. "http://mealie.dnix.ipreston.net") so Caddy doesn't try to
# provision Let's Encrypt certs for internal-only domains. Wildcard
# DNS (*.dnix.ipreston.net -> dev server, etc.) lives outside this
# repo. TLS is future work.
_: {
  flake.modules.nixos.caddy = _: {
    services.caddy.enable = true;

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
  };
}
