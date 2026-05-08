# Authentik option surface (platform-tier).
# Owns the `myAuthentik` option namespace that app modules contribute to.
# The leaf service (the authentik-nix module that actually runs the IDP)
# is deployed by modules/apps/authentik.nix, which imports this module
# to read the accumulated blueprint contributions.
_: {
  flake.modules.nixos.myAuthentik =
    { lib, ... }:
    {
      options.myAuthentik.extraBlueprints = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [ ];
        description = ''
          Extra blueprint directories or files to merge into authentik's
          blueprints_dir alongside the bundled defaults. Each entry is a
          path containing one or more *.yaml blueprint files. Other app
          modules can append their own blueprints here so each app stays
          self-contained.
        '';
      };
    };
}
