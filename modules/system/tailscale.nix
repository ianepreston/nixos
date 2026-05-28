{ inputs, ... }:
{
  flake.modules.nixos.tailscale =
    { config, ... }:
    let
      sopsFolder = "${inputs.nix-secrets}/sops";
    in
    {
      services.tailscale = {
        enable = true;
        openFirewall = true;
        authKeyFile = config.sops.secrets."tailscale/authkey".path;
        # Pre-authorize is set on the key itself in admin console;
        # device approval gate (tailnet-level) catches it anyway.
        extraUpFlags = [
          "--accept-dns=false" # don't override host /etc/resolv.conf
          "--accept-routes=false"
        ];
      };

      sops.secrets."tailscale/authkey" = {
        sopsFile = "${sopsFolder}/shared.yaml";
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
    };
}
