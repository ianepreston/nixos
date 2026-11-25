#!/usr/bin/env bash

# Values are set by the Nix service wrapper (or the offline test); single
# quoted jq and awk programs deliberately contain their own dollar variables.
# shellcheck disable=SC2016,SC2154
set -uo pipefail

: >"$roster"

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
  #
  # `--max-time` covers what a non-zero exit does not: a peer
  # that completes the handshake and then stops answering,
  # which curl waits on forever by default (CURLOPT_TIMEOUT
  # 0, "never times out during transfer"). This runs inside
  # the follow loop, so a hang freezes the roster — and the
  # roster is what `valheim_players_online` and the join-code
  # watchdog's "is anyone connected?" guard both read. A
  # frozen non-empty roster blocks recovery; a frozen empty
  # one permits a container restart with players on. Bare,
  # not `--retry` — see the note on `notify` in
  # joincode.nix. (#705)
  if printf 'url = "%s"\n' "$webhook" |
    "$curl" -fsS --max-time 15 -K - \
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
  printf '%s\t%s\n' "$prefix" "$name" >>"$roster"
  [ "$quiet" = 1 ] && return 0
  post "**$name** joined **$server** — $(online) online"
}

leave() {
  prefix="$1"
  name="$(roster_name "$prefix")"
  # Absent: a duplicate leave, or a prefix never on the roster.
  [ -n "$name" ] || return 0
  "$awk" -F'\t' -v p="$prefix" '$1 != p' "$roster" >"$roster.tmp" &&
    mv "$roster.tmp" "$roster"
  [ "$quiet" = 1 ] && return 0
  post "**$name** left **$server** — $(online) online"
}

# Normalise the journal to tab-separated events, so the
# dispatcher below is the same code for the replay and the
# live follow. J=spawn, L=departure, R=server lifecycle,
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
# `valheim-joincode-notify` dodges this with `sed -u`
# — the same flag on the same tool. (It used
# `grep --line-buffered` when this comment was written; #661
# moved it to sed and this cross-reference went stale.) Cost
# is nil — journalctl's --grep means sed only ever sees the
# handful of matching lines, not the raw journal.
normalize() {
  "$sed" -u -nE \
    -e 's/.*Got character ZDOID from (.+) : (-?[0-9]+):[0-9]+[[:space:]]*$/J\t\2\t\1/p' \
    -e 's/.*Destroying abandoned non persistent zdo -?[0-9]+:[0-9]+ owner (-?[0-9]+)[[:space:]]*$/L\t\1/p' \
    -e 's/.*\[Disconnect\] peer=.* uid=(-?[0-9]+)([[:space:]].*)?$/L\t\1/p' \
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
      R) : >"$roster" ;;
      C) printf '%s\n' "$a" >"$cursorfile" ;;
    esac
  done
}

# --grep so the match happens inside journalctl instead of
# dragging this boot's entire journal (tens of millions of
# lines after a GetPublicIP wedge — see README.md)
# through a pipe on every restart. stderr is deliberately not
# suppressed: if --grep ever fails, this unit silently
# announcing nothing forever is the worst outcome.
pattern='Got character ZDOID from|Destroying abandoned non persistent zdo|\[Disconnect\] peer=|New session server |Game - OnApplicationQuit'

# Replay and position in a single pass. --show-cursor reports
# the cursor of the last entry this pass actually consumed, so
# the follow resumes exactly there: no entry is seen twice,
# and none falls into a gap between the two passes. (The
# join-code unit reads its cursor separately and
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
: >"$ready"

quiet=0

if [ -s "$cursorfile" ]; then
  set -- -f --after-cursor="$(cat "$cursorfile")"
else
  # Nothing matched this boot, so there is no cursor to anchor
  # to: follow from now and take only new entries.
  set -- -b -f --lines=0
fi

"$journalctl" -u podman-valheim.service "$@" -o cat --grep="$pattern" |
  normalize | dispatch
