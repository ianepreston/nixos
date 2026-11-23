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

The **Authorization** section of [AGENTS.md](../../AGENTS.md) decides what
needs approval, including the `hpp-1` exception for `resolve-issue` and
`add-app` invocations. This file adds no rules and grants nothing beyond it.
Dev activation targets `hpp-1`; the fleet table above says which hosts are
production or workstations. For a disko change on a live host, the operator
runs `task bootstrap:reinstall` themselves, following the
[documented reinstall workflow](../../docs/agents/testing-and-bootstrap.md).

## Host access preflight

Identify the host, operation, and connection options each live step needs.
Check access before starting that step or a build that depends on it. Read-only
SSH needs a route to the effective host and port, a trusted host key, and usable
authentication. That can be an existing authenticated connection or credentials
that work in this runner. Some fleet identities use FIDO2 keys that require
a touch or PIN. Use the operator handoff below when authentication needs
interaction.

The probes need a recent OpenSSH client with `ForkAfterAuthentication` and
`SSH_ASKPASS_REQUIRE` support. An older client that rejects a probe option
fails immediately. The examples use GNU coreutils `timeout` on Linux and
macOS (`gtimeout` on some macOS installations). The repo's transport helper
specifically requires `timeout` on its PATH. Use a wall-clock deadline for
the whole unattended probe, including any proxy or key provider.
`ConnectTimeout` only covers connection establishment.

### Read-only SSH

Use the intended SSH alias or destination and the same user, port and
connection options as the planned operation. For example:

```sh
target=hpp-1
timeout -k 1s 5s ssh -G "$target" </dev/null
```

Inspect the effective hostname, user, port, jump/proxy, and identity/agent
locally. Before checking a master, compare the `controlpath` from `ssh -G`
with the expected socket path for that exact destination, user, and port.
Use the socket only if the path matches and is specific to that destination.

```sh
timeout -k 1s 5s ssh -o BatchMode=yes -O check "$target" </dev/null
```

The master check only shows that a socket is listening. A missing master
blocks tools that require one. Use the hostname probe to establish
reachability and verify the destination:

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
Ask the operator to authenticate in their own terminal with the same
destination, user, port, and connection settings. When a tool requires a
master, set `target` in that terminal to the verified SSH destination. The
operator can then run this command with the expected host-specific
`ControlPath` (or supply that path with `-S`):

```sh
timeout --foreground -k 1s 60s ssh -o BatchMode=no -fMN "$target"
```

The operator completes the touch or PIN within the deadline. After successful
authentication, `-f` backgrounds the master so it stays available. When a
step needs fresh authentication, the operator runs it in their terminal if
the runner cannot authenticate unattended. The agent's part is the bounded
recheck from the runner, which must be able to access the same socket if one
is required.

An agent may start interactive authentication or a foreground master only
with the operator present, their explicit agreement, and a wall-clock
deadline. An unanswered touch or PIN at the deadline is a missing reply.
Stop and report the unmet prerequisite. A missing reply is never approval.

When access is unavailable, report the unmet prerequisite and the exact
operator step or check to run from a capable environment. Defer the dependent
live steps and continue independent work. Record those validations as
deferred until they run and produce evidence. A passing access probe confirms
transport prerequisites. Record build and behavioral results when those
checks run.

## Reading state off a host

Bound the window, count, then excerpt:

```sh
timeout -k 1s 30s ssh -nT -o BatchMode=yes -o ControlMaster=no "$target" \
  'journalctl -u <unit> --since "7 days ago" | grep -c "<pattern>"'
timeout -k 1s 30s ssh -nT -o BatchMode=yes -o ControlMaster=no "$target" \
  'journalctl -u <unit> --since "2026-09-18 16:40" --until "2026-09-18 17:00" -o short-iso'
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
   Feed a script with this command. Single-quote the PromQL inside the script
   and pass it via `--data-urlencode "query=$q"`.

   ```sh
   timeout -k 1s 30s ssh -T -o BatchMode=yes -o ControlMaster=no "$target" bash -s < script.sh
   ```
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
# --local-secrets (bootstrap, VM and recovery drills only; routine secrets
# changes are pinned with `task secrets:publish`) uses NIX_SECRETS_PATH if set.
# Otherwise the helper looks beside the current checkout, then beside the
# primary checkout when run from a linked worktree.
scripts/activate-nixos.sh --host hpp-1 --dest hpp-1 --dry-run  # eval + print plan only
scripts/activate-nixos.sh --host hpp-1 --dest hpp-1 --preflight  # transport and identity probes only
scripts/activate-nixos.sh --host hpp-1 --dest hpp-1 --action check  # preflight, build, assert identity
scripts/activate-nixos.sh --host hpp-1 --dest hpp-1            # switch
```

Only the operator may decide to skip the probes with `--skip-preflight`
on the helper or `SKIP_PREFLIGHT=true` with deploy, rebuild, or bootstrap
rebuild tasks. A failed probe requires resolving or reporting the unmet
prerequisite. Never use either flag to get past a failed probe. Record an
operator-directed bypass as skipped preflight.

With `--local-secrets`, the preflight compares the checkout's HEAD with the
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

### Validating a dev host in one command

