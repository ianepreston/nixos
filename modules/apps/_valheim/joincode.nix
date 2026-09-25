# Valheim crossplay join-code notifier and watchdog (and the watchdog's timer).
# Crossplay-only: ../valheim.nix guards this fragment with
# `mkIf cfg.crossplay`, so a Steam-backend host renders none of it.
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
    joincodeRuntimeDir
    joincodeMarker
    joincodePending
    joincodeAlerted
    joincodeRetried
    joincodeGraceSeconds
    joincodeRetryInterval
    joincodeRetryLoudAfter
    playerRoster
    playerRosterReady
    ;
in
{
  systemd.services = {
    # The crossplay join code is issued fresh by PlayFab on every
    # server start — an auto-upgrade or a container bounce silently
    # invalidates whatever code players are holding. This watches the
    # server log and pushes each new code to Discord so nobody has to
    # notice the hard way.
    #
    # Source is journalctl rather than `podman logs` so the watcher
    # survives the container being recreated (a new container id
    # orphans a `podman logs -f`).
    #
    # The read is deliberately two passes rather than one following
    # invocation, because neither single-pass form is correct:
    #
    #   `-b -f`               `-f` implies `--lines=10` and that cap
    #                         beats `-b`, so this backfills ten lines,
    #                         not the boot. The join-code line sits
    #                         thousands of lines back in a running
    #                         server's journal, so a watcher starting
    #                         any time after server startup matches
    #                         nothing and stays mute forever.
    #   `-b -f --lines=all`   Replays every code line since boot on
    #                         every watcher start. The marker below
    #                         only suppresses repeats of the code it
    #                         last announced, so a boot that saw
    #                         several distinct codes re-announces the
    #                         whole sequence on each restart — one
    #                         burst of stale Discord messages per
    #                         deploy.
    #
    # So: pass 1 reads the backlog and announces only the newest code
    # in it; pass 2 follows from a cursor for live changes. Exactly one
    # announcement per distinct code.
    #
    # The cursor is captured *before* the backlog scan, not after. That
    # ordering is what closes the gap: a code landing between the two
    # reads is at or after the cursor, so it is caught by the follow
    # (and possibly also by the backlog scan — an overlap the marker
    # collapses). Reading the cursor after the scan would instead leave
    # a window in which a code is in neither pass and is never
    # announced.
    #
    # Dedupe state lives in RuntimeDirectory (/run), not /var/lib, on
    # purpose: a reboot restarts the server and therefore rotates the
    # code, so losing the marker exactly when it stops being true is
    # the correct behaviour — and it keeps this out of the
    # preservation/restic bookkeeping in server-apps.nix entirely.
    #
    # That rationale holds for reboots and is why it is still /run,
    # but it is not the whole rule any more. A *container* restart
    # also re-registers, and PlayFab will hand back the same digits
    # off the deterministic custom ID — so "restarted" and "rotated"
    # are not the same event, and the marker can outlive the code's
    # validity without outliving its value. #683 is exactly that
    # case: recovering from an unconfirmed code re-registered the
    # identical number and the marker swallowed the announcement
    # that it worked again. `handle_active` below drops the marker
    # when the watchdog has flagged the episode, so liveness gets
    # announced even when the digits do not change (#683).
    valheim-joincode-notify = {
      description = "Post the Valheim crossplay join code to Discord when it changes";
      # The sops edge is load-bearing, not decorative: without it this
      # unit starts during activation before sops-install-secrets has
      # written the webhook, dies on the missing file, and takes the
      # whole `switch-to-configuration` to exit 4 (= some units failed)
      # — i.e. a red deploy. `restartUnits` on the secret does heal it
      # a beat later, but the failed-unit window is what breaks the
      # deploy. Ordering only (no requires/wants): the unit is
      # Type=oneshot *without* RemainAfterExit, so it deactivates after
      # running and a hard dependency would drag this down with it.
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
        RuntimeDirectory = "valheim-joincode-notify";
        # Without this systemd deletes RuntimeDirectory every time the
        # unit stops, so the dedupe marker vanishes on each restart and
        # every deploy re-announces an unchanged code. "yes" keeps it
        # across unit restarts while /run being a tmpfs still clears it
        # on reboot — which is the wanted semantics, since a reboot
        # rotates the code anyway.
        RuntimeDirectoryPreserve = "yes";
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

        marker=${joincodeMarker}
        pending=${joincodePending}
        alerted=${joincodeAlerted}
        retried=${joincodeRetried}
        webhook="$(cat ${config.sops.secrets."valheim/discord_webhook".path})"
        server=${config.virtualisation.oci-containers.containers.valheim.environment.SERVER_NAME}

        notify() {
          code="$1"
          if [ -f "$marker" ] && [ "$(cat "$marker")" = "$code" ]; then
            echo "join code $code already announced, skipping"
            return 0
          fi

          payload="$(${pkgs.jq}/bin/jq -nc \
            --arg code "$code" \
            --arg server "$server" \
            '{content: ("Valheim server **" + $server + "** is up.\nCrossplay join code: **" + $code
                        + "**\n_This code changes every time the server restarts._")}')"

          # url via `-K -` (stdin) so the webhook secret never lands
          # in the process cmdline. A failed POST must not kill the
          # watcher — log it and keep following the journal.
          if printf 'url = "%s"\n' "$webhook" \
            | ${pkgs.curl}/bin/curl -fsS -K - \
                -X POST -H 'Content-Type: application/json' -d "$payload"; then
            echo "announced join code $code"
            echo "$code" > "$marker"
          else
            echo "failed to post join code $code to discord" >&2
          fi
        }

        # A registration, i.e. a code the server has *offered*. Not
        # announced — that is still the `is active` line's job, and
        # #661 is what happens when this line is trusted instead.
        # Recorded so that a confirmation which never arrives becomes
        # observable: valheim-joincode-watchdog alerts on the age of
        # this file and valheim-metrics publishes it as a gauge.
        #
        # An unchanged code already pending keeps its original
        # timestamp. The server re-logs `registered with` on every
        # lobby re-registration (3 times on 2026-09-12 alone), and
        # rewriting the epoch each time would walk the deadline
        # forward forever and the watchdog would never fire. Same
        # code with no confirmation in between is one unconfirmed
        # episode, not a new one.
        handle_reg() {
          code="$1"
          when="$2"
          # `pcode` is pre-set because this script runs under
          # `set -u`: a torn or empty pending file makes `read`
          # return non-zero having assigned nothing, and an unbound
          # expansion below would take the whole unit down. Same
          # class of foot-gun as #640, different trigger.
          pcode=
          if [ -f "$pending" ]; then
            read -r pcode _rest < "$pending" || true
            if [ "$pcode" = "$code" ]; then
              return 0
            fi
          fi
          # Reaching here means a *different* code is now pending,
          # which is a new episode: drop the watchdog's
          # already-announced flag so this one can be announced on
          # its own merits. Without this, a restart that re-registers
          # under a fresh number and fails again inherits the old
          # flag and goes unreported.
          #
          # `retried` deliberately does *not* go with it, though it
          # is tempting: a new code looks like a new episode, so
          # restarting its clock looks right. It is the one thing
          # that must not happen here. `retried` is the only pacing
          # the watchdog's restart loop has, and this branch is
          # reachable *from that loop* — a probe whose
          # re-registration comes back with different digits (#661
          # saw PlayFab mint two codes seconds apart). Clearing it
          # there would drop the spacing to grace + one tick and
          # bounce the container every ~3 minutes, which is exactly
          # what joincodeRetryInterval and ValheimServerRestartLoop
          # exist to prevent. Spacing means "when did I last
          # restart", and nothing a restart can itself cause may
          # reset it; the episode genuinely ending is
          # handle_active's job, and it clears `retried` there.
          rm -f "$alerted"
          printf '%s %s\n' "$code" "$when" > "$pending"
        }

        # A confirmation. Clears the pending registration, then
        # announces under the usual dedupe.
        #
        # The `alerted` branch is the one non-obvious part. A
        # container restart does not necessarily rotate the code:
        # PlayFab hands back the same digits via the deterministic
        # custom ID, which is exactly what happened recovering from
        # #683 — the fix-restart re-registered 496995 and the marker
        # suppressed the announcement as "already announced". By the
        # dedupe rule that is correct; in context it is wrong, because
        # what changed was whether the code *resolves*, not what it
        # is. So when the watchdog has told the channel this code is
        # broken, drop the marker and let the confirmation through:
        # the news is liveness, not novelty.
        #
        # Deliberately *not* dropping the marker on every `reg`. That
        # would re-announce on each ordinary lobby re-registration —
        # 1-3 unchanged-code messages a day, which is the stale-burst
        # the dedupe exists to prevent.
        handle_active() {
          code="$1"
          # `retried` clears with `pending`: the episode is over, so
          # the watchdog's attempt counter and spacing clock are
          # both spent state. The next episode starts from zero.
          rm -f "$pending" "$retried"
          if [ -e "$alerted" ]; then
            echo "join code $code confirmed after being announced unconfirmed; re-announcing"
            rm -f "$marker" "$alerted"
          fi
          notify "$code"
        }

        # Route one tagged event. Tags come from the sed programs
        # below, which is the only place the journal's wording is
        # known.
        dispatch() {
          while read -r tag code when; do
            case "$tag" in
              reg) handle_reg "$code" "''${when:-$(date +%s)}" ;;
              active) handle_active "$code" ;;
            esac
          done
        }

        journalctl=${pkgs.systemd}/bin/journalctl
        sed=${pkgs.gnused}/bin/sed

        # Position first, read second — see the cursor note above.
        # `--show-cursor` appends a `-- cursor: <id>` line after the
        # last entry, which is what -n 1 is here to produce cheaply.
        #
        # `|| true` because NixOS generates this script with `set -e`
        # in the wrapper, so with pipefail any stage of this pipeline
        # exiting non-zero aborts the whole unit. See the longer note
        # on the replay guard in valheim-player-notify below (#640).
        # An empty cursor is already handled: it selects the
        # follow-from-now branch further down.
        #
        # No stage here is currently known to exit non-zero at
        # runtime. An earlier version of this comment blamed
        # journalctl "legitimately exiting 1 when the container has
        # logged nothing this boot yet"; that was never measured and
        # is wrong — journalctl exits 0 for a unit with no entries,
        # for an unknown unit, and when it cannot read the journal,
        # and reaches 1 only on malformed arguments, which is a
        # build-time bug rather than a runtime state. The real #640
        # culprit was grep, in the backlog pass below. So treat this
        # as deliberate insurance for a future edit that reintroduces
        # a filter which does exit non-zero on no-match, not as a
        # guard against something live.
        cursor="$("$journalctl" -u podman-valheim.service -b -n 1 -o cat --show-cursor 2>/dev/null \
          | "$sed" -n 's/^-- cursor: //p')" || true

        # Pass 1 — backlog. The pattern matches the *authoritative*
        # line, which is
        #
        #   Session "<name>" with join code <N> and IP <ip>:<port> is active with <n> player(s)
        #
        # and not the `registered with join code <N>` line this used
        # to key on. That one reports the code the server *offered* at
        # re-registration, which PlayFab is free to reject and
        # replace. On 2026-09-18 it did: re-registration echoed
        # 496995, PlayFab minted 809934 and then 555295 a second
        # later, the session went live on 555295 — and this watcher
        # announced 496995, which no remote player could resolve
        # (#661). Nothing in the unit's own output looked wrong,
        # because the stale code matched the dedupe marker from that
        # morning and was skipped as "already announced".
        #
        # The `is active` line cannot name a dead code: the server
        # emits it only after its own `Retry join-code check`
        # countdown confirms the code resolves. It is also the line
        # the header comment tells an operator to grep by hand, so
        # watcher and runbook now agree rather than disagreeing
        # silently.
        #
        # It can, however, fail to appear at all — the corollary
        # #661 did not have to think about and #683 is. A line that
        # cannot lie is still no use when it is never written, and
        # keying on it alone made silence carry two meanings. Hence
        # the `reg` shape below: not to announce from (that is still
        # forbidden), but to know that a confirmation is *owed*, so
        # its absence becomes a fact the watchdog can act on rather
        # than the absence of a fact.
        #
        # Deliberately *not* also matching `Created new join code
        # <N>`. It fires ~3s earlier, but it names every candidate
        # including ones that go on to fail the retry check — 809934
        # above is exactly such a code.
        #
        # `sed -n` capture rather than `grep -oE` plus a positional
        # read: the IP field makes the match variable-length, so
        # counting whitespace fields no longer finds the code. Only
        # the newest match is announced; earlier ones in this boot are
        # already stale.
        #
        # `|| true` for the same reason as the cursor above: under
        # pipefail + the wrapper's `set -e`, a non-zero exit in this
        # pipeline kills the unit — which is what 4 failed starts on
        # 2026-09-15 were, clearing only once a code appeared at
        # 05:19:59 (#640).
        #
        # That was `grep` exiting 1 on no-match, and this pass no
        # longer runs grep: `sed -n ...p` exits 0 whether or not it
        # printed. The guard is therefore no longer load-bearing, and
        # is kept only so that swapping the filter back to something
        # grep-like cannot silently re-arm #640. "No code yet" is
        # exactly what the empty branch below is written to handle,
        # and it is reached via sed's empty output, not via this
        # guard.
        # `-o short-unix` rather than `-o cat` for this pass only.
        # The backlog can end on an *unconfirmed* registration, and
        # seeding the watchdog's deadline from it needs that line's
        # real timestamp — `date +%s` would restart the clock at unit
        # start and a restart during an outage would postpone the
        # alert indefinitely. The live pass below keeps `-o cat`,
        # where the line has just arrived and now is its timestamp.
        #
        # Both sed programs stay anchored on `.*` prefixes, so the
        # added `<epoch>.<usec> <host> <unit>:` prefix changes
        # nothing about what they match. The two shapes cannot
        # collide: the confirmation reads `" with join code"` and the
        # registration `"registered with join code"`, and only the
        # former carries `and IP … is active`. The image's third
        # shape (`New session server … that has join code ,` — note
        # the empty code) matches neither.
        backlog="$("$journalctl" -u podman-valheim.service -b --lines=all -o short-unix 2>/dev/null \
          | "$sed" -n -E \
              -e 's/^([0-9]+)\.[0-9]+ .*with join code ([0-9]+) and IP .* is active.*/active \2 \1/p' \
              -e 's/^([0-9]+)\.[0-9]+ .*registered with join code ([0-9]+).*/reg \2 \1/p' \
          | tail -1)" || true
        if [ -n "$backlog" ]; then
          # Only the newest event matters. If that is a confirmation,
          # announce it; if it is a registration with no confirmation
          # after it, this boot is *currently* in the #683 state and
          # the watchdog takes it from the pending file. Any earlier
          # code in the backlog is stale either way.
          printf '%s\n' "$backlog" | dispatch
        else
          echo "no join code in the journal for this boot yet; following for one"
        fi

        # Pass 2 — live. Following from the cursor means no historical
        # entry is re-emitted, so the marker is a guard against the
        # server relogging one unchanged code rather than the thing
        # holding back a replay burst.
        if [ -n "$cursor" ]; then
          set -- -f --after-cursor="$cursor"
        else
          # Empty journal for this unit this boot: nothing to anchor
          # to, so follow from now and take only new entries.
          set -- -b -f --lines=0
        fi

        # `-u` is what keeps this streaming: sed otherwise block-
        # buffers into a pipe and the announcement waits on a full
        # buffer's worth of journal, which on an idle server is
        # unbounded. It is the counterpart of the `grep
        # --line-buffered` this replaces.
        # No timestamp field emitted here, unlike the backlog pass:
        # `dispatch` fills a missing one with `date +%s`, which is
        # right for a line that has this instant come off the
        # journal.
        "$journalctl" -u podman-valheim.service "$@" -o cat \
          | "$sed" -n -E -u \
              -e 's/.*with join code ([0-9]+) and IP .* is active.*/active \1/p' \
              -e 's/.*registered with join code ([0-9]+).*/reg \1/p' \
          | dispatch
      '';
    };

    # The other half of #683: announce the *absence* of a
    # confirmation. valheim-joincode-notify is edge-triggered on the
    # `is active` line, so when that line never comes it emits
    # nothing — and nothing is also what a healthy idle server emits.
    # On 2026-09-20 an upstream NullReferenceException in
    # `ZPlayFabMatchmaking.OnCheckJoinCodeSuccess` killed the
    # confirmation state machine a second after registration, and
    # amos1 advertised an unresolvable code for 3h32m while every
    # signal on the host read healthy. A player found it.
    #
    # A timer rather than a read timeout inside the notifier's follow
    # loop: `read -t` only expires when the journal goes quiet, so on
    # a busy server the deadline would keep being reset — silent
    # exactly when the server is in use. Polling a timestamp is
    # indifferent to journal volume.
    #
    # It also re-registers, by restarting the container every
    # joincodeRetryInterval for as long as the code stays
    # unconfirmed (#701). An earlier version of this comment
    # declined to automate that on one data point; the second data
    # point arrived (#694) and changed the shape of the answer as
    # well as the answer.
    #
    # What changed is what a restart *is*. Within an episode every
    # registration fails — container restart, in-container
    # `supervisorctl restart`, a fresh PlayFab identity and a
    # reverted one all failed inside episode 2 — and outside one
    # every registration confirms in 1-2s. So a restart does not
    # fix anything; it asks whether the outage has ended, and the
    # server will never ask on its own (the NRE kills the join-code
    # state machine permanently while the lobby-refresh loop keeps
    # running). Asking repeatedly is therefore the only recovery
    # there is, and asking slowly forever beats asking hard and
    # giving up: both observed episodes would have shrunk from
    # 1h19m/3h32m to <= 15 minutes.
    #
    # "Bounces a prod game server" is also a smaller claim than it
    # was. Under crossplay there is no connect-by-address fallback,
    # so an unresolvable code admits nobody and an episode is a
    # zero-player server by construction — confirmed across all 5
    # failed registrations in #694. The roster guard below is a
    # safety net against that argument being wrong, not the
    # argument.
    valheim-joincode-watchdog = {
      description = "Alert to Discord and re-register when a Valheim join code is never confirmed";
      # Same sops edge as the notifier above — without it the first
      # run after activation dies on a missing webhook file. A
      # oneshot on a timer, so a failed run is not a failed deploy,
      # but ordering it costs nothing and keeps the pair symmetric.
      after = [
        "sops-install-secrets.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        # Shares the notifier's RuntimeDirectory rather than owning
        # one: these two units read and write the same four files,
        # and that sharing is the interface. `Preserve` must match
        # the notifier's, or a run of this oneshot would take the
        # directory — dedupe marker included — down with it on exit.
        RuntimeDirectory = baseNameOf joincodeRuntimeDir;
        RuntimeDirectoryPreserve = "yes";
        # Root: reads the sops secret. ProtectSystem=strict makes
        # /run read-only except for RuntimeDirectory, which is
        # exactly the one path this writes.
        #
        # None of this blocks the `systemctl restart` in the retry
        # branch. That is a D-Bus call to PID 1, so it needs
        # AF_UNIX (already here, for the webhook's resolver) and
        # writes nothing ProtectSystem covers; NoNewPrivileges is
        # irrelevant to a unit already running as root. Verified on
        # hpp-1 2026-09-21 with a systemd-run carrying this exact
        # property set: the restart went through, exit 0.
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

        pending=${joincodePending}
        alerted=${joincodeAlerted}
        retried=${joincodeRetried}
        roster=${playerRoster}
        rosterReady=${playerRosterReady}

        awk=${pkgs.gawk}/bin/awk
        systemctl=${pkgs.systemd}/bin/systemctl

        # Nothing registered, or the confirmation already landed and
        # the notifier cleared it. The overwhelmingly common case.
        if [ ! -f "$pending" ]; then
          exit 0
        fi

        # `if` rather than `&&`/`||` chains throughout this unit:
        # NixOS injects `set -e` into `script =`, so a bare test
        # returning non-zero kills the run. That is #640, and the
        # early-exit style above is what keeps it from coming back.
        read -r code when _rest < "$pending" || exit 0
        case "$when" in
          "" | *[!0-9]*) exit 0 ;;
        esac

        now=$(date +%s)
        age=$(( now - when ))
        if [ "$age" -lt ${toString joincodeGraceSeconds} ]; then
          exit 0
        fi

        # ## Announce — once per episode
        #
        # `alerted` used to short-circuit the whole unit. It now
        # guards only the Discord half, and that narrowing is the
        # point of #701: one message per episode, many restarts.
        # Leaving the retry behind this flag would fire exactly one
        # restart per episode, which is the capped design the
        # episode model rules out.
        if [ ! -e "$alerted" ]; then
          webhook="$(cat ${config.sops.secrets."valheim/discord_webhook".path})"
          server=${config.virtualisation.oci-containers.containers.valheim.environment.SERVER_NAME}

          # The wording matters more than it looks. #661 was a stale
          # code presented as usable, and this message names a code
          # too — so it has to say plainly that the code is *not*
          # expected to work. Never reuse the healthy announcement's
          # phrasing here.
          #
          # It no longer asks for a restart. #694 established these
          # arrive in multi-hour episodes in which every
          # registration fails, so the operator woken at 05:00 would
          # be hand-running a probe the host is already running on a
          # timer. Saying so is what stops the channel reading the
          # silence as "nobody is doing anything".
          payload="$(${pkgs.jq}/bin/jq -nc \
            --arg code "$code" \
            --arg server "$server" \
            --arg mins "$(( age / 60 ))" \
            --arg every "$(( ${toString joincodeRetryInterval} / 60 ))" \
            '{content: ("⚠️ Valheim server **" + $server
                        + "** registered join code **" + $code + "** " + $mins
                        + "m ago, but PlayFab never confirmed it.\n"
                        + "**That code most likely does not work** — do not share it.\n"
                        + "_These come in episodes lasting 1-3.5h in which every "
                        + "registration fails. While nobody is connected the host "
                        + "re-registers itself every " + $every + "m and will announce "
                        + "the code again when one takes, so normally there is nothing "
                        + "to do. It holds off while anyone is on rather than kicking "
                        + "them — if players are connected, restart by hand once they "
                        + "log off (#701)._")}')"

          # Same `-K -` stdin trick as the notifier: the webhook must
          # not reach the process cmdline. A failed POST leaves
          # `alerted` unset so the next tick retries, which is the
          # right direction to fail for an outage alert.
          #
          # `--max-time` is not decoration, and this is the one
          # place in the file that needs it: the announce runs
          # *before* the retry below, so a webhook that blackholes
          # rather than refuses would hang this unit with the retry
          # still unreached.
          #
          # Nothing would end that hang. `Type=oneshot` defaults to
          # `TimeoutStartUSec=infinity` — not the manager's 1min30s
          # `DefaultTimeoutStartUSec`, which is the easy thing to
          # assume; read off amos1, both this unit and
          # authentik-ldap-token-fetcher report infinity. And curl
          # bounds only the *connect* phase by default
          # (CURLOPT_CONNECTTIMEOUT 300s); CURLOPT_TIMEOUT defaults
          # to 0, "never times out during transfer", so a peer that
          # completes the handshake and then stops answering is
          # waited on forever. The timer cannot rescue it either: a
          # trigger on an already-running unit merges into the
          # existing job rather than starting a second run. So one
          # hung POST disables the whole watchdog until someone
          # intervenes — not for an episode, indefinitely.
          #
          # A host-side network fault is one of the things that
          # makes PlayFab registration fail in the first place, so
          # that correlation is real rather than theoretical. A
          # fast failure was always fine: curl exits non-zero, the
          # `else` branch logs it, and the retry below still runs.
          #
          # The notifier's two identical POSTs are unfixed (#705);
          # they sit in a follow loop, not a oneshot, so the hang
          # stalls journal routing instead.
          if printf 'url = "%s"\n' "$webhook" \
            | ${pkgs.curl}/bin/curl -fsS --max-time 15 -K - \
                -X POST -H 'Content-Type: application/json' -d "$payload"; then
            echo "announced unconfirmed join code $code (pending ''${age}s)"
            touch "$alerted"
          else
            echo "failed to post unconfirmed join code $code to discord" >&2
          fi
        fi

        # ## Re-register — repeatedly, for as long as it takes (#701)
        #
        # Everything below is independent of the block above: the
        # first tick of an episode does both, every later tick does
        # only this.

        # Two state guards before the roster one, both asking the
        # same question: can this probe possibly accomplish
        # anything? A restart that cannot is not a neutral retry,
        # it is an unwanted container bounce.
        #
        # The container must already be running. `pending` is a
        # file, so it outlives a deliberate `systemctl stop
        # podman-valheim` — and stopping the container is exactly
        # what an operator does while poking at a stuck code. The
        # roster guard does not cover this: the shutdown logs
        # `OnApplicationQuit`, which empties the roster, so a
        # stopped server looks maximally safe to restart. Without
        # this the watchdog resurrects a deliberately stopped
        # service within 15 minutes, possibly mid-image-pull.
        # `is-active` is also false while the unit is activating,
        # which costs at most one skipped tick during our own
        # restart.
        if ! "$systemctl" is-active --quiet podman-valheim.service; then
          exit 0
        fi

        # And the notifier must be running, because it is the only
        # thing that can ever clear `pending` and end the loop. If
        # it is dead or crash-looping, no confirmation will ever be
        # observed however many times the container re-registers,
        # so the loop would bounce a healthy server every 15
        # minutes indefinitely. That is the uncapped design's one
        # genuinely bad case, and it is cheap to exclude: no
        # observer, no probe.
        if ! "$systemctl" is-active --quiet valheim-joincode-notify.service; then
          exit 0
        fi

        # Roster guard. #694's argument that an episode is a
        # zero-player server by construction is a strong one — under
        # crossplay there is no connect-by-address fallback, so an
        # unresolvable code admits nobody — but it is an argument,
        # and #590 is a reminder that log lines can go missing. So
        # check, and fail towards not restarting.
        #
        # `ready` is what makes the roster answerable at all: the
        # notifier rebuilds it from scratch on every start and only
        # writes the marker afterwards, so during a rebuild the file
        # is an authoritative-looking lie (see the playerRoster
        # notes above). Missing marker, unreadable file, non-numeric
        # count and a non-zero count all land in the same `*` arm,
        # because "cannot tell" and "someone is on" call for the
        # same thing: do not bounce the server. The standing cost is
        # that a crossplay host with playerNotify = false would get
        # detection and never recovery; amos1 is the only crossplay
        # host and runs it true.
        if [ ! -e "$rosterReady" ]; then
          exit 0
        fi
        players=$("$awk" 'END { print NR }' "$roster" 2>/dev/null || true)
        case "$players" in
          0) ;;
          *) exit 0 ;;
        esac

        # "<epoch> <count>": when the last re-registration went out,
        # and how many this episode has had. Both pre-set because
        # this runs under `set -u` and a torn or empty file makes
        # `read` return non-zero having assigned nothing — the same
        # foot-gun handle_reg's `pcode` guards against.
        last=0
        count=0
        if [ -f "$retried" ]; then
          read -r last count _rest < "$retried" || true
          case "$last" in
            "" | *[!0-9]*) last=0 ;;
          esac
          case "$count" in
            "" | *[!0-9]*) count=0 ;;
          esac
        fi

        # Spacing. `last=0` means nothing has been tried yet this
        # episode, and that probes immediately rather than waiting
        # out a first full interval: detection has already cost the
        # grace window plus a tick, and the episode may have ended
        # in between.
        if [ "$last" -gt 0 ] && [ $(( now - last )) -lt ${toString joincodeRetryInterval} ]; then
          exit 0
        fi

        count=$(( count + 1 ))

        # Stamped before the restart rather than after. Nothing
        # should be able to leave this unit having bounced the
        # container without recording that it did — that is the one
        # way a 15-minute loop turns into a 60-second one.
        printf '%s %s\n' "$now" "$count" > "$retried"

        # Not a cap: the loop does not stop here. Past this many
        # attempts the episode is longer than any on record, so the
        # transient explanation is wearing thin and the journal
        # should say so in a way `journalctl -p err` can find.
        if [ "$count" -ge ${toString joincodeRetryLoudAfter} ]; then
          echo "join code $code still unconfirmed after $count re-registrations over $(( age / 60 ))m; that is longer than any observed episode, so this may be a permanent PlayFab failure rather than a transient one (#701)" >&2
        fi

        echo "re-registering join code $code: restarting podman-valheim (attempt $count, pending ''${age}s)"

        # --no-block so this oneshot returns at once. A blocking
        # restart holds the unit open for the container's stop —
        # 8-9s measured on amos1, but bounded only by podman's own
        # stop timeout, and `Type=oneshot` means this unit has no
        # start timeout to fall back on (`TimeoutStartUSec=infinity`
        # on amos1, not the manager's 1min30s default). So a stop
        # that wedged would wedge the watchdog with it, and the
        # timer could not start a second run. The exit status is
        # worth nothing here anyway: whether the re-registration
        # took is decided by the `is active` line the notifier
        # watches, not by whether the unit started.
        "$systemctl" restart --no-block podman-valheim.service
      '';
    };
  };

  systemd.timers = {
    # Crossplay-only, like the unit it drives: a Steam-backend
    # server has no join code and nothing to confirm (#683).
    #
    # 1m rather than the exporter's 2m. Total detection latency is
    # the grace window plus one tick, so this puts the Discord
    # message inside ~3m of a failed confirmation against a ~99s
    # protocol worst case. Every tick but the broken one is two stat
    # calls and an exit.
    #
    # OnBootSec deliberately past the grace window: at boot nothing
    # has registered yet, so earlier ticks would only exit immediately.
    valheim-joincode-watchdog = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3m";
        OnUnitActiveSec = "1m";
        Unit = "valheim-joincode-watchdog.service";
      };
    };
  };
}
