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
- `task deploy:hpp-1` (or `scripts/activate-nixos.sh --host hpp-1 --dest
  hpp-1 ...`) against **hpp-1** (dev) — never raw `nixos-rebuild`; see
  "Deploying to a host" below. This authorization names hpp-1 only; it never
  extends to a build host or another machine reached through SSH option reuse.

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

The master check is necessary for single-host activation and only confirms
that a socket is listening. Run `task ssh:preflight HOST=<host>` to also
check the effective agent, Nix store transport, builders, and target hostname.
For a deploy with custom SSH options or a separate build host, run
`scripts/activate-nixos.sh --preflight` with the same arguments as the deploy.
If a probe reports that a touch or PIN is needed, stop and report the operator
action.

If there is no master, ask the user to open one (`! ssh <host>` in the session,
or their own terminal). Do this at the start of a task, not at the point of
use: discovering it after a 20-minute build wastes the build.

## Reading state off a host

Bound the window, count, then excerpt:

```sh
ssh <host> 'journalctl -u <unit> --since "7 days ago" | grep -c "<pattern>"'
ssh <host> 'journalctl -u <unit> --since "2026-09-18 16:40" --until "2026-09-18 17:00" -o short-iso'
```

Both server hosts run **VictoriaMetrics** on `127.0.0.1:8428` (**45 day
retention** — `retentionPeriod` in `modules/system/victoriametrics.nix`) and
**VictoriaLogs** on `127.0.0.1:9428` (**30 day retention** — the
`-retentionPeriod` extra option in `modules/system/victorialogs.nix`) —
loopback only, so the query has to run *on* the host. VictoriaLogs is the only
log history that outlives journald's ~4G cap, so it is what makes "has this
happened before?" answerable.

Take those two numbers from the modules, not from here, before resting an
argument on a window: this file said 15 days for both until 2026-09-20, which
understated what is actually answerable.

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

Use the repo helper, `scripts/activate-nixos.sh` (what `task deploy:<host>`,
`task rebuild[:<host>]` and `task bootstrap:rebuild` all call). Its bounded,
read-only preflight runs before building, including for `--action check` and
`bootstrap:rebuild`. It then builds, copies when needed, and activates through
**one** connection that runs
`scripts/_activate-nixos/activate.sh` as root. Before anything is copied, and
again on the target in the same process as `switch-to-configuration`, it
requires:

- the closure path to be exactly
  `/nix/store/<32-char hash>-nixos-system-<host>-<version>` (so
  `…-custom-nixos-system-hpp-1-…` and `…-nixos-system-hpp-1-lab-…` fail);
- the closure's own `etc/hostname` to equal `<host>` exactly — the real guard,
  since a hyphenated host makes the name alone ambiguous;
- on the target, `hostname` to equal `<host>`.

The target script prints two nonce-bearing sentinel lines; unless both come
back, the run fails even if ssh exited 0 (so an ssh that never fed it the script
cannot pass as success). The activation's own stdin is `/dev/null` and its
stdout goes to stderr, so it can neither swallow the script nor fuse its output
with a sentinel. No retries, no fallback host. The target `hostname` is checked
again after the copy (copy only needs the connection; the check runs in the same
process as the switch). `task bootstrap:rebuild` always switches; use
`scripts/activate-nixos.sh --remote-flake src/nixos --action check|test|boot`
directly for another action.

```sh
# from any checkout or worktree; nix-secrets comes from flake.lock by default.
# Add --local-secrets only for unpublished secrets work: it finds the sibling
# checkout portably (of the main checkout when run from a worktree;
# $NIX_SECRETS_PATH wins)
scripts/activate-nixos.sh --host hpp-1 --dest hpp-1 --dry-run  # eval + print plan only
scripts/activate-nixos.sh --host hpp-1 --dest hpp-1 --preflight  # transport and identity probes only
scripts/activate-nixos.sh --host hpp-1 --dest hpp-1 --action check  # preflight, build, assert identity
scripts/activate-nixos.sh --host hpp-1 --dest hpp-1            # switch
```

Use `--skip-preflight` to bypass the probes explicitly. With
`--local-secrets`, the preflight compares the checkout's HEAD with the
locked revision and reports uncommitted changes. A builder failure stops
the run before the build.

`task deploy:hpp-1` is the same thing (`LOCAL_SECRETS=true task deploy:hpp-1`
adds `--local-secrets`); `ACTION=check|test|boot` selects the action. Task passes host and action as explicit `shellQuote`d arguments, never
`env:` (an inherited `ACTIVATE_HOST` would override it), and the helper
validates host, action, user, port and destination.