`task validate:<host>` (`scripts/validate-host.py`) runs the whole live
validation sequence through this helper: inputs (source SHA, locked
nix-secrets rev, overrides, expected closure from `--dry-run`), `--preflight`,
a read-only pre-change read (running closure, generation, failed units, next
`nixos-upgrade` run), `--action check`, then with `-- --switch` the switch,
post-switch checks (expected closure running, `is-system-running` = running,
no failed units, each `--probe` command exits 0 on the target) and an
optional `--observe <duration>` window. Each stage logs to its own file under
`$XDG_STATE_HOME/nixos-validate/<host>/` and the run ends with one JSON
evidence record whose path it prints. It only accepts hosts whose hostSpec has
`serverEnvironment = "dev"` (refused before any ssh otherwise), has no option
that skips the helper's checks, and stops at the first failure with no retry,
rollback or kill; a switch past its deadline is left running and reported as
unknown (exit 3). A failed or empty required host read, an ssh that fails or
drops, and a failing probe (run under `pipefail`) each stop the stage with no
further connection. The record stores probes only as index, short sha256 id
and exit code, scrubs `$HOME`, URL userinfo, query strings and token-like
strings from messages and input values, and records the effective
`--local-secrets` checkout (home-relative path, HEAD, dirty counts). A run
directory inside any Git repository is refused. Go Task reports a failed
command as exit 201; run `task --exit-code validate:<host> -- …` (or `-x`) to
get the driver's own status (checked with go-task 3.48.0). Arguments go after
`--`:

```sh
task -x validate:hpp-1                   # check only
task -x validate:hpp-1 -- --switch --observe 3m \
  --probe 'systemctl is-active caddy.service'
```

`system.autoUpgrade` is the one accepted exception: it activates without the
helper, but it only ever activates the local host from `main`, so there is no
remote target and no cross-host identity risk.

Do not call `nixos-rebuild --target-host` or `switch-to-configuration` by hand:
that bypasses the assertions (a test fails if any Taskfile does).

A closure copy waiting on authentication can show a live `ESTAB` socket
and transfer ~0 bytes. During read-only diagnosis from a verified connection,
inspect the target:

```sh
timeout -k 1s 15s ssh -nT -o BatchMode=yes -o ControlMaster=no "$target" \
  'ps -eo pid,etime,args | grep -E "[s]shd-session|[n]ix-store --serve"'
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
configured remote when its transport and credentials work. Bound unattended
Git operations with a wall-clock deadline. Disable Git prompts and use SSH
BatchMode in case a rewrite selects SSH. With the standard OpenSSH client:

```sh
timeout -k 1s 15s env GIT_TERMINAL_PROMPT=0 SSH_ASKPASS_REQUIRE=never \
  GIT_SSH_COMMAND='ssh -o BatchMode=yes' git ls-remote origin HEAD </dev/null
```

Carry forward any custom SSH options the remote requires. Use the operator's
terminal if authentication needs a touch or PIN. A read probe can establish
fetch access. Confirm publication after a push using the remote SHA.

### HTTPS fallback

The flake's [Git config](../../modules/system/_hm-core/git.nix) installs a
global `url."git@github.com:ianepreston/".insteadOf` rule for
`https://github.com/ianepreston/`. It can send an explicit HTTPS URL over
SSH. `insteadOf` applies to fetch and push. For push, a matching
`pushInsteadOf` can override it. A configured remote with an explicit
`pushurl` ignores `pushInsteadOf`. `-c url.<base>.insteadOf=<junk>` adds
another value to the multi-valued setting, so the existing rewrite still applies.

Before fetching or pushing to an explicit HTTPS URL, check its effective
URL and the applicable push rules using the same configuration as the transfer:

```sh
https_url=https://github.com/ianepreston/nixos.git
timeout -k 1s 5s git ls-remote --get-url "$https_url" </dev/null
timeout -k 1s 5s git config --show-origin --get-regexp '^url\..*\.pushinsteadof$' </dev/null
```

Require the first command to return the intended HTTPS URL. Before pushing,
also confirm no `pushInsteadOf` prefix matches that URL. Exit 1 from the
config query with no output means no such rules are set.

If a confirmed global rewrite is the blocker and HTTPS is authorized, set
`GIT_CONFIG_GLOBAL=/dev/null` only on the individual URL checks and transfer
for this fallback. Repeat the checks before transferring. Carry forward any
settings the transfer needs, including the effective `core.hooksPath` for a
push if suppression would change it. Read it with
`git config --get core.hooksPath` before suppression and pass
`-c core.hooksPath="$hooks_path"` to Git when set. Keep local and system
configuration in effect. If the effective URL cannot be verified or required
hooks or credentials cannot be preserved, use a capable operator terminal.

Once those checks confirm HTTPS, run the needed operation with the checked
configuration. Fetch can use anonymous HTTPS. For push, this example uses
an authenticated GitHub CLI and `branch` set to the task branch:

```sh
timeout -k 1s 120s env GIT_TERMINAL_PROMPT=0 SSH_ASKPASS_REQUIRE=never \
  GIT_SSH_COMMAND='ssh -o BatchMode=yes' \
  git fetch "$https_url" refs/heads/main:refs/remotes/origin/main </dev/null
timeout -k 1s 120s env GIT_TERMINAL_PROMPT=0 SSH_ASKPASS_REQUIRE=never \
  GIT_SSH_COMMAND='ssh -o BatchMode=yes' \
  git -c credential.helper= -c credential.helper='!gh auth git-credential' \
  push "$https_url" "HEAD:refs/heads/$branch" </dev/null
```

Keep tokens out of URLs and command arguments.

Commit normally with the configured identity and installed hooks. A failed
push citing email privacy needs a commit created with the configured public
identity. Changing push flags cannot change the author already in the commit.

Verify the remote SHA even if no local tracking ref was updated:

```sh
gh api repos/ianepreston/nixos/branches/<branch> --jq .commit.sha
```
