# Luna - MSI GS43VR laptop
# https://www.msi.com/Laptop/GS43VR-6RE-Phantom-Pro/Specification
{
  inputs,
  hostSpecs,
  config,
  ...
}:
{
  # networking.hostName is single-sourced from hostSpec by mkNixosHost.
  flake.nixosConfigurations.luna = config.flake.lib.mkNixosHost {
    inherit inputs;
    hostSpec = hostSpecs.luna;
    extraModules = [
      ./_luna-hardware.nix
      inputs.hardware.nixosModules.common-cpu-intel
      inputs.hardware.nixosModules.common-gpu-intel
      inputs.hardware.nixosModules.common-gpu-nvidia
      inputs.disko.nixosModules.disko
      ./_luna-disks.nix
    ]
    ++ (with inputs.self.modules.nixos; [
      workstation
      gnome
      docker
      flatpak
      gaming
      keyd
      nvidia-gtx1060
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
