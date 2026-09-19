# Reaching hosts and repos from an agent session

Shared by the skills in this directory. Read this before running anything
against a host or against `origin` — nearly every command here has a plausible
form that hangs forever instead of failing.

Not a skill (no `SKILL.md`); it is a reference other skills point at, so these
facts have one home.

## The fleet

| Host | Role |
| --- | --- |
| `hpp-1` | **dev** server — `serverEnvironment = dev`, `dnix.ipreston.net`. Validate server-side changes here first. |
| `amos1` | **prod** server — the user-facing homelab. |
| `terra`, `luna` | workstations (one of them is usually the machine this session runs on). |
| `behemoth` | pfSense router. Out-of-band; not a NixOS host. |
| `laconia` | Synology NAS. `ssh laconia` needs `-o RemoteCommand=none`. |
| `tests-server`, `tests-desktop` | quickemu VM targets (`taskfiles/vm.yaml`). |

`hostSpecs/<host>.nix` is the authority if this table and the repo disagree.

## What needs asking first

Free, no confirmation:

- Read-only inspection of any host, prod included — `systemctl status`,
  `journalctl`, `ss`, reading config and metrics.
- `task check`, `task build:<host>`, `nix build` of a host closure.
- `nixos-rebuild switch` against **hpp-1** (dev).

Ask the user first, every time:

- Anything that mutates **amos1** or any other live host — a switch, a service
  restart, touching `/var/lib/<app>`, a database.
- `task rebuild` / `build_home` — this workstation's own configuration.
- `task secrets:*` and `task secrets:publish` (it pushes to `../nix-secrets`).
- Destructive host-side commands, on hpp-1 too.
- `task deploy` of anything touching `modules/hosts/_<host>-disks.nix` — that
  one is never allowed. Disko changes need `bootstrap:reinstall`, which is the
  user's to run.

## The ssh master socket

Auth uses a FIDO2 key needing a touch or PIN, and nothing in an agent session
can answer that prompt. Check before you need it:

```sh
ssh -O check -o ControlPath="$HOME/.ssh/master-ipreston@<host>:22" ipreston@<host>
```

Plain `ssh <host>` succeeding proves nothing — it silently reuses
`~/.ssh/master-%r@%n:%p` (`ControlPersist yes`) and never re-authenticates. Any
command that opens its *own* connection will hang.

If there is no master, ask the user to open one (`! ssh <host>` in the session,
or their own terminal). Do this at the start of a task, not at the point of
use: discovering it after a 20-minute build wastes the build.

## Reading state off a host

Bound the window, count, then excerpt:

```sh
ssh <host> 'journalctl -u <unit> --since "7 days ago" | grep -c "<pattern>"'
ssh <host> 'journalctl -u <unit> --since "2026-09-18 16:40" --until "2026-09-18 17:00" -o short-iso'
```

Both server hosts run **VictoriaMetrics** on `127.0.0.1:8428` (**15 day
retention**) and **VictoriaLogs** on `127.0.0.1:9428` — loopback only, so the
query has to run *on* the host. VictoriaLogs is the only log history that
outlives journald's ~4G cap, so it is what makes "has this happened before?"
answerable.

Two traps, each worth a wasted round:

1. **`ssh host -- curl ... 'promql'` does not work.** ssh joins argv into one
   string and the remote zsh re-parses it, so `(`, `{mode="idle"}` and `[2m]`
   get glob/brace-expanded — you get `zsh: no matches found` instead of JSON.
   Pipe a script: `ssh host bash -s < script.sh`, PromQL single-quoted inside
   and passed via `--data-urlencode "query=$q"`.
2. **No `python3` on the server hosts.** Fetch raw JSON over ssh, parse locally.

LogSQL: `_time:30d "some phrase"` works, but adding
`_stream:{_SYSTEMD_UNIT="foo.service"}` silently returns nothing — filter on the
phrase instead. `/select/logsql/query` returns NDJSON with `_msg` before
`_time`, and `_msg` truncates at the first escaped quote, so grep both fields
and re-pair them. Timestamps are UTC; convert before comparing against a
local-time incident window.

## Deploying to a host

Use `nixos-rebuild` directly, not `task deploy:<host>`. `nixos-rebuild-ng`
appends its own `-o ControlMaster=auto -o ControlPath=<fresh tmpdir>/ssh-%C`
(`SSH_DEFAULT_OPTS` in `nixos_rebuild/process.py`), so it can never reuse the
master and must authenticate fresh — which hangs with no tty. User opts from
`NIX_SSHOPTS` are placed *before* those defaults and ssh takes the first value
for each option, so pointing it at the existing master wins:

```sh
NIX_SSHOPTS="-o ControlPath=$HOME/.ssh/master-ipreston@<host>:22 -o ControlMaster=no" \
  nixos-rebuild switch --flake .#<host> --target-host ipreston@<host> --sudo \
    --override-input nix-secrets path:/home/ipreston/src/nix-secrets
```

The `--override-input` must be absolute: `task deploy` hardcodes
`path:../nix-secrets`, which resolves to nothing from a worktree under
`.claude/worktrees/`.

The failure mode is misleading if you skip the master check — the closure copy
shows a live `ESTAB` socket and transfers ~0 bytes. Confirm from the target:

```sh
ssh <host> 'ps -eo pid,etime,args | grep -E "[s]shd-session|[n]ix-store --serve"'
```

A stuck session sits in `[priv]` (pre-auth) with no `nix-store --serve`.

Don't pipe a deploy into `tail`/`head` — it hides the exit status and a failed
deploy reads as success. Check `PIPESTATUS`, or don't pipe.

## Git against origin

`git push`, `git fetch` and `git ls-remote` over ssh all hang — same FIDO2
cause. Pushing the HTTPS URL does not dodge it: a global
`url.git@github.com:ianepreston/.insteadof https://github.com/ianepreston/`
rewrite sends it straight back to ssh. Do **not** try to cancel that with
`-c url.<base>.insteadof=<junk>`; `insteadOf` is multi-valued, so `-c` appends
and the global rule still fires.

Fetch (anonymous read works over https):

```sh
GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
  git fetch https://github.com/ianepreston/nixos +refs/heads/main:refs/remotes/origin/main
```

Push — suppress the global config and let `gh` answer the credential prompt, so
no token ever lands in argv:

```sh
GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
  git -c credential.helper='!gh auth git-credential' \
      -c user.name="Ian Preston" -c user.email="ian.e.preston@gmail.com" \
      push https://github.com/ianepreston/nixos HEAD:refs/heads/<branch>
```

Afterwards the local tracking ref is still missing — nothing was fetched — so
the push looks absent to git. Check the remote, not `git branch -vv`:

```sh
gh api repos/ianepreston/nixos/branches/<branch> --jq .commit.sha
```

`gh` itself is unaffected throughout (keyring token, `repo` scope), so
`gh issue`, `gh pr` and `gh api` always work.
