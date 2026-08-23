# FlareSolverr - proxy that solves Cloudflare/DDoS-GUARD challenges so
# indexers can be scraped. Consumed internally by the *arr stack
# (prowlarr) and shelfmark, which need it for sources behind Cloudflare.
#
# Native services.flaresolverr from nixpkgs (3.5.x). Stateless — the
# upstream service keeps no on-disk state (HOME is a RuntimeDirectory),
# so like decluttarr it has no preservation entry, no backup path, and
# no recovery task.
#
# Native consumers reach it at http://localhost:8191; podman containers
# (shelfmark) reach it at http://host.containers.internal:8191 over the
# already-trusted podman bridge — flaresolverr binds 0.0.0.0 by default.
#
# LAN exposure: 8191 is also opened to the home LAN subnet
# (192.168.10.0/24) so other devices on the network — off the server —
# can use it to solve challenges. The rule is source-restricted rather
# than opened globally: it does NOT reach the internet-facing side (the
# host sits behind NAT anyway) and deliberately excludes the isolated
# iot VLAN (192.168.30.0/24, see iot-network.nix). Restricting by source
# CIDR keeps this interface-name-agnostic — the LAN NIC is enp1s0 on
# hpp-1 but enp4s0 on amos1, and both live on 192.168.10.0/24. IPv4-only
# (iptables); the LAN is v4, so no ip6tables rule is needed.
_: {
  flake.modules.nixos.flaresolverr = {
    services.flaresolverr.enable = true;

    networking.firewall.extraCommands = ''
      iptables -A nixos-fw -p tcp -s 192.168.10.0/24 --dport 8191 -j nixos-fw-accept
    '';
    networking.firewall.extraStopCommands = ''
      iptables -D nixos-fw -p tcp -s 192.168.10.0/24 --dport 8191 -j nixos-fw-accept || true
    '';
  };
}
