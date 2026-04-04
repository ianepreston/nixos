{
  description = "Minimal NixOS configuration for bootstrapping systems";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    disko.url = "github:nix-community/disko"; # Declarative partitioning and formatting
  };

  outputs =
    {
      self,
      nixpkgs,
      ...
    }@inputs:
    let
      inherit (self) outputs;

      inherit (nixpkgs) lib;
      customLib = import ../lib { inherit lib; };
      evaluatedHostSpecs = lib.evalModules {
        specialArgs = { inherit inputs lib customLib; };
        modules = [ ../hostSpecs ];
      };
      hostSpec = evaluatedHostSpecs.config.hostSpecs.minimal-configuration;
      minimalSpecialArgs = {
        inherit
          inputs
          outputs
          lib
          customLib
          hostSpec
          ;
      };

      # This mkHost is way better: https://github.com/linyinfeng/dotfiles/blob/8785bdb188504cfda3daae9c3f70a6935e35c4df/flake/hosts.nix#L358
    in
    {
      nixosConfigurations = {
        # host = newConfig "name" disk" "swapSize" "useLuks" "useImpermanence"
        # Swap size is in GiB
        # toshibachromebook = newConfig "toshibachromebook" "/dev/sda" 4 true false;
        luna = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = minimalSpecialArgs;
          modules = [
            inputs.disko.nixosModules.disko
            ../hosts/common/disks/luna.nix
            ./minimal-configuration.nix
            { networking.hostName = "luna"; }
            ../hosts/nixos/luna/hardware-configuration.nix
          ];
        };
        terra = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = minimalSpecialArgs;
          modules = [
            inputs.disko.nixosModules.disko
            ../hosts/common/disks/terra.nix
            ./minimal-configuration.nix
            { networking.hostName = "terra"; }
            ../hosts/nixos/terra/hardware-configuration.nix
          ];
        };
        toshibachromebook = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = minimalSpecialArgs;
          modules = [
            inputs.disko.nixosModules.disko
            ../hosts/common/disks/toshibachromebook.nix
            ./minimal-configuration.nix
            { networking.hostName = "toshibachromebook"; }
            ../hosts/nixos/toshibachromebook/hardware-configuration.nix
          ];
        };

        # ghost = nixpkgs.lib.nixosSystem {
        #   system = "x86_64-linux";
        #   specialArgs = minimalSpecialArgs;
        #   modules = [
        #     inputs.disko.nixosModules.disko
        #     ../hosts/common/disks/ghost.nix
        #     ./minimal-configuration.nix
        #     { networking.hostName = "ghost"; }
        #     ../hosts/nixos/ghost/hardware-configuration.nix
        #   ];
        # };
      };
    };
}
