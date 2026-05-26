# tests-server - sacrificial VM target for `task recovery:test:full`.
# Imports the same server + server-apps profiles as hpp-1 so the
# restore drill exercises the real shape of a server. Single-disk
# btrfs with impermanence (rolled back to @root-blank on every boot)
# is fine here: the VM is deleted on teardown anyway, the impermanence
# layer matters to make `preservation-server` (pulled in by server
# profile) actually do its bind-mount work — without an impermanent
# root the bind-mounts run but have nothing to roll back.
{
  inputs,
  hostSpecs,
  ...
}:
{
  flake.nixosConfigurations.tests-server = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inherit inputs;
      hostSpec = hostSpecs.tests-server;
    };
    modules = [
      ./_tests-server-hardware.nix
      inputs.disko.nixosModules.disko
      ./_vm-disks.nix
    ]
    ++ (with inputs.self.modules.nixos; [
      server
      dev-server-apps
    ])
    ++ [
      {
        boot.loader = {
          systemd-boot.enable = true;
          efi.canTouchEfiVariables = true;
        };

        networking = {
          hostName = "tests-server";
          networkmanager.enable = true;
        };

        system.stateVersion = "25.11";
      }
    ];
  };
}
