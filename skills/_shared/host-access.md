# Reaching hosts and repos from an agent session

Shared by the skills in this directory. Read this before running commands
against a host or `origin`.

## The fleet

| Host | Role |
| --- | --- |
| `hpp-1` | **dev** server — `serverEnvironment = dev`, `dnix.ipreston.net`. Validate server-side changes here first. |
| `amos1` | **prod** server — the user-facing homelab. |
| `terra`, `luna` | workstations. |
| `behemoth` | pfSense router. Out-of-band; not a NixOS host. |
| `laconia` | Synology NAS. `ssh laconia` needs `-o RemoteCommand=none`. |
| `tests-server`, `tests-desktop` | quickemu VM targets (`taskfiles/vm.yaml`). |

`hostSpecs/<host>.nix` is the authority if this table and the repo disagree.

## Authorization

Read-only host inspection, including on production, and local checks and host
builds need no confirmation. Follow the host-specific activation authorization
in [AGENTS.md](../../AGENTS.md). When dev validation requires activation, use
`hpp-1` once the user has authorized that host and action. Authorization for
one host or action never extends to another. A missing reply is never approval.

Ask first for other live mutations (including restarts or changes to app data),
workstation rebuilds, `build_home`, and `task secrets:*` (including publication).
Disko changes require the operator's documented reinstall workflow.

## Host access preflight

Identify the host, operation, and connection options each live step needs.
Check access before starting that step or a build that depends on it. Read-only
SSH needs a route to the effective host and port, a trusted host key, and usable
authentication. That can be an existing authenticated connection or credentials
that work in this runner. Some fleet identities use FIDO2 keys that require
a touch or PIN. A runner can use those when it has an interactive terminal
and someone can supply the requested input.

The examples use OpenSSH and GNU coreutils `timeout` on Linux and macOS
(`gtimeout` is the command used by some macOS installations). The repo's
transport helper specifically requires `timeout` on its PATH. Use a
wall-clock deadline for the whole unattended probe, including any proxy or key
provider. `ConnectTimeout` only covers connection establishment.

### Read-only SSH

Use the intended SSH alias or destination and the same user, port and
connection options as the planned operation. For example:

```sh
target=hpp-1
timeout -k 1s 5s ssh -G "$target" </dev/null
timeout -k 1s 5s ssh -o BatchMode=yes -O check "$target" </dev/null
```

Inspect the effective hostname, user, port, jump/proxy, identity/agent, and
`ControlPath` locally. The second command checks for a listening master on
that socket. Confirm the socket belongs to the intended destination before
using it. A missing master only blocks tools that require one. A listening
master still needs a remote probe to establish reachability and identity:

```sh
timeout -k 1s 15s env SSH_ASKPASS_REQUIRE=never \
  ssh -nT -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=yes \
    -o UpdateHostKeys=no -o AddKeysToAgent=no -o ClearAllForwardings=yes \
    -o PermitLocalCommand=no -o ForkAfterAuthentication=no -o ControlMaster=no \
    -o RemoteCommand=none "$target" hostname
```

For a NixOS host, require the returned name to match the intended host. The
probe can reuse the expected master or connect without one. For unattended
reads, carry forward the verified connection settings and use a deadline
appropriate to the query. Keep stdin available for commands that read a script.

### Deployment and operator handoff

Run `task ssh:preflight HOST=<host>` for the standard single-host deployment.
For custom options, a separate builder, or a local input override, run
`scripts/activate-nixos.sh --preflight` with the same target, SSH, build and
input options as the planned operation. The helper checks the effective
agent, Nix store transport, configured builders and target hostname with
bounded probes. A standard single-host deploy requires a usable master.
Bootstrap rebuild probes can continue in BatchMode after a missing-master
warning. Split-host deployments use fresh authentication for the separate
connections. Keep target and builder SSH options separate as described below.

Use the probe's result to identify what is missing (for example network access,
host trust, an effective agent, a usable master or interactive authentication).
If operator input is needed, use an interactive terminal with the same
connection settings. For a required master, use `ssh -M -N "$target"` with a
configured host-specific `ControlPath` (or supply that path explicitly with
`-S`), complete any touch or PIN prompt, and keep the connection available.
Recheck it from the runner, which must be able to access the same socket.
For fresh authentication, verify it from that terminal and run the dependent
step there if the unattended runner still cannot authenticate.

When access is unavailable, report the unmet prerequisite and the exact
operator step or check to run from a capable environment. Defer the dependent
live steps and continue independent work. Record those validations as
deferred until they run and produce evidence. A passing access probe confirms
transport prerequisites. Record build and behavioral results when those
checks run.

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
the helper directly with the synced `--remote-flake` path and
`--action check|test|boot` for another action.

