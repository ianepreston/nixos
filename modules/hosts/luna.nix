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
            # Pinned off linuxPackages_latest. The NVIDIA 595.71.05 kernel
            # module fails to build against 7.x — nvidia/os-interface.c
            # calls strncpy() without including <linux/string.h>, which
            # 7.x no longer pulls in transitively:
            #   error: implicit declaration of function 'strncpy'
            # This was pinned to linuxPackages_7_1 (#512) until 7.1 went
            # EOL and nixpkgs removed it; 7.2 still fails the same way, so
            # luna now rides the nixpkgs default kernel like terra/amos1
            # (the other nvidia hosts). Revert to `pkgs.linuxPackages_latest`
            # once nvidia ships a 7.x-compatible driver.
            kernelPackages = pkgs.linuxPackages;
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
