# Coding sandbox - a disposable Lima VM for an individual worktree.
#
# The guest is intentionally Ubuntu + standalone Home Manager, rather than
# NixOS: it builds its Linux closure natively, so the Darwin host never needs
# an aarch64-linux builder.  The launcher is deliberately host-side runtime
# configuration; a work item should not require a darwin rebuild just to pick a
# VM or a network policy.
_: {
  flake.modules.homeManager.coding-sandbox =
    { pkgs, ... }:
    let
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
            nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
            home-manager = {
              url = "github:nix-community/home-manager/release-26.05";
              inputs.nixpkgs.follows = "nixpkgs";
            };
          };

          outputs = { nixpkgs, home-manager, ... }: {
            homeConfigurations.agent = home-manager.lib.homeManagerConfiguration {
              pkgs = nixpkgs.legacyPackages.aarch64-linux;
              modules = [
                {
                  home = {
                    username = "agent";
                    homeDirectory = "/home/agent";
                    stateVersion = "26.05";
                    packages = with nixpkgs.legacyPackages.aarch64-linux; [
                      bashInteractive
                      coreutils
                      curl
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
              ];
            };
          };
        }
      '';

      launcher = pkgs.writeShellApplication {
        name = "sandbox";
        runtimeInputs = with pkgs; [
          coreutils
          git
          gawk
          gnugrep
          gnused
          jq
          lima
          python3
        ];
        text = ''
          export SANDBOX_GUEST_PROFILE=${guestProfile}
          export SANDBOX_POLICY_HELPER=${./coding-sandbox-policy.py}
          ${builtins.readFile ./coding-sandbox.sh}
        '';
      };
    in
    {
      home.packages = [
        pkgs.lima
        launcher
      ];
    };
}
