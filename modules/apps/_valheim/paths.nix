# Shared interface bindings for the split Valheim components in this directory
# (metrics.nix, joincode.nix, player-notify.nix).
#
# Leading-underscore directory => import-tree does not auto-register these as
# flake modules; ../valheim.nix and the sibling components pull them in via
# `import ./_valheim/paths.nix` (same convention as ../_arr-lib.nix and
# ../../hosts/_rollback-root.nix). Plain attrset, no arguments.
#
# These are the /run and /var/lib paths and the join-code timing constants that
# more than one component reads or writes — the *paths* are the contract
# between the units, so they are named once here rather than in each script.
# Operational narrative and incident history live in ./README.md.
let
  # The single interface between valheim-player-notify and
  # valheim-metrics (#631). Deliberately a pair of files in /run rather
  # than a systemd dependency — the exporter must stay readable when a
  # wedged podman has the notifier stuck, so it reads the roster
  # opportunistically and publishes nothing when it isn't there. That
  # makes the *path* the whole contract, so both sides name it from here
  # rather than each hardcoding it.
  #
  # `ready` exists because `roster` alone is not a safe signal: the
  # notifier truncates it at startup and only refills it once the journal
  # replay finishes, so a reader keyed on the roster file would see an
  # authoritative-looking "0 players" for the length of every rebuild.
  # The marker is written after the replay, and systemd drops the whole
  # RuntimeDirectory on stop/restart (no RuntimeDirectoryPreserve), so it
  # is absent for exactly the window in which the roster is a lie.
  playerNotifyRuntimeDir = "/run/valheim-player-notify";
  playerRoster = "${playerNotifyRuntimeDir}/roster";
  playerRosterReady = "${playerNotifyRuntimeDir}/ready";

  # valheim-joincode-notify's state, and the seam between it,
  # valheim-joincode-watchdog and valheim-metrics (#683). Same shape as
  # the roster pair above and for the same reason: three units read or
  # write these paths, so they are named once here rather than three
  # times in three scripts.
  #
  # All four live in the notifier's RuntimeDirectory, which is /run and
  # therefore cleared on reboot. That is still the wanted semantics — a
  # reboot restarts the server, which re-registers — but note it is no
  # longer the *whole* story for `marker`; see the re-announce path in
  # valheim-joincode-notify below.
  #
  #   marker    the code last announced to Discord. Suppresses a repeat
  #             of an unchanged code.
  #   pending   "<code> <epoch>" for a registration whose confirming
  #             `is active` line has not arrived. Written by the
  #             notifier, cleared by it on confirmation, and read by
  #             both the watchdog (to alert) and valheim-metrics (to
  #             publish the age as a gauge).
  #   alerted   set by the watchdog once it has announced the current
  #             pending as unconfirmed. Stops it re-posting every minute,
  #             and is what tells the notifier that the eventual
  #             confirmation is *news* even at unchanged digits.
  #   retried   "<epoch> <count>" for the watchdog's automatic
  #             re-registration loop (#701): when it last restarted the
  #             container for this episode, and how many times. Paces
  #             the retries and drives the loud line past
  #             joincodeRetryLoudAfter. Deliberately *not* the same file
  #             as `alerted` — one Discord message per episode, many
  #             restarts — and cleared alongside `pending` so a
  #             confirmation resets the counter.
  joincodeRuntimeDir = "/run/valheim-joincode-notify";
  joincodeMarker = "${joincodeRuntimeDir}/last";
  joincodePending = "${joincodeRuntimeDir}/pending";
  joincodeAlerted = "${joincodeRuntimeDir}/alerted";
  joincodeRetried = "${joincodeRuntimeDir}/retried";

  # How long a registration may go unconfirmed before it is treated as
  # broken (#683).
  #
  # Derived, not picked: the server's own `Retry join-code check`
  # countdown starts at 99 and decrements once a second, so ~99s is the
  # longest wait the server itself will tolerate before giving up on a
  # code. Measured on amos1 — 2026-09-19 05:35:30/31/32 are checks
  # 99/98/97, one per second, with the `is active` line at 05:35:33; 30
  # retry lines across the 14 days to 2026-09-20, longest run 3. So every
  # healthy confirmation lands 1-4s after registration and the worst case
  # the protocol allows is ~99s. 120s clears that with margin.
  #
  # Do not re-derive this from a comment elsewhere in the file: it comes
  # from those log timestamps.
  joincodeGraceSeconds = 120;

  # How often the watchdog re-registers while a code stays unconfirmed,
  # by restarting the container (#701).
  #
  # 900 is a floor imposed by an existing alert, not a tuning choice.
  # ValheimServerRestartLoop in ../system/victoriametrics.nix is
  # `max_over_time(valheim_server_uptime_seconds[30m]) < 600 and
  # valheim_server_up == 1`, for 15m. At 15-minute spacing the server
  # reaches ~900s of uptime between restarts, which falsifies it. At 10
  # minutes uptime peaks right at the 600s threshold and every episode
  # would risk a spurious restart-loop page. Do not lower this without
  # changing that rule too.
  #
  # Constant rather than exponential, which would be actively wrong
  # here: detection lag *is* the retry interval, so backoff grows the
  # lag precisely when the wait has been longest. From a 2m base,
  # probes land at 2, 6, 14, 30, 62, 126, 254m — episode 1 ended at
  # 3h32m, between the 126m and 254m probes, so the next one would have
  # been 42 minutes late. A constant interval has a flat worst case.
  #
  # Uncapped on purpose. #694 established that within an episode every
  # registration fails however it is triggered, so a restart is a probe
  # of whether the outage has lifted, not a remediation — a cap of 2-3
  # is spent in the first minutes of a multi-hour episode and the unit
  # then goes quiet for the remaining three hours.
  joincodeRetryInterval = 900;

  # Retries past which the watchdog starts logging at error level
  # (#701). Not a cap — nothing stops at this number; it exists so a
  # genuinely permanent failure is distinguishable in the journal from
  # a long-but-ordinary episode.
  #
  # 16 * 900s = 4h, which clears the longest episode on record
  # (2026-09-20, <= 3h32m, ~14 retries at this spacing). So the loud
  # line means "this episode is already longer than anything observed",
  # which is a claim worth making; a smaller number would fire inside
  # the normal range and mean nothing.
  joincodeRetryLoudAfter = 16;
in
{
  inherit
    playerNotifyRuntimeDir
    playerRoster
    playerRosterReady
    joincodeRuntimeDir
    joincodeMarker
    joincodePending
    joincodeAlerted
    joincodeRetried
    joincodeGraceSeconds
    joincodeRetryInterval
    joincodeRetryLoudAfter
    ;
}
