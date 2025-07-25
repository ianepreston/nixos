{
  description = "NixOS configs";

  # ...

  outputs =
    {
      self,
      nixpkgs,
      catppuccin,
      nix-flatpak,
      ...
    }@inputs:
    let
      inherit (self) outputs;

      #
      # ========= Architectures =========
      lib = nixpkgs.lib;
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forEachSupportedSystem =
        f:
        nixpkgs.lib.genAttrs supportedSystems (
          system:
          f {
            pkgs = import nixpkgs { inherit system; };
          }
        );
      customLib = import ./lib { inherit lib; };
      evaluatedHostSpecs = lib.evalModules {
        specialArgs = { inherit inputs lib customLib; };
        modules = [ ./hostSpecs ];
      };
      hostSpecs = evaluatedHostSpecs.config.hostSpecs;

    in
    {
      devShells = forEachSupportedSystem (
        { pkgs }:
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              nixos-rebuild
              pciutils
              go-task
              dconf2nix
              alejandra
              nushell
            ];
          };
        }
      );
      nixosConfigurations = builtins.listToAttrs (
        map (host: {
          name = host;
          value = nixpkgs.lib.nixosSystem {
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
              ./hosts/nixos/${host}
              catppuccin.nixosModules.catppuccin
              nix-flatpak.nixosModules.nix-flatpak
            ];
          };
        }) (builtins.attrNames (builtins.readDir ./hosts/nixos))
      );
      homeConfigurations."ipreston@wsl" = inputs.home-manager.lib.homeManagerConfiguration {
        pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
        extraSpecialArgs = {
          inherit customLib inputs;
          hostSpec = hostSpecs.wsl;
        };
        modules = [
          ./home/ipreston/wsl.nix
          catppuccin.homeModules.catppuccin
        ];
      };
      homeConfigurations."vm@work" = inputs.home-manager.lib.homeManagerConfiguration {
        pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
        extraSpecialArgs = {
          inherit customLib inputs;
          hostSpec = hostSpecs.workvm;
        };
        modules = [
          ./home/work/workvm.nix
          catppuccin.homeModules.catppuccin
        ];
      };
      homeConfigurations."wsl@work" = inputs.home-manager.lib.homeManagerConfiguration {
        pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
        extraSpecialArgs = {
          inherit customLib inputs;
          hostSpec = hostSpecs.workwsl;
        };
        modules = [
          ./home/work/workwsl.nix
          catppuccin.homeModules.catppuccin
        ];
      };
    };
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    # The next two are for pinning to stable vs unstable regardless of what the above is set to
    # This is particularly useful when an upcoming stable release is in beta because you can effectively
    # keep 'nixpkgs-stable' set to stable for critical packages while setting 'nixpkgs' to the beta branch to
    # get a jump start on deprecation changes.
    # See also 'stable-packages' and 'unstable-packages' overlays at 'overlays/default.nix"
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    hardware.url = "github:nixos/nixos-hardware";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    stylix.url = "github:danth/stylix/release-25.05";
    catppuccin.url = "github:catppuccin/nix";
    nix-flatpak.url = "github:gmodena/nix-flatpak/?ref=latest";
    # Secrets management. See ./docs/secretsmgmt.md
    sops-nix = {
      url = "github:mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    #
    # ========= Personal Repositories =========
    #
    # Private secrets repo.  See ./docs/secretsmgmt.md
    # Authenticate via ssh and use shallow clone
    nix-secrets = {
      url = "git+ssh://git@github.com/ianepreston/nix-secrets.git?ref=main&shallow=1";
      inputs = { };
    };
  };
}
