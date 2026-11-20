# Package sets for the coding-sandbox guest.
#
# Evaluated from the same locked revisions in two places: by this flake, which
# reads each bundle's store paths for `sandbox plan` and the guest's
# post-activation check (and builds them all in CI), and by the generated
# guest flake, which the guest builds from, and which a NixOS host builds
# from too when it seeds a new guest.
# Both callers must get identical derivations, so this file is the single
# owner of the guest's nixpkgs configuration.
{
  nixpkgs,
  nixpkgs-unstable,
  system,
}:
let
  # Unfree packages a platform bundle may select. Nothing else unfree can
  # enter a guest closure.
  unfree = [
    "claude-code"
    "databricks-cli"
    "unity-gateway"
  ];
  # Explicit, because the guest evaluates impurely: nixpkgs would otherwise
  # honour NIXPKGS_ALLOW_UNFREE and ~/.config/nixpkgs overlays there, but not
  # on the workstation.
  config = {
    allowUnfree = false;
    allowUnfreePredicate = pkg: builtins.elem (nixpkgs.lib.getName pkg) unfree;
  };
  overlays = [ ];
in
{
  pkgs = import nixpkgs { inherit system config overlays; };
  pkgsUnstable = import nixpkgs-unstable { inherit system config overlays; };
}
