# hpp-1 - Dev server
{
  inputs,
  hostSpecs,
  config,
  ...
}:
{
  # networking.hostName is single-sourced from hostSpec by mkNixosHost.
  flake.nixosConfigurations.hpp-1 = config.flake.lib.mkNixosHost {
    inherit inputs;
    hostSpec = hostSpecs.hpp-1;
    extraModules = [
      ./_hpp-1-hardware.nix
      inputs.disko.nixosModules.disko
      ./_hpp-1-disks.nix
    ]
    ++ (with inputs.self.modules.nixos; [
      intel-quicksync
      server
      server-apps
      # Imported here rather than via a profile so a future move to a
      # dedicated runner box is a one-line change. See #180.
      github-runner
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
          networkmanager.enable = true;
        };

        system.stateVersion = "25.11";
      }
    ];
  };
}
