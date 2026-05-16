# testvm - minimal VM for bootstrap testing
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
      inputs.preservation.nixosModules.default
    ]
    ++ (with inputs.self.modules.nixos; [
      base
      sops
      ssh
    ])
    ++ [
      {
        boot.loader = {
          systemd-boot.enable = true;
          efi.canTouchEfiVariables = true;
        };
        # Required by preservation; also a prerequisite for the
        # rollback-root initrd service defined in _testvm-disks.nix.
        boot.initrd.systemd.enable = true;

        networking = {
          hostName = "testvm";
          networkmanager.enable = true;
        };

        # ed25519 only. NixOS's openssh module otherwise also generates
        # an RSA host key on first boot, which preservation would then
        # try to bind-mount from a never-seeded /persist/etc/ssh/ssh_host_rsa_key
        # and sshd would fail loading the empty file. Modern clients
        # don't need RSA — drop it everywhere on impermanent hosts.
        services.openssh.hostKeys = [
          {
            path = "/etc/ssh/ssh_host_ed25519_key";
            type = "ed25519";
          }
        ];

        # Bind-mounted machine-id from /persist is already durable; the
        # commit-transient-to-disk service has nothing to do and fails
        # noisily. Suppress.
        systemd.suppressedSystemUnits = [ "systemd-machine-id-commit.service" ];

        # Minimal persist set — just enough to validate that
        # preservation actually keeps state across reboot. The full
        # server persist set lives in modules/system/preservation-server.nix
        # and is gated on the server profile, which testvm doesn't import.
        preservation = {
          enable = true;
          preserveAt."/persist" = {
            directories = [
              "/var/lib/nixos"
              "/var/lib/systemd"
            ];
            files = [
              # sshd refuses to load a private key with anything other
              # than 0600 — preservation's tmpfiles default of 0644
              # would otherwise re-apply on every boot and kill sshd.
              {
                file = "/etc/ssh/ssh_host_ed25519_key";
                mode = "0600";
              }
              "/etc/ssh/ssh_host_ed25519_key.pub"
              {
                file = "/etc/machine-id";
                inInitrd = true;
              }
            ];
          };
        };

        system.stateVersion = "25.11";
      }
    ];
  };
}
