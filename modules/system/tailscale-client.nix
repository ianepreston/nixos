# Tailscale (client) — the tailscale module plus home-LAN access for
# roaming machines (laptops) that need it from anywhere.
#
# Accepts behemoth's subnet routes and the tailnet's DNS config, whose
# split-DNS entry sends ipreston.net to behemoth — so
# hpp-1.ipreston.net resolves and routes off-LAN. Servers keep both off: they sit on that LAN, and taking the
# routes would pull their own LAN traffic into tailscale0.
{ inputs, ... }:
let
  # What behemoth advertises. Lives in pfSense, not this repo — keep in
  # step by hand (`tailscale status --json`, the peer's PrimaryRoutes).
  homeSubnets = [
    "192.168.10.0/24"
    "192.168.15.0/24"
  ];
in
{
  flake.modules.nixos.tailscale-client =
    { lib, pkgs, ... }:
    let
      # Linux tailscale looks up table 52 (accepted routes) at priority
      # 5270, ahead of main, so at home the laptop's own connected LAN
      # would hairpin through tailscale0 to behemoth. This rule consults
      # main first, and suppress_prefixlength 0 discards a match on the
      # default route: on the home LAN the connected /24 wins, anywhere
      # else lookup falls through to table 52. No network detection
      # needed. 5200 is evaluated just ahead of tailscale's own 5210-5270
      # block, and outside it, so tailscaled leaves it alone on restart.
      ruleArgs = subnet: "to ${subnet} lookup main suppress_prefixlength 0 priority 5200";
      ip = lib.getExe' pkgs.iproute2 "ip";
    in
    {
      imports = [ inputs.self.modules.nixos.tailscale ];

      services.tailscale = {
        # Loose rp_filter: replies from subnet-routed hosts arrive on
        # tailscale0, which strict reverse-path filtering drops.
        useRoutingFeatures = "client";
        extraUpFlags = [
          "--accept-dns=true"
          "--accept-routes=true"
        ];
        # extraUpFlags only apply on first login (autoconnect skips `up`
        # once the node is Running); `tailscale set` runs every boot, so
        # already-enrolled hosts pick this up and it can't drift.
        extraSetFlags = [
          "--accept-dns=true"
          "--accept-routes=true"
        ];
      };

      # Without resolved, tailscaled rewrites /etc/resolv.conf wholesale and
      # fights NetworkManager for it. With resolved it sets per-link split
      # DNS on tailscale0 and leaves the rest of the system's DNS alone.
      services.resolved.enable = true;
      networking.networkmanager.dns = "systemd-resolved";

      systemd.services.tailscale-lan-bypass = {
        description = "Keep home-LAN traffic off tailscale0 when on the home LAN";
        wantedBy = [ "multi-user.target" ];
        before = [ "tailscaled.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        # del-then-add: `ip rule add` duplicates rather than replacing.
        script = lib.concatMapStrings (subnet: ''
          ${ip} rule del ${ruleArgs subnet} 2>/dev/null || true
          ${ip} rule add ${ruleArgs subnet}
        '') homeSubnets;
        preStop = lib.concatMapStrings (subnet: ''
          ${ip} rule del ${ruleArgs subnet} || true
        '') homeSubnets;
      };
    };
}
