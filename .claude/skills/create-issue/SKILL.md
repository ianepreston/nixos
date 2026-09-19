---
name: create-issue
description: File a GitHub issue in ianepreston/nixos the way this repo's issues are written — gather and quantify evidence off the live host, locate the mechanism in the repo, rule out alternatives, then fill the matching .github/ISSUE_TEMPLATE. Use when asked to file/open/write up an issue, log a bug, capture an investigation, or turn something just observed into an issue ("file an issue for this", "open a bug about the pactl spam", "/create-issue").
---

# Create an issue

The issues in this repo are long, quantified, and structured, because the
session that implements them is starting cold. An issue that says "X is broken,
we should fix it" costs that session a re-investigation you already did.

Do not open the editor first. Evidence, then triage, then template.

## 1. Frame the observation

From the user's ask (or from what this session just found), establish:

- **What was observed** — the symptom, not yet the diagnosis.
- **Which host.** `hpp-1` (dev server), `amos1` (prod server), `terra`/`luna`
  (workstations), `behemoth` (pfSense), `laconia` (NAS). Everything downstream
  depends on this.
- **Whether it is already filed.** `gh issue list --search "<keywords>"
  --state all`. Check closed issues too — a reopened or referenced issue beats
  a duplicate, and a closed one often carries the taxonomy you're about to
  rebuild.

If the ask is vague ("the valheim thing is flaky"), gather evidence first and
come back with what you found rather than asking the user to specify.

## 2. Gather evidence, quantified

An unquantified claim is the single most common gap. "Steam spams pactl errors"
is not the issue; **"313 occurrences in the last 7 days, and it fires
repeatedly for as long as Steam is up, not once at startup"** is (#650).

Reaching a server host needs the ssh master socket — auth uses a FIDO2 key and
no tty here can answer its prompt:

```sh
ssh -O check -o ControlPath="$HOME/.ssh/master-ipreston@<host>:22" ipreston@<host>
```

If that fails, ask the user to open one (`! ssh <host>`) before going further.

**Journal.** Bound the window, count, then excerpt:

```sh
ssh <host> 'journalctl -u <unit> --since "7 days ago" | grep -c "<pattern>"'
ssh <host> 'journalctl -u <unit> --since "2026-09-18 16:40" --until "2026-09-18 17:00" -o short-iso'
```

**History older than the journal** lives in VictoriaLogs (`127.0.0.1:9428`),
which is what makes "has this happened before?" answerable — it turned a one-off
Valheim freeze into a 12-occurrence pattern in #627.

**Metrics** are VictoriaMetrics (`127.0.0.1:8428`, **15 day retention**), also
loopback-only. Two traps, each worth a wasted round otherwise:

- `ssh host -- curl ... 'promql'` does not work. ssh joins argv into one string
  and the remote zsh re-parses it, so `(`, `{mode="idle"}` and `[2m]` get
  glob/brace-expanded. Pipe a script instead: `ssh host bash -s < script.sh`,
  PromQL single-quoted inside and passed via `--data-urlencode "query=$q"`.
- The server hosts have **no `python3`**. Fetch raw JSON over ssh, parse
  locally.

Where several symptoms co-occur, **establish the ordering** and say what it
rules out. #662's whole analysis turns on the relay error at 16:50:41 preceding
every DNS failure — so DNS was an amplifier, not the trigger. Getting this
backwards sends the implementing session after the wrong thing.

## 3. Locate the mechanism

Find the code, cite it as `modules/<path>.nix:<line>`, and read it. An issue
that names the file has already done a third of the implementation.

**Verify any constant you are about to reason from.** Do not quote a comment.
#649 sized its fix against a 90s budget taken from an in-repo comment; reading
moonshine 0.16.1's source at PR time showed the binding cap was 60s, which
changed the numbers. If a timeout, retention, threshold or limit is
load-bearing, read the source that defines it and cite what you read.

