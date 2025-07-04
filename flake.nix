{
  description = "NixOS configs";

  # ...

  outputs =
    {
      self,
      nixpkgs,
      ...
    }@inputs:
    let
      inherit (self) outputs;

      #
      # ========= Architectures =========
      #
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        #"aarch64-darwin"
      ];

      lib = nixpkgs.lib;
      customLib = import ./lib { inherit lib; };

    in
    {
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
              isDarwin = false;
            };
            modules = [ ./hosts/nixos/${host} ];
          };
        }) (builtins.attrNames (builtins.readDir ./hosts/nixos))
      );
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
