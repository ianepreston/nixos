# Luna - MSI GS43VR laptop
# https://www.msi.com/Laptop/GS43VR-6RE-Phantom-Pro/Specification
{
  inputs,
  hostSpecs,
  ...
}:
{
  flake.nixosConfigurations.luna = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inherit inputs;
      hostSpec = hostSpecs.luna;
    };
    modules = [
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
      obsidian
      printing
      smbclient
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
          ];

          boot = {
            loader = {
              systemd-boot.enable = true;
              efi.canTouchEfiVariables = true;
            };
            kernelPackages = pkgs.linuxPackages_latest;
          };

          networking = {
            hostName = "luna";
            networkmanager.enable = true;
          };

          system.stateVersion = "25.05";
        }
      )
    ];
  };
}
