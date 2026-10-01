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
        # bumps and config changes before they reach amos1 (#644), under
        # the same crossplay backend prod runs (#771).
        #
        # `gamePort = 2466` is what keeps this off amos1's PlayFab
        # endpoint: amos1 is on 2456 behind the same public IP, and a join
        # code resolves to `<public-ip>:<port>`, so a shared port would
        # have each server answer the other's codes (2026-09-11,
        # 2026-09-21; see "Endpoint exclusivity" in ../apps/valheim.nix).
        # It stays 2466 if this drops back to `crossplay = false` to act as
        # a Steam-backend control — then join by typing 192.168.10.10:2466
        # into Join Game -> Add server.
        #
        # Join codes go to this host's alerts channel, not the players'
        # one, so nobody follows a dev code into the dev world by accident
        # (`task valheim:joincode HOST=hpp-1` prints the current one too).
        # Repoint to a dedicated channel by adding a key and naming it in
        # `joincodeWebhookSecret`.
        #
        # `playerNotify = false` because join/leave here is terminal-side
        # noise, not something the players' Discord channel wants; see the
        # option's description for how to repoint it instead. The cost is
        # that the join-code watchdog detects an unconfirmed code here but
        # never restarts to recover — it needs that roster to know nobody
        # is on. Restart by hand.
        myValheim = {
          enable = true;
          crossplay = true;
          gamePort = 2466;
          joincodeWebhookSecret = "discord/alerts_webhook";
          bepinex = true;
          playerNotify = false;
        };

        system.stateVersion = "25.11";
      }

      # Valheim dev experiments (#772). This block is the record of what is
      # under test on hpp-1; amos1 gets none of it, and promoting a result is
      # a separate change there. Revert one entry at a time — removing a
      # plugin and deploying cleans its files and declared config, leaving
      # the world and BepInEx's own files alone. Results and per-plugin
      # notes: "Mods and dev experiments" in ../apps/_valheim/README.md.
      (
        { config, ... }:
        {
          myValheim = {
            # Accepted values verified against this server's
            # assembly_valheim.dll; see the README. A preset is saved
            # into the world, so removing this does not undo it — run
            # one start on `-preset normal` first.
            serverArgs = [
              "-preset"
              "hard"
            ];

            # #671 A/B, one networking plugin at a time (asserted).
            # Switching is swapping this entry for
            # `firesGhettoNetworking`. Settings spell out the upstream
            # "first test" block so the tested configuration is visible
            # here even where it matches the defaults.
            bepinexPlugins = [
              (config.myValheim.availablePlugins.betterNetworking10.override {
                settings = {
                  "00 - Compatibility".Mode = "Balanced";
                  "01 - Features" = {
                    "Queue Size" = true;
                    "New Connection ZDO Buffer" = false;
                  };
                  "02 - Networking"."Queue Size" = "KB32";
                };
              })
            ];
          };
        }
      )
    ];
  };
}