SSH options are per host and explicit. The helper discards an inherited
`NIX_SSHOPTS`; a separate `--build-host` gets only `--build-ssh-opt`s while the
target gets only `--target-ssh-opt`s (the closure is pulled from the build host,
then pushed to the target, as two single-host commands). With a build host,
every connection to either host (including the `nix copy` transports) is forced
to `-oControlMaster=no -oControlPath=none -oProxyJump=none -oProxyCommand=none`,
ahead of any option you pass, so no socket can be shared whatever
`~/.ssh/config` says. Consequently, in split-host mode every leg authenticates afresh (ssh-ng opens
a Nix-owned master per copy), so a hardware key needs a touch per leg.
Single-host mode instead reuses your pre-opened master: the closure is copied
over the legacy `ssh://` store (one plain `ssh` per command, picking up the
`ControlPath` from `~/.ssh/config`) with only `-oControlMaster=no` added, never
`ControlPath=none`. `ssh-ng://` is not used there because it always starts its
own ssh master on a private socket, so it can never use the pre-opened one and
would demand a fresh authentication (a failed touch shows as `failed to start
SSH master connection`). A jump host is a separate ssh client that never sees those
options, so with `--build-host` an explicit `-J`/`-oProxyJump` is rejected and
any jump or proxy from `~/.ssh/config` is disabled; single-host mode still
accepts `-J`/`-oProxyJump`. Every target ssh also passes `-T`, so a
`RequestTTY force` in client config cannot merge stderr into the activation
transcript (`-t`/`-tt`/`RequestTTY` are not allowlisted).

Each `--*-ssh-opt` is one whitespace-free token from an allowlist of connection
settings: `-oKey=value` for `ForwardAgent`, `ControlPath`, `ControlMaster`,
`ControlPersist`, `IdentityFile`, `ProxyJump` and similar, plus `-iFILE`,
`-JJUMP`, `-4`, `-6`, `-A`, `-C`, `-q`, `-v`. Anything that changes what runs,
where stdin goes, or which config/socket is used (`-n`, `-N`, `-f`, `-W`, `-O`,
`-S`, `-F`, `-l`, `RemoteCommand`, `ProxyCommand`, `User`, …) is rejected. Use
`--port` and `--user` rather than `-p`/`-l`. The helper opens plain `ssh`
connections, so (single-host only) an existing master from `~/.ssh/config` is
reused for both the closure copy and the activation ssh; to pin one
explicitly pass `--target-ssh-opt=-oControlPath=$HOME/.ssh/master-ipreston@<host>:22
--target-ssh-opt=-oControlMaster=no`.

`system.autoUpgrade` is the one accepted exception: it activates without the
helper, but it only ever activates the local host from `main`, so there is no
remote target and no cross-host identity risk.

Do not call `nixos-rebuild --target-host` or `switch-to-configuration` by hand:
that bypasses the assertions (a test fails if any Taskfile does).

The failure mode is misleading if you skip the master check — the closure copy
shows a live `ESTAB` socket and transfers ~0 bytes. Confirm from the target:

```sh
ssh <host> 'ps -eo pid,etime,args | grep -E "[s]shd-session|[n]ix-store --serve"'
```

A stuck session sits in `[priv]` (pre-auth) with no `nix-store --serve`.

If an activation errors or the target stops answering, stop and report. Do not
retry or re-run the activation: first establish which host received the command
and what state it is in.

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

### Creating commits with a suppressed global config

Usually a plain `git commit` needs no identity flags: the flake installs the
correct public Git identity in `~/.gitconfig`. If a command must create a
commit with `GIT_CONFIG_GLOBAL=/dev/null`, capture that identity *before*
suppressing the global config and pass it to `git commit`:

```sh
git_user_name="$(git config user.name)"
git_user_email="$(git config user.email)"

GIT_CONFIG_GLOBAL=/dev/null \
  git -c user.name="$git_user_name" -c user.email="$git_user_email" commit -m "<message>"
```

Do not add identity flags to `git push`: it transmits commits already created
and does not use them. A remote rejection saying `push declined due to email
privacy restrictions` means the commit's identity was wrong; amend or recreate
the commit with the configured identity before pushing.

Push — suppress the global config and let `gh` answer the credential prompt, so
no token ever lands in argv:

```sh
GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
  git -c credential.helper='!gh auth git-credential' \
      push https://github.com/ianepreston/nixos HEAD:refs/heads/<branch>
```

Afterwards the local tracking ref is still missing — nothing was fetched — so
the push looks absent to git. Check the remote, not `git branch -vv`:

```sh
gh api repos/ianepreston/nixos/branches/<branch> --jq .commit.sha
```

`gh` itself is unaffected throughout (keyring token, `repo` scope), so
`gh issue`, `gh pr` and `gh api` always work.
