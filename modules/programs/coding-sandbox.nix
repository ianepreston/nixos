# Coding sandbox - a disposable Lima VM for an individual worktree.
#
# The guest is intentionally Ubuntu + standalone Home Manager, rather than
# NixOS: it builds its Linux closure natively, so the Darwin host never needs
# an aarch64-linux builder.  The launcher is deliberately host-side runtime
# configuration; a work item should not require a Darwin or NixOS rebuild just
# to pick a VM or a network policy.
#
# One launcher serves both host OSes.  Apple Silicon macOS runs an aarch64
# guest under Virtualization.framework (VZ); a Linux workstation runs a guest
# of its own CPU architecture under QEMU/KVM.  The guest always matches the
# host CPU, so nothing is emulated and the guest builds its own closure.
{ inputs, ... }:
let
  release = inputs.nixpkgs.lib.trivial.release;
in
{
  flake.modules.homeManager.coding-sandbox =
    {
      config,
      lib,
      pkgs,
      hostSpec,
      ...
    }@args:
    let
      inherit (pkgs.stdenv) hostPlatform;
      # Lima's architecture names (aarch64, x86_64) match the Nix CPU names
      # for every platform this module supports.
      cpu = hostPlatform.parsed.cpu.name;
      guestSystem = "${cpu}-linux";
      # The GitHub App behind [github] session grants (#780). Only a NixOS host's
      # Home Manager has the sops module and an age identity (the same test as
      # vibes.nix): the work Mac has neither yet, so its launcher reports
      # [github] as unavailable.
      githubApp = (args ? osConfig) && !hostSpec.isDarwin;
      githubAppSecret = key: {
        sopsFile = "${inputs.nix-secrets}/sops/coding-sandbox.yaml";
        key = "github_app/${key}";
      };
      vm =
        if hostPlatform.isDarwin then
          {
            type = "vz";
            mountType = "virtiofs";
            description = "Apple Virtualization (VZ)";
          }
        else
          {
            type = "qemu";
            # 9p needs nothing beyond the QEMU that nixpkgs' limactl wrapper
            # already puts on PATH; virtiofs under QEMU would add a host-side
            # virtiofsd daemon to the boundary.
            mountType = "9p";
            description = "QEMU/KVM";
          };
      # This is the deliberately small, fixed first profile. It contains no
      # coding agent, model endpoint, or model credential: work demos often
      # need a separately installed agent pointed at their own AI gateway.
      # Project tools are supplied by a declared project's devShell when one
      # is mounted. A sandbox may also deliberately have no host mounts, so
      # this source remains separate from project code and cannot be altered
      # by an untrusted checkout.
      guestProfile = pkgs.writeTextDir "flake.nix" ''
        {
          description = "Coding sandbox guest profile";

          inputs = {
            nixpkgs.url = "github:NixOS/nixpkgs/nixos-${release}";
            home-manager = {
              url = "github:nix-community/home-manager/release-${release}";
              inputs.nixpkgs.follows = "nixpkgs";
            };
          };

          outputs = { nixpkgs, home-manager, ... }: {
            homeConfigurations.agent = home-manager.lib.homeManagerConfiguration {
              pkgs = nixpkgs.legacyPackages.${guestSystem};
              modules = [
                {
                  home = {
                    username = "agent";
                    homeDirectory = "/home/agent";
                    stateVersion = "26.05";
                    packages = with nixpkgs.legacyPackages.${guestSystem}; [
                      bashInteractive
                      coreutils
                      curl
                      gh
                      git
                      jq
                    ];
                  };

                  programs = {
                    direnv = {
                      enable = true;
                      nix-direnv.enable = true;
                    };
                  };
                }
                # `coding-sandbox.sh` creates this ordinary Home Manager
                # module from the reviewed per-worktree profile before the
                # guest evaluates the flake. It imports only guest paths that
                # the host policy resolved beneath declared mounts.
                ./sandbox-profile.nix
              ];
            };
          };
        }
      '';

      launcher = pkgs.writeShellApplication {
        name = "sandbox";
        runtimeInputs = with pkgs; [
          coreutils
          curl
          git
          gawk
          gnugrep
          gnused
          jq
          lima
          openssl
          python3
        ];
        text = ''
          export SANDBOX_GUEST_PROFILE=${guestProfile}
          export SANDBOX_POLICY_HELPER=${./coding-sandbox-policy.py}
          export SANDBOX_VM_TYPE=${vm.type}
          export SANDBOX_VM_ARCH=${cpu}
          export SANDBOX_VM_MOUNT_TYPE=${vm.mountType}
          export SANDBOX_VM_DESCRIPTION=${lib.escapeShellArg vm.description}
          ${lib.optionalString githubApp ''
            export SANDBOX_GITHUB_APP_ID_FILE=${
              lib.escapeShellArg config.sops.secrets."coding-sandbox/github_app_id".path
            }
            export SANDBOX_GITHUB_APP_KEY_FILE=${
              lib.escapeShellArg config.sops.secrets."coding-sandbox/github_app_private_key".path
            }
          ''}
          ${builtins.replaceStrings [ "@home-manager-release@" ] [ "release-${release}" ] (
            builtins.readFile ./coding-sandbox.sh
          )}
        '';
      };
    in
    {
      imports = lib.optional githubApp {
        sops.secrets = {
          "coding-sandbox/github_app_id" = githubAppSecret "app_id";
          "coding-sandbox/github_app_private_key" = githubAppSecret "private_key";
        };
      };

      home.packages = [
        pkgs.lima
        launcher
      ];
    };
}
