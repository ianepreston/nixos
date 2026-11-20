{ inputs, ... }:
{
  flake.modules.nixos.tailscale =
    { config, lib, ... }:
    let
      sopsFolder = "${inputs.nix-secrets}/sops";
      cfg = config.services.tailscale;
    in
    {
      # mkDefault so a host that must stay off the tailnet can opt out
      # with `services.tailscale.enable = false`. tests-server does: the
      # drill VM has no reason to join, and tailnet.yaml deliberately
      # doesn't list it (#506). The secret below is gated on the same
      # switch because sops-install-secrets is all-or-nothing, so one
      # file the host can't decrypt would fail every secret on it.
      config = lib.mkMerge [
        { services.tailscale.enable = lib.mkDefault true; }
        (lib.mkIf cfg.enable {
          services.tailscale = {
            openFirewall = true;
            authKeyFile = config.sops.secrets."tailscale/authkey".path;
            # Pre-authorize is set on the key itself in admin console;
            # device approval gate (tailnet-level) catches it anyway.
            # mkDefault so tailscale-client can replace the list outright.
            extraUpFlags = lib.mkDefault [
              "--accept-dns=false" # don't override host /etc/resolv.conf
              "--accept-routes=false"
            ];
          };

          sops.secrets."tailscale/authkey" = {
            sopsFile = "${sopsFolder}/tailnet.yaml";
            # No restartUnits: tailscaled reads the file at up-time, not
            # continuously; rebuild restart isn't needed once authed.
          };

          # Gate the nixpkgs-provided autoconnect oneshot on sops, otherwise
          # on a fresh bootstrap it races sops-install-secrets, cats a
          # nonexistent authkey, falls back to interactive URL auth, and
          # times out — leaving the host Logged-out until a manual
          # `tailscale up`. Once authed, /var/lib/tailscale persists, so
          # this matters mostly on the first boot after install (where
          # losing the race is silent: tailscaled itself stays active, only
          # the autoconnect oneshot fails).
          systemd.services.tailscaled-autoconnect = {
            after = [ "sops-install-secrets.service" ];
            requires = [ "sops-install-secrets.service" ];
          };
        })
      ];
    };
}
