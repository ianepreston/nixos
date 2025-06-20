{
  description = "NixOS configs";

  # ...

  outputs =
    { nixpkgs, ... }@inputs:
    {
      inputs = {
        nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
        # The next two are for pinning to stable vs unstable regardless of what the above is set to
        # This is particularly useful when an upcoming stable release is in beta because you can effectively
        # keep 'nixpkgs-stable' set to stable for critical packages while setting 'nixpkgs' to the beta branch to
        # get a jump start on deprecation changes.
        # See also 'stable-packages' and 'unstable-packages' overlays at 'overlays/default.nix"
        nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-25.05";
        nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
      };
      nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/nixos/luna/configuration.nix
          # ./nixosModules
        ];
      };

    };

}
