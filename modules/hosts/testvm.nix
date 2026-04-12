# testvm - minimal VM for bootstrap testing
{
  inputs,
  hostSpecs,
  ...
}:
{
  flake.nixosConfigurations.testvm = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inherit inputs;
      hostSpec = hostSpecs.testvm;
    };
    modules = [
      ./_testvm-hardware.nix
      inputs.disko.nixosModules.disko
      ./_testvm-disks.nix
    ]
    ++ (with inputs.self.modules.nixos; [
      base
      sops
      ssh
    ])
    ++ [
      {
        home-manager.sharedModules = [
          { home.stateVersion = "25.11"; }
        ];

        boot.loader = {
          systemd-boot.enable = true;
          efi.canTouchEfiVariables = true;
        };

        networking = {
          hostName = "testvm";
          networkmanager.enable = true;
        };

        system.stateVersion = "25.11";
      }
    ];
  };
}
