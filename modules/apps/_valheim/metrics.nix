# Valheim observability: the node_exporter textfile collector, the per-unit
# journald rate cap on podman-valheim, the vmalert rule group, and the
# app-state declaration for the relay counters' persistent totals.
#
# Extracted from ../valheim.nix; returns a NixOS config fragment that
# valheim.nix merges under `config = mkIf cfg.enable (mkMerge [ ... ])`. Always
# merged (both hosts). Operational narrative and incident history live in
# ./README.md; inline references to "the top of this file" mean that runbook.
#
# The vmalert rule group is kept whole here — it is one ordered list, and the
# join-code alert lives with the other rules rather than in joincode.nix so the
# rendered order stays stable.
{
  lib,
  pkgs,
  config,
  cfg,
  paths,
}:
let
  inherit (paths)
    playerRoster
    playerRosterReady
    joincodePending
    joincodeGraceSeconds
    ;

  # Shared node_exporter textfile-collector drop dir; see
  # modules/system/observability-options.nix.
  textfileDir = config.myObservability.nodeExporterTextfileDirectory;

  # The join-code gauge's two halves, as bindings rather than inline
  # `lib.optionalString` calls: an interpolation opening at column 0
  # inside an indented string would reset Nix's indentation stripping for
  # the whole script.
  #
  # Crossplay-gated so a Steam-backend host's exporter is byte-identical
  # to before #683 — it has no join code, so there is nothing to measure
  # and no reason to change hpp-1's closure for this.
  #
  # The `\n`-prefixed `*Line` wrappers are what make "byte-identical"
  # literally true rather than nearly true. Interpolating on its own
  # source line leaves that line's indentation behind when the string is
  # empty, so a Steam-backend host got a script differing from
  # origin/main by one line of trailing whitespace — no behaviour change,
  # but enough to rebuild the closure and to make a diff-based claim
  # false. Carrying the newline inside the optional string instead means
  # the crossplay=false expansion is exactly the empty string.
  joincodeGaugeReadLine = lib.optionalString cfg.crossplay "\n${joincodeGaugeRead}";
  joincodeGaugeEmitLine = lib.optionalString cfg.crossplay "\n${joincodeGaugeEmit}";

  joincodeGaugeRead = ''
    # Age of an unconfirmed join-code registration (#683). Read from
    # valheim-joincode-notify's pending file rather than from the
    # journal: the notifier already parses those lines, and duplicating
    # the parse here would be a second place to get the wording wrong.
    #
    # Opportunistic, exactly like the player roster above — an absent
    # file means "confirmed, nothing pending" and publishes no series.
    joincode_unconfirmed=
    if [ -f ${joincodePending} ]; then
      read -r _jccode _jcwhen _jcrest < ${joincodePending} || true
      case "''${_jcwhen:-}" in
        "" | *[!0-9]*) _jcwhen= ;;
      esac
      if [ -n "''${_jcwhen:-}" ]; then
        joincode_unconfirmed=$(( $(date +%s) - _jcwhen ))
        # A clock step backwards is the only way this goes negative,
        # and a negative age would read as "confirmed" to the rule.
        if [ "$joincode_unconfirmed" -lt 0 ]; then
          joincode_unconfirmed=0
        fi
      fi
    fi
  '';

  joincodeGaugeEmit = ''
    # Absent rather than 0 when there is nothing pending, for the same
    # reason valheim_players_online is: 0 is a meaningful value here
    # ("registered this instant") and must not double as no-data.
    #
    # Note this legitimately reads 1-4 on an ordinary re-registration,
    # since every confirmation is preceded by a brief pending window.
    # The alert threshold is what distinguishes that from a fault; see
    # ValheimJoinCodeUnconfirmed in ../system/victoriametrics.nix.
    if [ -n "''${joincode_unconfirmed:-}" ]; then
      echo "# HELP valheim_joincode_unconfirmed_seconds Seconds since the server registered a PlayFab join code without its confirming 'is active' line arriving. Absent while the live code is confirmed. A value past ${toString joincodeGraceSeconds} means the server's own join-code check never completed and the advertised code most likely does not resolve (#683)."
      echo "# TYPE valheim_joincode_unconfirmed_seconds gauge"
      echo "valheim_joincode_unconfirmed_seconds $joincode_unconfirmed"
    fi
  '';

  # Persistent state for the journal-derived relay counters (#627).
  # /var/lib rather than /run precisely because these are counters: the
  # point is a total that outlives the timer, the journal window and a
  # reboot.
  #
  # Which means it needs the preservation entry in the `config` block
  # below. Both valheim hosts are impermanent — `preservation.enable`
  # arrives via the `server` profile, not from anything in
  # modules/hosts/<host>.nix, so grepping the host files says otherwise
  # and is wrong. Without that entry `_rollback-root.nix` recreates
  # @root from @root-blank on every boot, the exporter takes its
  # first-run branch and re-seeds at the tail, and every event between
  # the last run and the reboot is dropped silently — with /var/log/journal
  # preserved, the evidence would still be on disk while the counter
  # said zero. These are derived counters, not authored state — restoring
  # a month-old total out of restic would be worse than starting from zero,
  # because it would publish a number that silently disagrees with the
  # journal. The app-state declaration below preserves them without
  # backing them up.
  metricsStateDir = "/var/lib/valheim-metrics";
  relayCursorFile = "${metricsStateDir}/journal-cursor";
  relayTotalsFile = "${metricsStateDir}/relay-totals";

  # The two journal lines the counters are built from, verified against
  # amos1's journal (30 and 25 occurrences respectively in the 14 days to
  # 2026-09-19). Anchored strings, not loose ones: `ZRpc timeout` alone
  # also matches `ZRpc timeout set to 90s`, which the server logs on every
  # handshake — it is the constant being announced, not a fault, and
  # grepping for it would swamp the signal with an order more matches.
  relayStallMatch = "Failed to send, suspend TX";
  relayTimeoutMatch = "ZRpc timeout detected";
  relayJournalPattern = "${relayStallMatch}|${relayTimeoutMatch}";
