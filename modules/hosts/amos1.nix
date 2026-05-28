# amos1 - Prod server
{
  inputs,
  hostSpecs,
  ...
}:
{
  flake.nixosConfigurations.amos1 = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inherit inputs;
      hostSpec = hostSpecs.amos1;
    };
    modules = [
      ./_amos1-hardware.nix
      inputs.disko.nixosModules.disko
      ./_amos1-disks.nix
    ]
    ++ (with inputs.self.modules.nixos; [
      nvidia-server
      nvidia-exporter
      server
      prod-server-apps
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
          hostName = "amos1";
          networkmanager.enable = true;
        };

        system.stateVersion = "25.11";
      }
    ];
  };
}
