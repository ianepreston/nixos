# Host configuration builders for NixOS, Darwin, and Home Manager
{
  inputs,
  self,
  hostSpecs,
  customLib,
  ...
}:
let
  inherit (inputs.nixpkgs) lib;
  inherit (self) outputs;

  # Builder for NixOS hosts
  mkNixosHost = host: {
    name = host;
    value = lib.nixosSystem {
      specialArgs = {
        inherit
          inputs
          outputs
          lib
          customLib
          ;
        hostSpec = hostSpecs.${host};
      };
      modules = [
        ../../hosts/nixos/${host}
        inputs.nix-flatpak.nixosModules.nix-flatpak
        inputs.stylix.nixosModules.stylix
      ];
    };
  };

  # Builder for Darwin hosts
  mkDarwinHost = host: {
    name = host;
    value = inputs.nix-darwin.lib.darwinSystem {
      specialArgs = {
        inherit inputs outputs customLib;
        inherit (inputs.nixpkgs-darwin) lib;
        hostSpec = hostSpecs.${host};
      };
      modules = [
        ../../hosts/darwin/${host}
      ];
    };
  };

  # Discover hosts from directory names
  nixosHosts = builtins.attrNames (builtins.readDir ../../hosts/nixos);
  darwinHosts = builtins.attrNames (builtins.readDir ../../hosts/darwin);
in
{
  flake = {
    nixosConfigurations = builtins.listToAttrs (map mkNixosHost nixosHosts);

    darwinConfigurations = builtins.listToAttrs (map mkDarwinHost darwinHosts);

    homeConfigurations."penguin" = inputs.home-manager.lib.homeManagerConfiguration {
      pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
      extraSpecialArgs = {
        inherit customLib inputs;
        hostSpec = hostSpecs.penguin;
      };
      modules = [
        ../../home/ipreston/penguin.nix
      ];
    };
  };
}
