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
    # A prefix→name roster, built from two lines that are reliable:
    #
    #   Got character ZDOID from <name> : <prefix>:<n>
    #   Destroying abandoned non persistent zdo <prefix>:<n> owner <prefix>
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
        set -uo pipefail

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

        : > "$roster"

        # Set for the replay pass below, cleared before the live
        # follow: the roster is rebuilt silently so that restarting
        # this unit mid-session doesn't re-announce the session's
        # whole history to the channel.
        quiet=1

        post() {
          # allowed_mentions parse:[] because the player name is
          # attacker-controlled — a character called "@everyone"
          # would otherwise ping the server every time they spawn.
          payload="$("$jq" -nc --arg t "$1" \
            '{content: $t, allowed_mentions: {parse: []}}')"

          # url via `-K -` (stdin) so the webhook secret never lands
          # in the process cmdline. A failed POST must not kill the
          # watcher — log it and keep following the journal.
          if printf 'url = "%s"\n' "$webhook" \
            | "$curl" -fsS -K - \
                -X POST -H 'Content-Type: application/json' -d "$payload"; then
            echo "posted: $1"
          else
            echo "failed to post to discord: $1" >&2
          fi
        }

        online() { "$awk" 'END { print NR }' "$roster"; }

        # awk rather than grep for the lookup: prefixes are signed and
        # a negative one ("-367286238") would be parsed as an option.
        roster_name() {
          "$awk" -F'\t' -v p="$1" '$1 == p { print $2; exit }' "$roster"
        }

        join() {
          prefix="$1"
          name="$2"
          # Already present: a respawn, not a new session.
          [ -n "$(roster_name "$prefix")" ] && return 0
          printf '%s\t%s\n' "$prefix" "$name" >> "$roster"
          [ "$quiet" = 1 ] && return 0
          post "**$name** joined **$server** — $(online) online"
        }

        leave() {
          prefix="$1"
          name="$(roster_name "$prefix")"
          # Absent: either a later line of the same destroy burst, or
          # a ZDO owned by someone who was never on the roster.
          [ -n "$name" ] || return 0
          "$awk" -F'\t' -v p="$prefix" '$1 != p' "$roster" > "$roster.tmp" \
            && mv "$roster.tmp" "$roster"
          [ "$quiet" = 1 ] && return 0
          post "**$name** left **$server** — $(online) online"
        }

        # Normalise the journal to tab-separated events, so the
        # dispatcher below is the same code for the replay and the
        # live follow. J=spawn, L=zdo destroyed, R=server lifecycle,
        # C=journal cursor (emitted by --show-cursor, last in a
        # non-following stream).
        #
        # `-u` is load-bearing, not a tidiness flag. sed's stdout here
        # is a pipe, so without it stdio picks full buffering and holds
        # output until 4 KiB accumulates. Events are a few dozen bytes
        # and arrive minutes to hours apart, so in the *live* pass that
        # buffer never fills and every notification is stranded — the
        # unit sits `active (running)`, journalctl keeps flushing into
        # it (verified: journalctl -f flushes per entry), and nothing is
        # ever posted. The replay pass hid it, because EOF flushes: the
        # roster rebuilt correctly, which is exactly why the unit looked
        # healthy while announcing nothing from 09-14 through 09-15.
        # `valheim-joincode-notify` above dodges this with `sed -u`
        # — the same flag on the same tool. (It used
        # `grep --line-buffered` when this comment was written; #661
        # moved it to sed and this cross-reference went stale.) Cost
        # is nil — journalctl's --grep means sed only ever sees the
        # handful of matching lines, not the raw journal.
        normalize() {
          "$sed" -u -nE \
            -e 's/.*Got character ZDOID from (.+) : (-?[0-9]+):[0-9]+[[:space:]]*$/J\t\2\t\1/p' \
            -e 's/.*Destroying abandoned non persistent zdo -?[0-9]+:[0-9]+ owner (-?[0-9]+)[[:space:]]*$/L\t\1/p' \
            -e 's/.*(New session server |Game - OnApplicationQuit).*/R/p' \
            -e 's/^-- cursor: (.*)$/C\t\1/p'
        }

        # Runs in a subshell on the right of a pipe, so all state it
        # touches is deliberately on disk rather than in shell vars.
        dispatch() {
          while IFS="$(printf '\t')" read -r kind a b; do
            case "$kind" in
              # prefix 0 is a death (ZDOID "0:0"), not a spawn.
              J) [ "$a" = 0 ] || join "$a" "$b" ;;
              L) leave "$a" ;;
              R) : > "$roster" ;;
              C) printf '%s\n' "$a" > "$cursorfile" ;;
            esac
          done
        }

        # --grep so the match happens inside journalctl instead of
        # dragging this boot's entire journal (tens of millions of
        # lines after a GetPublicIP wedge — see the top of this file)
        # through a pipe on every restart. stderr is deliberately not
        # suppressed: if --grep ever fails, this unit silently
        # announcing nothing forever is the worst outcome.
        pattern='Got character ZDOID from|Destroying abandoned non persistent zdo|New session server |Game - OnApplicationQuit'

        # Replay and position in a single pass. --show-cursor reports
        # the cursor of the last entry this pass actually consumed, so
        # the follow resumes exactly there: no entry is seen twice,
        # and none falls into a gap between the two passes. (The
        # join-code unit above reads its cursor separately and
        # tolerates the overlap because its marker collapses a repeat;
        # here a repeat would be absorbed silently by the roster and
        # the notification would be *lost*, so the boundary has to be
        # exact.)
        #
        # The `if !` is load-bearing, not style (#640). NixOS emits
        # this script with `set -e` in the generated wrapper — the
        # script's own `set -uo pipefail` deliberately omits `-e`,
        # which is moot — so combined with pipefail a non-zero
        # journalctl aborts the unit outright, before even the
        # "roster rebuilt" line below. journalctl exits 1 both for
        # "no entries matched" and for a real error, and *no entries
        # matched is the normal state for the first ~60s of a boot*:
        # the container has not logged a session line yet. So this
        # raced the container on every boot and fail-looped both
        # notify units until it happened to win — 4 failed starts on
        # 2026-09-15, 10 on 09-14, each recovering ~2s after the
        # first matching line appeared. An empty backlog is a fine
        # starting state; the live follow below catches everything
        # after it. A genuine journalctl error stays visible because
        # stderr is still not suppressed.
        if ! "$journalctl" -u podman-valheim.service -b --lines=all -o cat \
          --show-cursor --grep="$pattern" | normalize | dispatch; then
          echo "no matching entries for this boot yet (or journalctl failed — check stderr above); starting from an empty roster"
        fi

        echo "roster rebuilt from journal: $(online) player(s) online"

        # Only now is the roster an answer rather than a half-filled
        # file. valheim-metrics keys its gauge on this marker; see the
        # `playerRosterReady` note at the top of this file for why the
        # roster file's own existence is not enough.
        : > "$ready"

        quiet=0

        if [ -s "$cursorfile" ]; then
          set -- -f --after-cursor="$(cat "$cursorfile")"
        else
          # Nothing matched this boot, so there is no cursor to anchor
          # to: follow from now and take only new entries.
          set -- -b -f --lines=0
        fi

        "$journalctl" -u podman-valheim.service "$@" -o cat --grep="$pattern" \
          | normalize | dispatch
      '';
    };
  };
}
