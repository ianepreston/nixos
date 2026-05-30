{
  description = "NixOS configs";

  # ...

  outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } (inputs.import-tree ./modules);

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    import-tree.url = "github:vic/import-tree";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    # The next two are for pinning to stable vs unstable regardless of what the above is set to
    # This is particularly useful when an upcoming stable release is in beta because you can effectively
    # keep 'nixpkgs-stable' set to stable for critical packages while setting 'nixpkgs' to the beta branch to
    # get a jump start on deprecation changes.
    # See also 'stable-packages' and 'unstable-packages' overlays at 'overlays/default.nix"
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-darwin.url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs-darwin";
    hardware.url = "github:nixos/nixos-hardware";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # stylix has no release-26.05 branch yet — pinned to 25.11 release branch.
    # Stylix pins its own nixpkgs internally, so the lag mostly affects whether
    # its HM/NixOS module APIs still match. Bump when upstream tags it.
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
    # Authenticate via ssh and use shallow clone. SSH (not HTTPS) so the
    # nightly `nixos-upgrade.service` on impermanent server hosts can
    # fetch with a system-level deploy key — root has no HTTPS creds and
    # the user's home-manager-managed SSH key isn't materialized at
    # 04:40 when the timer fires (see modules/system/auto-rebuild.nix).
    nix-secrets = {
      url = "git+ssh://git@github.com/ianepreston/nix-secrets.git?ref=main&shallow=1";
      inputs = { };
    };
    # Native NixOS module for authentik (server, worker, outposts).
    # Upstream warns against overriding nixpkgs via follows because
    # python deps in the lockfile are pinned together; let it use its
    # own locked nixpkgs.
    authentik-nix.url = "github:nix-community/authentik-nix";
    # UniFi OS Server packaged as an extracted OCI image + NixOS module
    # that runs it under podman. Upstream pins its own nixpkgs (pulls
    # nixos-unstable for the blueprint framework); we don't follow it
    # here — the package is a self-contained image extraction that
    # doesn't share a closure with the host pkgs anyway.
    unifi-os-server.url = "github:rcambrj/unifi-os-server";
    # Declarative state preservation across ephemeral root reboots.
    # See modules/system/preservation-server.nix and the server hosts'
    # disko configs (btrfs blank-snapshot rollback in initrd).
    preservation = {
      url = "github:nix-community/preservation";
    };
  };
}
