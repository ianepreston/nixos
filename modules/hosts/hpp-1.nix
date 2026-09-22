# hpp-1 - Dev server
{
  inputs,
  hostSpecs,
  config,
  ...
}:
{
  # networking.hostName is single-sourced from hostSpec by mkNixosHost.
  flake.nixosConfigurations.hpp-1 = config.flake.lib.mkNixosHost {
    inherit inputs;
    hostSpec = hostSpecs.hpp-1;
    extraModules = [
      ./_hpp-1-hardware.nix
      inputs.disko.nixosModules.disko
      ./_hpp-1-disks.nix
    ]
    ++ (with inputs.self.modules.nixos; [
      intel-quicksync
      server
      server-apps
      # Route-only: fronts terra's llama-server with TLS + authentik.
      # No inference runs here (see modules/apps/llm-terra.nix).
      llm-terra
      # Imported here rather than via a profile so a future move to a
      # dedicated runner box is a one-line change. See #180.
      github-runner
    ])
    ++ [
      {
        home-manager.sharedModules = with inputs.self.modules.homeManager; [
          ssh-homelan
        ];
        boot.loader = {
          systemd-boot.enable = true;
          efi.canTouchEfiVariables = true;
        };

        networking = {
          networkmanager.enable = true;
        };

        # Valheim dev instance — a place to test BepInEx mods, image
        # bumps and config changes before they reach amos1 (#644).
        #
        # `crossplay = false` keeps this off amos1's PlayFab endpoint two
        # ways. It issues no join code, so there is no way to wander into
        # this world by accident — and it moves the game port to 2466,
        # which is what actually stops the lobby this server registers
        # anyway from answering amos1's code (2026-09-21; see "Crossplay
        # exclusivity" in ../apps/valheim.nix). Join deliberately, by
        # typing 192.168.10.10:2466 into Join Game -> Add server. Steam
        # clients only — console players cannot reach a Steam-backend
        # server at all.
        #
        # `playerNotify = false` because join/leave here is terminal-side
        # noise, not something the players' Discord channel wants; see the
        # option's description for how to repoint it instead.
        myValheim = {
          enable = true;
          crossplay = false;
          bepinex = true;
          playerNotify = false;
        };

        system.stateVersion = "25.11";
      }
    ];
  };
}
