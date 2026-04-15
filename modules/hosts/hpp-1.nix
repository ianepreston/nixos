# hpp-1 - Dev server
{
  inputs,
  hostSpecs,
  ...
}:
{
  flake.nixosConfigurations.hpp-1 = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inherit inputs;
      hostSpec = hostSpecs.hpp-1;
    };
    modules = [
      ./_hpp-1-hardware.nix
      inputs.disko.nixosModules.disko
      ./_hpp-1-disks.nix
    ]
    ++ (with inputs.self.modules.nixos; [
      server
    ])
    ++ [
      {
        home-manager.sharedModules = with inputs.self.modules.homeManager; [
          ssh-homelan
        ];
        boot.loader = {
          systemd-boot.enable = true;
          efi.canTouchEfiVariables = true;
        };

        networking = {
          hostName = "hpp-1";
          networkmanager.enable = true;
        };

        system.stateVersion = "25.11";
      }
    ];
  };
}