in
{
  myObservability.metricRuleGroups.valheim.groups = [
    {
      name = "valheim";
      rules = [
        {
          alert = "ValheimServerDown";
          expr = "valheim_server_up == 0";
          for = "15m";
          labels.severity = "warning";
          annotations = {
            summary = "Valheim server process is down on {{ $labels.instance }}";
            description = "valheim_server.x86_64 has not been running for 15m on {{ $labels.instance }}. supervisord restarts it automatically, so this means the restart is failing — check `podman logs valheim`.";
          };
        }
        {
          alert = "ValheimServerRestartLoop";
          expr = "max_over_time(valheim_server_uptime_seconds[30m]) < 600 and valheim_server_up == 1";
          for = "15m";
          labels.severity = "warning";
          annotations = {
            summary = "Valheim server restart-looping on {{ $labels.instance }}";
            description = "valheim_server has not stayed up longer than 10m at any point in the last 30m (currently {{ $value | humanizeDuration }}). supervisord is restarting it repeatedly — check `podman logs valheim` for the crash.";
          };
        }
        {
          alert = "ValheimMemoryHigh";
          expr = "valheim_server_rss_bytes > 4 * 1024 * 1024 * 1024";
          for = "30m";
          labels.severity = "warning";
          annotations = {
            summary = "Valheim server memory high on {{ $labels.instance }}";
            description = "valheim_server RSS has been above 4 GiB for 30m on {{ $labels.instance }} (currently {{ $value | humanize1024 }}B), against a ~1.1 GiB idle baseline. Suspect the upstream memory leak that RESTART_CRON exists to paper over; restart the container and see modules/apps/valheim.nix.";
          };
        }
        {
          alert = "ValheimMemoryBaselineHigh";
          expr = "min_over_time(valheim_server_rss_bytes[12h]) > 2 * 1024 * 1024 * 1024";
          for = "30m";
          labels.severity = "warning";
          annotations = {
            summary = "Valheim server baseline memory has risen on {{ $labels.instance }}";
            description = "valheim_server RSS has not dropped below 2 GiB at any point in the last 12h on {{ $labels.instance }} (floor currently {{ $value | humanize1024 }}B), against a 430-850 MB steady state. A raised floor rather than a peak is the shape of the leak RESTART_CRON used to paper over, and the weekly cadence is what lets it accumulate — see the restart-cadence notes in modules/apps/valheim.nix (#458).";
          };
        }
        {
          alert = "ValheimJoinCodeUnconfirmed";
          expr = "valheim_joincode_unconfirmed_seconds > 120";
          for = "5m";
          labels.severity = "warning";
          annotations = {
            summary = "Valheim join code never confirmed on {{ $labels.instance }}";
            description = "A PlayFab join code has been registered for {{ $value | humanizeDuration }} on {{ $labels.instance }} without the server's confirming `is active` line, so the advertised code most likely does not resolve and no player can join — while the server process itself reads healthy. These arrive in episodes lasting 1-3.5h in which every registration fails, so a restart only takes once the episode has ended — which is why valheim-joincode-watchdog is already re-registering on its own, every 15 minutes, uncapped, for as long as the code stays unconfirmed and the server stays empty. Expect no action: this clears when PlayFab starts confirming again. `journalctl -u valheim-joincode-watchdog` shows the attempts, and logs at error level once the episode outlasts every one on record. See the join-code notes in modules/apps/valheim.nix (#683, #694, #701).";
          };
        }
        {
          alert = "ValheimMetricsStale";
          expr = ''time() - node_textfile_mtime_seconds{file="${textfileDir}/valheim.prom"} > 900'';
          for = "10m";
          labels.severity = "warning";
          annotations = {
            summary = "Valheim metrics are stale on {{ $labels.instance }}";
            description = "valheim.prom has not been rewritten for {{ $value | humanizeDuration }} on {{ $labels.instance }}, so every Valheim alert is now evaluating stale data and cannot be trusted. Check valheim-metrics.service and its timer.";
          };
        }
      ];
    }
  ];

  # The relay counters' totals and cursor (#627). See the
  # `metricsStateDir` note in the `let` block above for why this is
  # preserved but deliberately kept out of restic. Keep the root
  # ownership and mode inherited by the former bare preservation entry.
  myAppState.valheim-metrics = {
    stateDir = metricsStateDir;
    user = "root";
    group = "root";
    mode = "0755";
    backup = false;
  };

  systemd.services = {
    # Per-unit journald rate cap, so a GetPublicIP wedge (see that
    # section at the top of this file) can't consume the host's whole
    # journal again. 2400 per 30s = 80 lines/sec.
    #
    # This is deliberately a *per-unit* cap rather than the global
    # `RateLimitBurst` tightening floated in #590, because the global
    # lever no longer works. journald's stock setting is 10000/30s =
    # 333/s per service; the busiest legitimate burst on these hosts
    # (nix-gc) peaks around 137/s, and the wedge now runs at ~160/s
    # once the VALHEIM_LOG_FILTER_CONTAINS_* filters below have taken
    # 60% of it out. Those two numbers are close enough that no global
    # threshold is both safe for nix-gc and effective against the
    # runaway — filtering the flood closed the window a global cap
    # needed. A per-unit cap has no such conflict: it only constrains
    # the one unit with a known pathology.
    #
    # 80/s is ~25x healthy valheim traffic (~3/s), so this never binds
    # in normal operation, and it stays above the 50/s
    # `JournalLogRateHigh` threshold in modules/system/victoriametrics.nix
    # so a capped wedge still alerts rather than going quiet — same
    # reason the log filter is partial. journald additionally logs
    # "Suppressed N messages from podman-valheim.service" when the cap
    # engages, which names the culprit outright.
    #
    # Merges into the unit generated by virtualisation.oci-containers.
    podman-valheim.serviceConfig = {
      LogRateLimitIntervalSec = "30s";
      LogRateLimitBurst = 2400;
    };

    # Valheim is invisible to every existing alert path, so this
    # publishes the missing signals to the node_exporter textfile
    # collector for vmalert to consume:
    #
    #   - gatus can't watch it — the server is UDP-only under
    #     crossplay and STATUS_HTTP is off, so there is no endpoint.
    #   - SystemdUnitFailed watches the wrong layer. supervisord
    #     restarts valheim-server *inside* the container, so systemd
    #     holds podman-valheim.service `active` the whole time the
    #     game server is crash-looping.
    #   - cAdvisor only scrapes /system.slice/podman-valheim.service,
    #     which is the conmon wrapper (~1 MiB, flat forever). The
    #     payload cgroup that actually holds the game server
    #     (/machine.slice/libpod-<id>.scope/container) is not in its
    #     series at all, so no timeseries tracked the server's memory.
    #
    # That last gap is the load-bearing one: the RESTART_CRON bounce
    # (see the restart-cadence notes at the top of this file) exists
    # upstream purely as insurance against a game-server memory leak,
    # and nothing here could have told us whether that leak was real.
    # These metrics are what paid for pulling the cron back from daily
    # to weekly, and they are what Phase 2 will be judged on — see
    # #458.
    #
    # Everything is read from the host PID namespace: `--network=host`
    # means valheim_server.x86_64 is plainly visible in /proc, so this
    # never shells into the container. A wedged or paused podman can't
    # make the exporter hang, and there's no dependency on the podman
    # units at all — no `after=`, no `requires=`.
    #
    # `valheim_players_online` (#631) keeps that property. It comes
    # from valheim-player-notify's roster, but by reading two files
    # out of /run, not by depending on the unit: a stuck notifier
    # costs the gauge and nothing else. See the `playerRoster` notes
    # at the top of this file.
    #
    # So do the relay counters (#627), which read the journal rather
    # than the container: journalctl talks to /var/log/journal, so a
    # wedged or paused podman still can't stall this unit — the
    # container's output has already been written by the time this
    # reads it. See "PlayFab peer-relay stalls" at the top of this
    # file for what they measure and why they are worth having.
    valheim-metrics = {
      description = "publish valheim server health to node_exporter textfile collector";
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        # Holds the relay counters' running totals and journal
        # cursor (#627). Root unit, so this is ${metricsStateDir}
        # rather than /var/lib/private.
        StateDirectory = baseNameOf metricsStateDir;
        Environment = [
          "PATH=${
            lib.makeBinPath [
              pkgs.coreutils
              pkgs.procps
              pkgs.gawk
              # journalctl, for the relay counters below.
              pkgs.systemd
            ]
          }"
        ];
      };
      script = ''
        set -eu
        out=${textfileDir}/valheim.prom
        mkdir -p "$(dirname "$out")"

        up=0
        rss=0
        uptime=0
        cgmem=0
        players=${joincodeGaugeReadLine}

        # `|| true` so `set -e` survives the no-match case: pgrep exits
        # 1 when the server is down, which is a value we want to
        # publish (up=0), not an error that should kill the unit.
        pid=$(pgrep -f valheim_server.x86_64 | head -1 || true)
        if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
          up=1

          rss_kb=$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status" 2>/dev/null || true)
          [ -n "$rss_kb" ] || rss_kb=0
          rss=$(( rss_kb * 1024 ))

          uptime=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -dc '0-9' || true)
          [ -n "$uptime" ] || uptime=0

          # Resolve the payload cgroup from the process itself rather
          # than hardcoding a libpod path — the container id changes
          # every time the container is recreated.
          cg=$(awk -F: 'NR==1{print $3}' "/proc/$pid/cgroup" 2>/dev/null || true)
          if [ -n "$cg" ] && [ -r "/sys/fs/cgroup$cg/memory.current" ]; then
            cgmem=$(cat "/sys/fs/cgroup$cg/memory.current" 2>/dev/null || echo 0)
          fi
        fi

        # Player count, one line per connected player, straight off
        # valheim-player-notify's roster (#631). Read outside the
        # `up` block on purpose: the roster is the notifier's state,
        # not the game process's, and gating it on pgrep would make
        # the gauge vanish for a different reason than it already
        # does below.
        #
        # Every other presence signal this server emits is known bad
        # under crossplay — the A2S query always answers 0, the
        # `IDLE_DATAGRAM_*` counting the image uses instead trips on
        # PlayFab lobby chatter, and the `now N player(s)` log lines
        # are internally inconsistent (a 3->2 leave logged "now 3").
        # The roster is derived from ZDO ownership instead, which is
        # why it is the source here.
        #
        # `$players` stays empty unless the marker says the roster is
        # both present and rebuilt, and an empty value omits the
        # series entirely rather than publishing 0. The asymmetry is
        # deliberate and load-bearing for #458, which wants to gate
        # the restart cron on an empty server: a wrong 0 bounces a
        # server with players on it, while a missing sample just
        # fails the rule's guard and skips the bounce. A companion
        # `_valid` gauge would instead keep publishing that wrong 0
        # next to a flag any rule can forget to check. So: absent.
        # Ask with `absent_over_time(valheim_players_online[...])` if
        # the gap itself ever needs alerting.
        #
        # This is also why hpp-1 never publishes the series at all —
        # it runs `playerNotify = false`, so there is no roster to
        # read and no gauge, with no extra gating needed here.
        if [ -e ${playerRosterReady} ]; then
          players=$(awk 'END { print NR }' ${playerRoster} 2>/dev/null || true)
        fi

        # PlayFab peer-relay stalls (#627). Under crossplay a peer
        # whose relay endpoint faults leaves its socket held open for
        # the full 90s ZRpc timeout, and Valheim distributes
        # simulation by ZDO ownership — so for those 90s every
        # creature and object that peer was simulating is frozen for
        # everyone else. Players read that as "the server died"; the
        # host is idle and healthy throughout, and nothing else in
        # the monitoring stack can see it. These two counters are
        # what make the frequency trendable, and the only way to tell
        # whether a future image or game update helped.
        #
        # Counted incrementally against a saved cursor rather than by
        # rescanning, for two independent reasons:
        #
        #   - Honesty. journald is a *window*, not a ledger. amos1's
        #     4G cap fell to 6.5 hours of retention during the #590
        #     wedge, so a rescanned total would drop when the journal
        #     vacuumed — which PromQL reads as a counter reset and
        #     turns into a phantom increase, exactly inverting the
        #     trend this is for.
        #   - Cost. A --grep over amos1's retained journal for this
        #     unit takes over two minutes; this timer fires every
        #     two. Anchored to a cursor, each run reads one interval.
        #
        # Both counters are unlabelled on purpose. The natural label
        # is the peer id, but those are per-connection and unbounded
        # over time (six distinct peers in the two days #627 sampled),
        # so labelling would grow the textfile series set without
        # limit for a question — "is this getting worse?" — that is
        # asked in aggregate anyway. The per-peer breakdown stays a
        # journal grep.
        stalls=0
        timeouts=0
        if [ -r ${relayTotalsFile} ]; then
          read -r stalls timeouts < ${relayTotalsFile} || true
        fi
        case "$stalls" in "" | *[!0-9]*) stalls=0 ;; esac
        case "$timeouts" in "" | *[!0-9]*) timeouts=0 ;; esac

        # The unit's newest cursor, read *before* counting. Used to
        # seed the first run, and as a fallback position if the
        # counting pass reports none.
        #
        # Reading it first is what makes that fallback safe: an entry
        # written while the counting pass runs is necessarily *after*
        # this cursor, so falling back to it can only ever re-read
        # entries, never skip past unread ones. Cheap — journalctl
        # seeks straight to the tail.
        tailcursor=$(journalctl -u podman-valheim.service -n 1 -o cat --show-cursor 2>/dev/null \
          | awk '/^-- cursor: /{ print substr($0, 12) }' || true)

        if [ -s ${relayCursorFile} ]; then
          # awk rather than grep for the tally because one pass has
          # to yield three things — two independent counts and the
          # trailing cursor — and grep gives one. (Not for the reason
          # it first looks like: `-o cat` does emit the container's
          # trailing newline as a blank line after every entry, which
          # doubles a `wc -l`, but a blank line matches neither
          # pattern so `grep -c` would have been fine on that count.)
          delta=$(journalctl -u podman-valheim.service -o cat --show-cursor \
            --after-cursor="$(cat ${relayCursorFile})" \
            --grep=${lib.escapeShellArg relayJournalPattern} 2>/dev/null \
            | awk '
                /${relayStallMatch}/   { s++ }
                /${relayTimeoutMatch}/ { t++ }
                /^-- cursor: /         { c = substr($0, 12) }
                END { printf "%d %d %s\n", s, t, c }
              ' || true)
          read -r dstalls dtimeouts dcursor <<<"$delta" || true
          case "$dstalls" in "" | *[!0-9]*) dstalls=0 ;; esac
          case "$dtimeouts" in "" | *[!0-9]*) dtimeouts=0 ;; esac
          stalls=$(( stalls + dstalls ))
          timeouts=$(( timeouts + dtimeouts ))
          # `--show-cursor` reports the position the scan *ended* at,
          # not the last matching entry — verified on amos1: a run
          # with an impossible --grep pattern still prints a cursor,
          # byte-identical to the unit's tail. So the cursor advances
          # to the tail every run, matches or not, and an idle server
          # never re-scans a growing span.
          #
          # The fallback covers the one case that prints nothing at
          # all: a unit with no journal entries yet. Kept rather than
          # relying on the above, since that behaviour is observed
          # rather than documented, and it costs one already-taken
          # variable.
          [ -n "$dcursor" ] || dcursor="$tailcursor"

          # Known limit, measured rather than assumed: a stored
          # cursor that journald has already vacuumed past does not
          # error. journalctl seeks to the *head* of what survives and
          # re-emits it, so that one pass re-counts the whole retained
          # window (verified on amos1 with a hand-rewound cursor: it
          # returned the full 30/25 rather than 0/0). The counter
          # steps up once and stays consistent after.
          #
          # Deliberately not guarded. The cursor is dragged to the
          # journal tail every two minutes, so falling behind
          # retention needs this unit absent for longer than the
          # journal keeps — which is not the #590 wedge (the timer
          # keeps advancing the cursor right through it) but a host
          # down or the unit stopped for days. Against a counter read
          # as a trend, a one-off step of at most one retention
          # window is not worth machinery to detect.
        else
          # First run, or state lost. Seed at the tail and start
          # counting from now rather than backfilling the journal:
          # every historical event would otherwise land in one scrape
          # interval as a single false spike, dated to today instead
          # of to when it happened.
          dcursor="$tailcursor"
        fi
        # Both state files are written tempfile + rename, for the same
        # reason the .prom below is: a torn write is silent here, and
        # worse than a crash. A half-written cursor makes journalctl
        # fail its seek ("Failed to seek to cursor: Invalid
        # argument") — which prints no `-- cursor:` line at all, so
        # the fallback above quietly jumps to the tail and every
        # entry in between goes uncounted, with nothing in the log to
        # say so. A torn totals file just reads back as garbage and
        # is floored to 0 by the guards above, silently discarding
        # the running total.
        #
        # `if` rather than `[ -n … ] && …`: the script runs under the
        # `set -e` NixOS injects into `script =`, and a bare `&&` list
        # whose left side is false returns non-zero, which would kill
        # the unit on the perfectly ordinary "unit has no journal
        # entries yet" path. Same class as the #640 fix in
        # valheim-player-notify below.
        if [ -n "$dcursor" ]; then
          ctmp=$(mktemp -p ${metricsStateDir} .journal-cursor.XXXXXX)
          printf '%s\n' "$dcursor" > "$ctmp"
          mv "$ctmp" ${relayCursorFile}
        fi
        ttmp=$(mktemp -p ${metricsStateDir} .relay-totals.XXXXXX)
        printf '%s %s\n' "$stalls" "$timeouts" > "$ttmp"
        mv "$ttmp" ${relayTotalsFile}

        # Atomic write via tempfile + rename so a crashed run never
        # leaves node_exporter reading a half-written .prom.
        tmp=$(mktemp -p "$(dirname "$out")" .valheim.prom.XXXXXX)
        {
          echo "# HELP valheim_server_up Whether the valheim_server process is running (1) or not (0)."
          echo "# TYPE valheim_server_up gauge"
          echo "valheim_server_up $up"
          echo "# HELP valheim_server_rss_bytes Resident set size of the valheim_server process. The leak signal: anonymous memory only, so it is not inflated by the page cache that steamcmd and world saves push into the cgroup."
          echo "# TYPE valheim_server_rss_bytes gauge"
          echo "valheim_server_rss_bytes $rss"
          echo "# HELP valheim_server_uptime_seconds Seconds since the valheim_server process started. Resets on every supervisord restart, so a value that stays low means the server is crash-looping."
          echo "# TYPE valheim_server_uptime_seconds gauge"
          echo "valheim_server_uptime_seconds $uptime"
          echo "# HELP valheim_container_memory_bytes memory.current of the container payload cgroup. Total footprint including page cache, so it runs several GiB above RSS and is context rather than a leak signal."
          echo "# TYPE valheim_container_memory_bytes gauge"
          echo "valheim_container_memory_bytes $cgmem"
          echo "# HELP valheim_peer_relay_stall_total PlayFab relay faults that suspended TX to a peer ('Failed to send, suspend TX'). Each one freezes every ZDO that peer owned for up to the 90s ZRpc timeout. Counted incrementally from a saved journal cursor, so it survives journald vacuuming; resets only if ${metricsStateDir} is lost."
          echo "# TYPE valheim_peer_relay_stall_total counter"
          echo "valheim_peer_relay_stall_total $stalls"
          echo "# HELP valheim_zrpc_timeout_total Peers evicted by Valheim's 90s ZRpc timeout ('ZRpc timeout detected'), which is when the objects a stalled peer owned unfreeze. Trails valheim_peer_relay_stall_total, since a peer that reconnects in time never times out."
          echo "# TYPE valheim_zrpc_timeout_total counter"
          echo "valheim_zrpc_timeout_total $timeouts"
          if [ -n "$players" ]; then
            echo "# HELP valheim_players_online Players currently connected, from the valheim-player-notify roster. Absent rather than 0 whenever that roster is missing or mid-rebuild, so no-data and nobody-online stay distinguishable."
            echo "# TYPE valheim_players_online gauge"
            echo "valheim_players_online $players"
          fi${joincodeGaugeEmitLine}
        } > "$tmp"
        chmod 0644 "$tmp"
        mv "$tmp" "$out"
      '';
    };
  };

  systemd.timers = {
    valheim-metrics = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "2m";
        Unit = "valheim-metrics.service";
      };
    };
  };
}
