# sops-nix - Multi Context Aspect
# Consolidates NixOS + home-manager secrets management
#
# Two age identities with separate jobs, kept on separate paths (#504):
#
# - ~/.config/sops/age/host.txt: the runtime identity. Derived at boot and on
#   switch (sops-host-age-identity.service) from the host's SSH host key, so
#   it decrypts only the files that list this host in nix-secrets'
#   .sops.yaml. home-manager sops reads it.
# - ~/.config/sops/age/keys.txt: the operator identity, which is where the
#   `sops` CLI looks by default. Only on authoring workstations
#   (homeManager.sops-operator below): stubs pointing at the two YubiKeys.
#   Every other host has nothing there.
#
# Before #504 one key did both jobs: shared.yaml's `keys/age` was the operator
# key itself, and sops-nix put it on every host.
{ inputs, ... }:
let
  sopsFile = builtins.toString inputs.nix-secrets + "/sops/shared.yaml";
  ageDir = home: "${home}/.config/sops/age";
in
{
  # NixOS-level sops configuration
  flake.modules.nixos.sops =
    {
      config,
      lib,
      pkgs,
      hostSpec,
      ...
    }:
    {
      imports = [ inputs.sops-nix.nixosModules.sops ];

      sops = {
        defaultSopsFile = sopsFile;
        validateSopsFiles = false;
        age = {
          # Automatically import host SSH keys as age keys
          sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
        };

        # Run sops-install-secrets as a proper systemd unit
        # (`sops-install-secrets.service`, wantedBy=sysinit.target,
        # requiredBy=sysinit-reactivation.target) instead of as an
        # activation script. This is what lets `*-db-password.service`
        # (and anything else that reads decrypted secrets in a script)
        # gate its start with `after = [ sops-install-secrets.service ]`
        # — there's no equivalent ordering primitive for activation
        # scripts, so without this a script-style consumer could run
        # before decryption completed and silently see a missing file
        # (see #123 for the paperless-ngx-db-password near-miss). The
        # sops-nix default auto-enables this only when systemd-sysusers
        # or userborn is in use; we use the legacy users module, so we
        # have to opt in explicitly.
        useSystemdActivation = true;
      };

      # Secrets for user creation
      sops.secrets = lib.mkMerge [
        {
          # User password for creating the user
          "passwords/${hostSpec.username}" = {
            inherit sopsFile;
            neededForUsers = true;
          };
        }
      ];

      # Fix ownership of .config/sops/age directory
      system.activationScripts.sopsSetAgeKeyOwnership =
        let
          ageFolder = ageDir hostSpec.home;
          user = config.users.users.${hostSpec.username}.name;
          inherit (config.users.users.${hostSpec.username}) group;
        in
        ''
          mkdir -p ${ageFolder} || true
          chown -R ${user}:${group} ${hostSpec.home}/.config
        '';

      # Runtime age identity for home-manager sops: see the header.
      #
      # A stage-2 unit, not an activation script: on systemd-initrd hosts
      # (the preservation ones, tests-desktop) activation runs in the initrd,
      # before stage-2 bind mounts, so the host key, or /home, may not exist
      # yet. Same reason sops-install-secrets is a unit here
      # (useSystemdActivation above).
      #
      # Runs as the user, with the root-only host key handed in through
      # LoadCredential, so root never writes into a directory the user owns.
      # A missing key fails the unit (LoadCredential can't open it), which
      # makes this unit the failure you see, not a vague "no identity matched"
      # later in home-manager's sops. Changing the script restarts it on
      # switch; a regenerated host key is picked up on the next boot.
      #
      # Wanted by the home-manager unit too, not only multi-user.target:
      # `before` orders jobs only within one transaction, and on a switch
      # the home-manager restart runs before new units start. Without the
      # Wants, the first switch to this unit restarted home-manager before
      # host.txt existed and failed amos1's autoUpgrade. Wants, not
      # Requires, so a missing host key fails this unit, not home-manager.
      systemd.services.sops-host-age-identity = {
        description = "Derive the home-manager sops age identity from the SSH host key";
        wantedBy = [
          "multi-user.target"
          "home-manager-${hostSpec.username}.service"
        ];
        before = [
          "home-manager-${hostSpec.username}.service"
          "systemd-user-sessions.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = config.users.users.${hostSpec.username}.name;
          Group = config.users.users.${hostSpec.username}.group;
          UMask = "0077";
          LoadCredential = "host-key:${builtins.head config.sops.age.sshKeyPaths}";
          ExecStart = "${
            lib.getExe (
              pkgs.writeShellApplication {
                name = "sops-host-age-identity";
                runtimeInputs = [
                  pkgs.coreutils
                  pkgs.ssh-to-age
                ];
                text = builtins.readFile ./_sops/host-age-identity.sh;
              }
            )
          } ${ageDir hostSpec.home}";
        };
      };

      # Automatically include home-manager sops config for all users
      home-manager.sharedModules = [
        inputs.self.modules.homeManager.sops
      ];
    };

  flake.modules.homeManager = {
    # Home-manager-level sops configuration
    sops =
      {
        config,
        lib,
        hostSpec,
        ...
      }:
      let
        inherit (config.home) homeDirectory;
      in
      {
        imports = [ inputs.sops-nix.homeManagerModules.sops ];

        sops = {
          age.keyFile = "${ageDir homeDirectory}/host.txt";
          defaultSopsFile = hostSpec.sopsFile;
          validateSopsFiles = false;
          secrets = lib.mkMerge [
            {
              "ssh/ed25519" = {
                path = "${homeDirectory}/.ssh/id_ed25519";
              };
            }
          ];
        };
      };

    # Operator identity for the `sops` CLI, imported by the authoring
    # workstations (terra, luna) only. Never servers or test VMs.
    #
    # These are age-plugin-yubikey *stubs*, not keys: each names a token serial
    # and PIV slot, and the private key never leaves the token. They are inert
    # without the token plugged in, which is what makes it safe to manage them
    # declaratively. They live in nix-secrets rather than here to keep the token
    # serials out of a public repo. The token identities, plus an offline escrow
    # key, are recipients of every file; see nix-secrets' README.
    sops-operator = {
      home.file.".config/sops/age/keys.txt".source = "${inputs.nix-secrets}/operator-age-identities.txt";
    };
  };
}
