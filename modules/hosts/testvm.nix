# testvm - QEMU/quickemu VM for bootstrap testing
{
  inputs,
  hostSpecs,
  ...
}:
{
  flake.nixosConfigurations.testvm = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inherit inputs;
      hostSpec = hostSpecs.testvm;
    };
    modules = [
      ./_testvm-hardware.nix
      inputs.disko.nixosModules.disko
      ./_testvm-disks.nix
    ]
    ++ (with inputs.self.modules.nixos; [
      workstation
      gnome
    ])
    ++ [
      (
        { pkgs, ... }:
        {
          home-manager.sharedModules = with inputs.self.modules.homeManager; [
            vibes
            browser
          ];

          boot = {
            loader = {
              systemd-boot.enable = true;
              efi.canTouchEfiVariables = true;
            };
            kernelPackages = pkgs.linuxPackages_latest;
          };

          services.qemuGuest.enable = true;

          networking = {
            hostName = "testvm";
            networkmanager.enable = true;
          };

          system.stateVersion = "25.05";
        }
      )
    ];
  };
}
