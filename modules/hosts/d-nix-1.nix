# d-nix-1 - minimal VM for bootstrap testing
{
  inputs,
  hostSpecs,
  ...
}:
{
  flake.nixosConfigurations.d-nix-1 = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inherit inputs;
      hostSpec = hostSpecs.d-nix-1;
    };
    modules = [
      ./_d-nix-1-hardware.nix
      inputs.disko.nixosModules.disko
      ./_d-nix-1-disks.nix
    ]
    ++ (with inputs.self.modules.nixos; [
      server
    ])
    ++ [
      {
        home-manager.sharedModules = with inputs.self.modules.homeManager; [
          vibes
          ssh-homelan
        ];
        boot.loader = {
          systemd-boot.enable = true;
          efi.canTouchEfiVariables = true;
        };

        networking = {
          hostName = "d-nix-1";
          networkmanager.enable = true;
        };

        system.stateVersion = "25.11";
      }
    ];
  };
}
