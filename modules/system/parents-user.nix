# Parents user - secondary, non-admin account
#
# Opt-in via `inputs.self.modules.nixos.parents-user` on hosts that
# should have the account. ipreston (from base.nix) remains the
# administrator on every host; this module never grants `wheel`.
#
# Password is sops-managed at `passwords/preston` in shared.yaml,
# mirroring the `passwords/${hostSpec.username}` shape used by base.nix.
{ inputs, ... }:
let
  sopsFile = builtins.toString inputs.nix-secrets + "/sops/shared.yaml";
in
{
  flake.modules.nixos.parents-user =
    {
      config,
      pkgs,
      ...
    }:
    {
      users.users.preston = {
        isNormalUser = true;
        description = "Parents";
        shell = pkgs.zsh;
        hashedPasswordFile = config.sops.secrets."passwords/preston".path;
        extraGroups =
          let
            ifTheyExist = groups: builtins.filter (g: builtins.hasAttr g config.users.groups) groups;
          in
          ifTheyExist [
            "audio"
            "video"
            "networkmanager"
            "scanner"
            "lp"
            "render"
          ];
      };

      sops.secrets."passwords/preston" = {
        inherit sopsFile;
        neededForUsers = true;
      };
    };
}