```sh
# from any checkout or worktree; nix-secrets comes from flake.lock by default.
# For unpublished secrets work, --local-secrets uses NIX_SECRETS_PATH if set.
# Otherwise the helper looks beside the current checkout, then beside the
# primary checkout when run from a linked worktree.
scripts/activate-nixos.sh --host hpp-1 --dest hpp-1 --dry-run  # eval + print plan only
scripts/activate-nixos.sh --host hpp-1 --dest hpp-1 --preflight  # transport and identity probes only
scripts/activate-nixos.sh --host hpp-1 --dest hpp-1 --action check  # preflight, build, assert identity
scripts/activate-nixos.sh --host hpp-1 --dest hpp-1            # switch
```

Use `--skip-preflight` on the helper or `SKIP_PREFLIGHT=true` with deploy,
rebuild, or bootstrap rebuild tasks to bypass the probes explicitly. With
`--local-secrets`, the preflight compares the checkout's HEAD with the
locked revision and reports uncommitted changes. A builder failure stops
the run before the build. Record an explicit bypass as skipped preflight.

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
ahead of any option you pass, regardless of the effective SSH configuration.
In split-host mode every leg authenticates afresh (ssh-ng opens
a Nix-owned master per copy), so a hardware key needs a touch per leg.
Single-host mode instead reuses your pre-opened master: the closure is copied
over the legacy `ssh://` store (one plain `ssh` per command, picking up the
effective `ControlPath`) with only `-oControlMaster=no` added, never
`ControlPath=none`. `ssh-ng://` is not used there because it always starts its
own ssh master on a private socket, so it can never use the pre-opened one and
would demand a fresh authentication (a failed touch shows as `failed to start
SSH master connection`). A jump host is a separate ssh client that never sees those
options, so with `--build-host` an explicit `-J`/`-oProxyJump` is rejected and
configuration-supplied jumps and proxies are disabled. Single-host mode
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
connections, so (single-host only) an existing master from the effective SSH
configuration is reused for both the closure copy and activation. To pin the
verified socket, pass `--target-ssh-opt="-oControlPath=$control_path"` and
`--target-ssh-opt=-oControlMaster=no`, where `control_path` is the absolute
path for that destination. Do not share that option across hosts.

`system.autoUpgrade` is the one accepted exception: it activates without the
helper, but it only ever activates the local host from `main`, so there is no
remote target and no cross-host identity risk.

Do not call `nixos-rebuild --target-host` or `switch-to-configuration` by hand:
that bypasses the assertions (a test fails if any Taskfile does).

A closure copy waiting on authentication can show a live `ESTAB` socket
and transfer ~0 bytes. During read-only diagnosis from a verified connection,
inspect the target:

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

Inspect the effective fetch and push URLs with `git remote get-url origin`
and `git remote get-url --push origin`. Check `gh auth status --hostname
github.com` before relying on the GitHub CLI or its credential helper. Use the
configured remote when its transport and credentials work. For an unattended
read probe, use a wall-clock deadline and disable prompting. For example, with
an effective HTTPS remote:

```sh
timeout -k 1s 15s env GIT_TERMINAL_PROMPT=0 git ls-remote origin HEAD </dev/null
```

For SSH, use BatchMode with the remote's effective SSH settings or use an
operator terminal if authentication needs a touch or PIN. A read probe can
establish fetch access. Confirm publication after a push using the remote SHA.

If SSH is unavailable, try a command-scoped HTTPS URL
(`https://github.com/ianepreston/nixos.git`). Fetch can use anonymous HTTPS.
For push, use an authenticated HTTPS credential helper. For example, with a
working GitHub CLI login and `branch` set to the task branch:

```sh
https_url=https://github.com/ianepreston/nixos.git
GIT_TERMINAL_PROMPT=0 git fetch "$https_url" refs/heads/main:refs/remotes/origin/main
GIT_TERMINAL_PROMPT=0 git -c credential.helper= -c credential.helper='!gh auth git-credential' \
  push "$https_url" "HEAD:refs/heads/$branch"
```

Keep tokens out of URLs and command arguments.

Check URL rewrites if the HTTPS URL still selects SSH. Use
`git ls-remote --get-url <https-url>` for fetch and inspect any
`url.*.pushInsteadOf` rules for push. If the relevant rewrite comes from
global config and HTTPS is authorized, set `GIT_CONFIG_GLOBAL=/dev/null` on
that individual fetch or push only, then verify the effective URL under that
setting. Carry forward any settings the operation needs, including the
effective `core.hooksPath` for a push if it would otherwise change. Read it
with `git config --get core.hooksPath` before suppression and pass it as
`git -c core.hooksPath="$hooks_path" …` when set. Keep local and system
configuration in effect. If a rewrite still applies or the required hook or
credential settings cannot be preserved, use a capable operator terminal.

Commit normally with the configured identity and installed hooks. A failed
push citing email privacy needs a commit created with the configured public
identity. Changing push flags cannot change the author already in the commit.

Verify the remote SHA even if no local tracking ref was updated:

```sh
gh api repos/ianepreston/nixos/branches/<branch> --jq .commit.sha
```
