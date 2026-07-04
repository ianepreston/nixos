# Terra - AMD desktop workstation
{
  inputs,
  hostSpecs,
  config,
  ...
}:
{
  # networking.hostName is single-sourced from hostSpec by mkNixosHost.
  flake.nixosConfigurations.terra = config.flake.lib.mkNixosHost {
    inherit inputs;
    hostSpec = hostSpecs.terra;
    extraModules = [
      ./_terra-hardware.nix
      inputs.hardware.nixosModules.common-cpu-amd
      inputs.disko.nixosModules.disko
      ./_terra-disks.nix
    ]
    ++ (with inputs.self.modules.nixos; [
      workstation
      gnome
      docker
      flatpak
      gaming
      keyd
      nvidia-rtx5080
      printing
      rgb
      smbclient
      quickemu
      sunshine
      xreal-headset
      zsa-keeb
    ])
    ++ [
      {
        home-manager.sharedModules = with inputs.self.modules.homeManager; [
          vibes
          adb
          calibre
          freecad
          obsidian
          # orca-slicer — code kept but dormant; printing through bambuddy is
          # blocked upstream (see #298). Re-add when fixed.
          browser
          ssh-homelan
        ];

        boot = {
          loader = {
            systemd-boot.enable = true;
            efi.canTouchEfiVariables = true;
          };
        };

        networking = {
          networkmanager.enable = true;
        };

        system.stateVersion = "25.05";
      }
    ];
  };
}
