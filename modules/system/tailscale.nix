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
    };
}
