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
            # Pinned off linuxPackages_latest. The NVIDIA kernel module
            # fails to build against 7.x — nvidia/os-interface.c calls
            # strncpy() without including <linux/string.h>, which 7.x no
            # longer pulls in transitively:
            #   error: implicit declaration of function 'strncpy'
            # This was pinned to linuxPackages_7_1 (#512) until 7.1 went
            # EOL and nixpkgs removed it; 7.2 still fails the same way, so
            # luna now rides the nixpkgs default kernel like terra/amos1
            # (the other nvidia hosts).
            #
            # Independent of the driver *branch* pin in
            # modules/hardware/nvidia-gtx1060.nix (#767): 580.173.02 and
            # 595.71.05 both hit this identical strncpy error on 7.2.8, so
            # moving luna to the 580 LTSB line neither fixes nor worsens the
            # constraint here. It does narrow the exit condition, though —
            # luna is pinned to 580 for the life of its Pascal card, so
            # revert to `pkgs.linuxPackages_latest` once **580** builds
            # against 7.x, not merely once some newer mainline driver does.
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
