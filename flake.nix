{
  description = "NixOS configs";

  # ...

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      imports = [
        # ========== Flake Infrastructure ==========
        ./modules/flake/module-namespaces.nix
        ./modules/flake/git-hooks.nix
        ./modules/flake/dev-shell.nix
        ./modules/flake/host-specs.nix

        # ========== Profiles ==========
        ./modules/profiles/base.nix
        ./modules/profiles/workstation.nix
        ./modules/profiles/darwin-base.nix

        # ========== System ==========
        ./modules/system/ssh.nix
        ./modules/system/sops.nix
        ./modules/system/docker.nix
        ./modules/system/smbclient.nix
        ./modules/system/minimal-user.nix

        # ========== Desktop ==========
        ./modules/desktop/gnome.nix
        ./modules/desktop/audio.nix
        ./modules/desktop/flatpak.nix
        ./modules/desktop/gaming.nix
        ./modules/desktop/themes.nix
        ./modules/desktop/sunshine.nix
        ./modules/desktop/kde.nix

        # ========== Hardware ==========
        ./modules/hardware/keyd.nix
        ./modules/hardware/nvidia-gtx1060.nix
        ./modules/hardware/nvidia-rtx5080.nix
        ./modules/hardware/xreal-headset.nix
        ./modules/hardware/zsa-keeb.nix
        ./modules/hardware/rgb.nix

        # ========== Programs ==========
        ./modules/programs/obsidian.nix
        ./modules/programs/printing.nix
        ./modules/programs/browser.nix
        ./modules/programs/media.nix
        ./modules/programs/comms.nix
        ./modules/programs/vibes.nix
        ./modules/programs/moonlight.nix
        ./modules/programs/calibre.nix
        ./modules/programs/adb.nix
        ./modules/programs/freecad.nix
        ./modules/programs/hammerspoon.nix

        # ========== Hosts ==========
        ./modules/hosts/luna.nix
        ./modules/hosts/terra.nix
        ./modules/hosts/work.nix
        ./modules/hosts/toshibachromebook.nix
        ./modules/hosts/iso.nix
        ./modules/hosts/penguin.nix
      ];
    };

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-25.11-darwin";
    # The next two are for pinning to stable vs unstable regardless of what the above is set to
    # This is particularly useful when an upcoming stable release is in beta because you can effectively
    # keep 'nixpkgs-stable' set to stable for critical packages while setting 'nixpkgs' to the beta branch to
    # get a jump start on deprecation changes.
    # See also 'stable-packages' and 'unstable-packages' overlays at 'overlays/default.nix"
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-darwin.url = "github:nix-darwin/nix-darwin/nix-darwin-25.11";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs-darwin";
    hardware.url = "github:nixos/nixos-hardware";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    stylix.url = "github:danth/stylix/release-25.11";
    nix-flatpak.url = "github:gmodena/nix-flatpak/?ref=latest";
    # Declarative partitioning and formatting
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Secrets management. See ./docs/secretsmgmt.md
    sops-nix = {
      url = "github:mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    systems.url = "github:nix-systems/default";
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";
    #
    # ========= Personal Repositories =========
    #
    # Private secrets repo.  See ./docs/secretsmgmt.md
    # Authenticate via ssh and use shallow clone
    nix-secrets = {
      url = "git+ssh://git@github.com/ianepreston/nix-secrets.git?ref=main&shallow=1";
      inputs = { };
    };
  };
}
