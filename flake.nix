{
  description = "NixOS configs";

  # ...

  outputs =
    {
      self,
      nixpkgs,
      nix-flatpak,
      stylix,
      ...
    }@inputs:
    let
      inherit (self) outputs;

      #
      # ========= Architectures =========
      inherit (nixpkgs) lib;
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
            inherit system;
            pkgs = import nixpkgs { inherit system; };
          }
        );
      customLib = import ./lib { inherit lib; };
      evaluatedHostSpecs = lib.evalModules {
        specialArgs = { inherit inputs lib customLib; };
        modules = [ ./hostSpecs ];
      };
      inherit (evaluatedHostSpecs.config) hostSpecs;

    in
    {
      checks = forEachSupportedSystem (
        { system, ... }:
        {
          pre-commit-check = inputs.git-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              nixfmt.enable = true;
              statix.enable = true; # Catch anti-patterns, unused bindings, etc.
              deadnix.enable = true; # Find dead/unreferenced nix code.
              ripsecrets.enable = true;
              check-yaml.enable = true;
              check-json.enable = true;
              trim-trailing-whitespace.enable = true;
              end-of-file-fixer.enable = true;
              flake-check = {
                enable = true;
                name = "nix flake check";
                entry = "nix flake check --all-systems";
                language = "system";
                pass_filenames = false;
              };
            };
          };
        }
      );

      devShells = forEachSupportedSystem (
        { system, pkgs }:
        {
          default =
            let
              inherit (self.checks.${system}.pre-commit-check) shellHook enabledPackages;
            in
            pkgs.mkShell {
              inherit shellHook;
              packages =
                enabledPackages
                ++ (with pkgs; [
                  nixos-rebuild
                  pciutils
                  go-task
                  dconf2nix
                  nushell
                  ssh-to-age
                  pre-commit-hook-ensure-sops
                ]);
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
              nix-flatpak.nixosModules.nix-flatpak
              stylix.nixosModules.stylix
            ];
          };
        }) (builtins.attrNames (builtins.readDir ./hosts/nixos))
      );
      darwinConfigurations = builtins.listToAttrs (
        map (host: {
          name = host;
          value = inputs.nix-darwin.lib.darwinSystem {
            specialArgs = {
              inherit inputs outputs customLib;
              inherit (inputs.nixpkgs-darwin) lib;
              hostSpec = hostSpecs.${host};
            };
            modules = [
              ./hosts/darwin/${host}
            ];
          };
        }) (builtins.attrNames (builtins.readDir ./hosts/darwin))
      );
      homeConfigurations."penguin" = inputs.home-manager.lib.homeManagerConfiguration {
        pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
        extraSpecialArgs = {
          inherit customLib inputs;
          hostSpec = hostSpecs.penguin;
        };
        modules = [
          ./home/ipreston/penguin.nix
        ];
      };
    };
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-25.11-darwin";
    # The next two are for pinning to stable vs unstable regardless of what the above is set to
    # This is particularly useful when an upcoming stable release is in beta because you can effectively
    # keep 'nixpkgs-stable' set to stable for critical packages while setting 'nixpkgs' to the beta branch to
    # get a jump start on deprecation changes.
    # See also 'stable-packages' and 'unstable-packages' overlays at 'overlays/default.nix"
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-darwin.url = "github:nix-darwin/nix-darwin/nix-darwin-25.11";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs-darwin";
    hardware.url = "github:nixos/nixos-hardware";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    stylix.url = "github:danth/stylix/release-25.11";
    nix-flatpak.url = "github:gmodena/nix-flatpak/?ref=latest";
    # Declarative partitioning and formatting
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Secrets management. See ./docs/secretsmgmt.md
    sops-nix = {
      url = "github:mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    systems.url = "github:nix-systems/default";
    git-hooks.url = "github:cachix/git-hooks.nix";
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