**Enumerate the cascade.** If the fix replaces a mechanism, list what else
names it — buffering flags, helper vars, doc comments, runbooks, a Taskfile
description. #661 anticipated the field-offset change but not `grep
--line-buffered` → `sed -u`, the orphaned gnugrep helper, or a comment making a
false claim about journalctl's exit codes. Those all landed in the PR as
surprises.

## 4. Triage the type

| Evidence looks like | Type | Template |
| --- | --- | --- |
| Something behaves wrongly and you can point at the mechanism | defect | `.github/ISSUE_TEMPLATE/bug.md` |
| Nothing is broken; you want behaviour that doesn't exist | enhancement | `.github/ISSUE_TEMPLATE/enhancement.md` |
| You have evidence but no diagnosis, or the fix isn't the next step | investigation | `.github/ISSUE_TEMPLATE/investigation.md` |

Then read the matching reference for how to fill it:
`references/defect.md`, `references/enhancement.md`, `references/investigation.md`.

Judgement calls:

- **Diagnosed but not worth fixing yet** → investigation. Closing "explained,
  not a defect" is a real outcome (#662), and the write-up still gets cited.
- **Hybrid** — a defect report that also carries enhancement asks — is a blank
  issue with a `## What happened` section and numbered `## Ask N` sections, one
  per separable piece of work (#643). Don't force it into one template.
- **Found while working on something else** → file separately and cross-link,
  unless the fixes are the same edit. #650 was found diagnosing #649 and split
  out; both PRs stayed scoped. Say in the Summary where it came from.
- **Several independent changes** → several issues. One issue, one PR.

## 5. Rules that apply to every type

These are earned from PRs that had to discover them; each is cheap to write and
expensive to miss.

1. **Quantify.** Occurrences over a stated window, on a named host.
2. **Verify constants against source**, never from a comment (#649).
3. **State retention and scrape interval** for anything querying metrics, and
   confirm your window fits. #636 proposed comparing against two weeks ago; at
   15d retention `offset 14d` silently evaluates to nothing — the same silent
   no-op the issue was about.
4. **Name the unverifiable.** Which checks need a human, a game client, a
   phone, physical access. #644 marked "a LAN Steam client can actually join"
   as *the load-bearing unknown*; it was still the one open item at PR time,
   and nobody was surprised.
5. **List what must not change**, and how that will be proven. A closure diff
   against `origin/main` beats a smoke test — that is how #647 established
   amos1 was untouched, and how it found that emitting `BEPINEX="false"`
   instead of omitting it would bounce the container and rotate the join code
   out from under every player.
6. **Ruled-out list.** What this is not, each with its eliminating observation,
   including coincidences (#662's upsmon flap inside the window).
7. **Write down what you checked and found fine**, so implementation doesn't
   re-derive it — secrets, preservation, recovery tasks, alert rules (#644's
   "No change needed (verified, listing so it isn't re-derived)").
8. **Package additions** bring more than a binary. Say what units or PATH
   entries come with it and why they're inert (#651: `pulseaudio.socket` lands
   on pipewire-pulse's socket path and is harmless only because upstream ships
   `Conflicts=`).

## 6. File it

Title: `<area>: <the fault or outcome>`, where area is the module or subsystem
(`valheim`, `observability`, `audio`, `nut`, `renovate`). State the fault, not
the symptom — `pactl is missing under pipewire-pulse` rather than `Steam logs
errors`.

Draft the body to a scratchpad file and file from it, so a long body survives
quoting intact:

```sh
gh issue create --title "<title>" --label bug --body-file <scratchpad>/issue.md
```

Labels: `bug`, `enhancement`, or none for investigations and hybrids (matching
what the repo already does). Add `blocked` only if it genuinely is.

Show the user the body before filing if it took real investigation to produce —
they are the one who has to live with the framing. File without asking when it
is a straightforward write-up of something you both just watched happen.

Afterwards, report the issue URL and anything you could not determine — the
gaps are as useful as the findings, because they tell the implementing session
where to start.
