# Terra - AMD desktop workstation
{
  inputs,
  hostSpecs,
  ...
}:
{
  flake.nixosConfigurations.terra = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inherit inputs;
      hostSpec = hostSpecs.terra;
    };
    modules = [
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
          hostName = "terra";
          networkmanager.enable = true;
        };

        # Pin sunshine capture to the headless HDMI dummy plug so streaming
        # works regardless of the real monitor (DP-4) being awake.
        # output_name is a numeric index from sunshine's KMS monitor list,
        # not a connector name — check with `journalctl --user -u sunshine`
        # for "Monitor N is <name>" lines if the dummy ever moves ports.
        services.sunshine.settings.output_name = "0";

        system.stateVersion = "25.05";
      }
    ];
  };
}
