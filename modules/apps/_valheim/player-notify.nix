# Valheim player-presence notifier and the roster it publishes for
# valheim-metrics. Gated by ../valheim.nix with `mkIf cfg.playerNotify`.
#
# Extracted from ../valheim.nix; returns a NixOS config fragment. Operational
# narrative and incident history live in ./README.md; inline references to "the
# top of this file" mean that runbook.
{
  pkgs,
  config,
  paths,
}:
let
  inherit (paths)
    playerNotifyRuntimeDir
    playerRoster
    playerRosterReady
    ;
in
{
  systemd.services = {
    # Post player join/leave to Discord. Sibling of the join-code
    # watcher above and the same shape — root journal follower, secret
    # read by path, `curl -K -` so the webhook never reaches the
    # cmdline — but it keys off different lines, and *which* lines is
    # the whole design. See #609.
    #
    # ## Why not the "Player joined/connection lost" lines
    #
    # The obvious candidates look purpose-built:
    #
    #   Player joined server "<world>" that has join code <code>, now 2 player(s)
    #   Player connection lost server "<world>" that has join code <code>, now 3 player(s)
    #
    # All three parts of that are untrustworthy under crossplay,
    # measured against a real 3-player session (2026-09-13 16:55–20:40,
    # amos1):
    #
    #   - The count is wrong. It logged "now 3 player(s)" on a leave
    #     that took the server from 3 to 2, and "now 2 player(s)" on a
    #     *join*. It is sampled at some point that doesn't correspond
    #     to the event being applied, so it can't drive a player count.
    #   - `Player connection lost` fires on transient PlayFab relay
    #     faults, not just real departures — a peer whose relay socket
    #     faults logs it immediately and reconnects ~90s later, which
    #     is why the naive version of this needed a debounce.
    #   - It still misses real departures. One of the five that
    #     evening (a ZRpc timeout) produced no such line at all.
    #
    # ## What this uses instead
    #
    # A prefix→name roster, built from these presence lines:
    #
    #   Got character ZDOID from <name> : <prefix>:<n>
    #   Destroying abandoned non persistent zdo <prefix>:<n> owner <prefix>
    #   [Disconnect] peer=<name> uid=<prefix> ...
    #
    # `<prefix>` is stable for the lifetime of one player connection
    # and freshly allocated on reconnect, which is what makes the
    # roster work as both the identity map and the dedupe state:
    #
    #   - A ZDOID line whose prefix is *already* on the roster is a
    #     respawn (death, portal, bed), not a new session — so roster
    #     membership is exactly the "already announced" test, and no
    #     separate marker is needed.
    #   - A destroy burst emits one line per ZDO the leaver owned (2–7
    #     of them, all within the same second). The first removes the
    #     roster entry; the rest find nothing and are dropped. The
    #     removal *is* the dedupe.
    #   - Leave gets a name, which the "connection lost" line can't
    #     give — and the destroy bursts matched real departures 5/5
    #     that evening, including the timeout one, with zero false
    #     positives on the relay fault. The debounce #609 anticipated
    #     is unnecessary because the false signal never reaches here.
    #   - A player who disconnects while dead owns no ZDOs, so there
    #     is no destroy burst (#812). FiresGhettoNetworking's disconnect
    #     line supplies the same connection prefix. Its removal and a
    #     later destroy burst dedupe through the roster. Without the
    #     plugin, or if its log wording changes, dead departures can
    #     again leave ghosts; the vanilla destroy signal still works.
    #   - `<prefix>:0` with `<n>` 0 is a death rather than a spawn; it
    #     is filtered, per the noise-budget note on #609.
    #
    # ## Restarts
    #
    # A server restart disconnects everyone *without* emitting any
    # destroy lines, so the roster has to be cleared on the lifecycle
    # lines instead: `Game - OnApplicationQuit` going down and `New
    # session server` coming back up. Both, because neither is
    # reliably present on its own (this boot: 7 session-starts, 8
    # join-code registrations — the code line re-fires without a
    # restart, which is why it is not the anchor here even though the
    # sibling unit keys on it). Truncating an already-empty roster is
    # a no-op, so using both costs nothing.
    #
    # No leave notifications are posted for a restart. The join-code
    # unit already announces the server coming back, which tells the
    # channel everyone was dropped, and five simultaneous "left"
    # messages at 05:10 would be noise.
    valheim-player-notify = {
      description = "Post Valheim player join/leave to Discord";
      # Same ordering rationale as valheim-joincode-notify above —
      # the sops edge is what keeps a deploy from going red on a
      # missing secret. Ordering only, no requires/wants.
      after = [
        "sops-install-secrets.service"
        "podman-valheim.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Restart = "always";
        RestartSec = 10;
        # No RuntimeDirectoryPreserve, unlike the join-code unit: the
        # roster is fully reconstructed from the journal on every
        # start (see the replay pass below), so carrying the old file
        # across a restart would only risk stale entries surviving a
        # reset they should have been cleared by. That teardown is
        # also what makes the `ready` marker below a correct
        # readiness signal for valheim-metrics.
        #
        # Left at the default RuntimeDirectoryMode (0755) with the
        # unit's default root ownership, so the root valheim-metrics
        # reads the roster without any extra grant.
        RuntimeDirectory = baseNameOf playerNotifyRuntimeDir;
        # Root: needs to read both the full journal and the sops
        # secret. Everything below is off by default for a root unit.
        ProtectHome = true;
        ProtectSystem = "strict";
        PrivateTmp = true;
        NoNewPrivileges = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
      };

      script = ''
        rundir=${playerNotifyRuntimeDir}
        roster=${playerRoster}
        ready=${playerRosterReady}
        cursorfile="$rundir/cursor"
        webhook="$(cat ${config.sops.secrets."valheim/player_webhook".path})"
        server=${config.virtualisation.oci-containers.containers.valheim.environment.SERVER_NAME}

        awk=${pkgs.gawk}/bin/awk
        curl=${pkgs.curl}/bin/curl
        jq=${pkgs.jq}/bin/jq
        journalctl=${pkgs.systemd}/bin/journalctl
        sed=${pkgs.gnused}/bin/sed

        ${builtins.readFile ./player-notify.sh}
      '';
    };
  };
}
