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
  # The guest flake's inputs are this flake's locked revisions, so a
  # workstation revision identifies the guest's tool bytes. A lock bump
  # reaches new VMs only; an existing VM keeps what it was built from.
  pin = name: {
    inherit (inputs.${name}) rev narHash;
  };
  guestPins = {
    nixpkgs = pin "nixpkgs";
    nixpkgs-unstable = pin "nixpkgs-unstable";
    home-manager = pin "home-manager";
  };
  # A literal attrset in the rendered flake: flake inputs cannot be computed.
  githubInput = owner: repo: name: extra: ''
    {
          type = "github";
          owner = "${owner}";
          repo = "${repo}";
          rev = "${guestPins.${name}.rev}";
          narHash = "${guestPins.${name}.narHash}";
          ${extra}
        }'';
  bundleDir = ./_coding-sandbox/bundles;
  bundleNames =
    let
      inherit (inputs.nixpkgs) lib;
      isBundle = name: type: type == "regular" && lib.hasSuffix ".nix" name;
    in
    map (lib.removeSuffix ".nix") (
      builtins.attrNames (lib.filterAttrs isBundle (builtins.readDir bundleDir))
    );
  # The guest's package sets for one Linux system. The workstation evaluates
  # them only to name store paths; the guest flake imports the same file to
  # build them.
  guestSets =
    system:
    import ./_coding-sandbox/guest-pkgs.nix {
      inherit (inputs) nixpkgs nixpkgs-unstable;
      inherit system;
    };
  importBundle =
    sets: name:
    import (bundleDir + "/${name}.nix") {
      inherit (sets) pkgs pkgsUnstable;
      inherit (inputs.nixpkgs) lib;
    };
in
{
  # Each bundle's fixed-output sources (an optional `sources` attribute), so
  # a `# regen-hash:` marker in a bundle names a flake attribute that
  # scripts/regen-fetch-hashes.sh can build. A fixed-output path depends only
  # on its name and hash, so one builder regenerates every guest system's.
  perSystem =
    { system, lib, ... }:
    {
      legacyPackages.coding-sandbox-bundle-sources = lib.genAttrs bundleNames (
        name: (importBundle (guestSets system) name).sources or { }
      );
    };

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
      # Nothing Linux is built on the workstation: each bundle's store paths
      # lose their string context before they reach the launcher.
      guestBundle = importBundle (guestSets guestSystem);
      # The trusted catalog a project selects from by name. Each bundle's
      # source digest is policy (changing it requires recreating a VM); its
      # store paths follow the lock and are displayed and verified, not
      # compared.
      bundleCatalog = pkgs.writeText "coding-sandbox-bundles.json" (
        builtins.toJSON {
          pins = guestPins;
          bundles = lib.genAttrs bundleNames (
            name:
            let
              source = bundleDir + "/${name}.nix";
              bundle = guestBundle name;
            in
            {
              inherit (bundle) description commands;
              fetch_domains = bundle.fetchDomains;
              digest = "sha256:${builtins.hashFile "sha256" source}";
              packages = map (package: {
                name = lib.getName package;
                version = lib.getVersion package;
                path = builtins.unsafeDiscardStringContext package.outPath;
              }) bundle.packages;
            }
          );
        }
      );
      # This is the deliberately small, fixed first profile. It contains no
      # coding agent, model endpoint, or model credential: work demos often
      # need a separately installed agent pointed at their own AI gateway.
      # Project tools are supplied by a declared project's devShell when one
      # is mounted, platform bundles, or portable project modules. A sandbox
      # may also deliberately have no host mounts, so this source remains
      # separate from project code and cannot be altered by an untrusted
      # checkout.
      guestFlake = pkgs.writeText "flake.nix" ''
        {
          description = "Coding sandbox guest profile";

          inputs = {
            nixpkgs = ${githubInput "NixOS" "nixpkgs" "nixpkgs" ""};
            nixpkgs-unstable = ${githubInput "NixOS" "nixpkgs" "nixpkgs-unstable" ""};
            home-manager = ${
              githubInput "nix-community" "home-manager" "home-manager" ''inputs.nixpkgs.follows = "nixpkgs";''
            };
          };

          outputs = { nixpkgs, nixpkgs-unstable, home-manager, ... }:
            let
              system = "${guestSystem}";
              inherit (nixpkgs) lib;
              sets = import ./guest-pkgs.nix { inherit nixpkgs nixpkgs-unstable system; };
              # `coding-sandbox.sh` writes the names the host policy
              # validated against this same catalog.
              selected = builtins.fromJSON (builtins.readFile ./sandbox-bundles.json);
              bundle = name: import (./bundles + "/''${name}.nix") {
                inherit (sets) pkgs pkgsUnstable;
                inherit lib;
              };
            in
            {
              # Activation uses this flake's own pinned Home Manager rather
              # than resolving a release branch at first boot.
              packages.''${system}.home-manager = home-manager.packages.''${system}.home-manager;

              homeConfigurations.agent = home-manager.lib.homeManagerConfiguration {
                inherit (sets) pkgs;
                modules = [
                  {
                    home = {
                      username = "agent";
                      homeDirectory = "/home/agent";
                      stateVersion = "26.05";
                      packages = with sets.pkgs; [
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
                  { home.packages = lib.concatMap (name: (bundle name).packages) selected; }
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
      # A real directory, not symlinks: Lima mounts it into the guest, where
      # the workstation's store paths do not exist.
      guestProfile = pkgs.runCommand "coding-sandbox-guest-profile" { } ''
        mkdir -p "$out/bundles"
        cp ${guestFlake} "$out/flake.nix"
        cp ${./_coding-sandbox/guest-pkgs.nix} "$out/guest-pkgs.nix"
        cp ${bundleDir}/*.nix "$out/bundles/"
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
          export SANDBOX_BUNDLE_CATALOG=${bundleCatalog}
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
          ${builtins.readFile ./coding-sandbox.sh}
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
