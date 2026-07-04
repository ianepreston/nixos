# XPS13 - headless since the monitor doesn't work
{
  inputs,
  hostSpecs,
  config,
  ...
}:
{
  # networking.hostName is single-sourced from hostSpec by mkNixosHost.
  flake.nixosConfigurations.xps13 = config.flake.lib.mkNixosHost {
    inherit inputs;
    hostSpec = hostSpecs.xps13;
    extraModules = [
      ./_xps13-hardware.nix
      inputs.hardware.nixosModules.common-cpu-intel
      inputs.hardware.nixosModules.common-gpu-intel
      inputs.disko.nixosModules.disko
      ./_xps13-disks.nix
    ]
    ++ (with inputs.self.modules.nixos; [
      workstation
      gnome
      flatpak
      keyd
      printing
      smbclient
      tailscale
      xreal-headset
      zsa-keeb
    ])
    ++ [
      (
        { pkgs, ... }:
        {
          home-manager.sharedModules = with inputs.self.modules.homeManager; [
            vibes
            moonlight
            browser
            obsidian
            ssh-homelan
          ];

          boot = {
            loader = {
              systemd-boot.enable = true;
              efi.canTouchEfiVariables = true;
            };
            kernelPackages = pkgs.linuxPackages_latest;
          };

          networking = {
            networkmanager.enable = true;
          };

          system.stateVersion = "25.05";
        }
      )
    ];
  };
}
