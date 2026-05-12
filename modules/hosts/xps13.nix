# XPS13 - headless since the monitor doesn't work
{
  inputs,
  hostSpecs,
  ...
}:
{
  flake.nixosConfigurations.xps13 = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inherit inputs;
      hostSpec = hostSpecs.xps13;
    };
    modules = [
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
            hostName = "xps13";
            networkmanager.enable = true;
          };

          system.stateVersion = "25.05";
        }
      )
    ];
  };
}
