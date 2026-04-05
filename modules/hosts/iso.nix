# ISO - Recovery/installer image
# This is a special-purpose host that doesn't use the workstation profile.
# It uses minimal setup for recovery and installation.
{
  inputs,
  hostSpecs,
  customLib,
  ...
}:
let
  hostSpec = hostSpecs.iso;
in
{
  flake.nixosConfigurations.iso = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inherit inputs customLib hostSpec;
    };
    modules = [
      # The ISO host config still uses the old pattern for its complex installer setup
      (customLib.relativeToRoot "hosts/nixos/iso")
    ];
  };
}
