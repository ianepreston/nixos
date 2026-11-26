# Testing, bootstrap, and disk-layout changes

## Disko changes need a reinstall, never `task deploy`

Disko-managed subvolumes/partitions only appear at install time, when
nixos-anywhere runs disko. `task deploy:<host>` does an in-place
`nixos-rebuild switch`, which still adds the `fileSystems.*` entries disko
generates; systemd then tries to mount paths that don't exist,
`local-fs.target` fails, dependent units (sshd among them) cascade, and the
host goes dark until a console rollback. Rollback doesn't always clear the
runtime job queue, so a second deploy afterwards can re-trigger it.

Any change touching `modules/hosts/_<host>-disks.nix` goes through
`task bootstrap:reinstall HOST=<host> DEST=<ip>` (or `bootstrap:new`), with
`IMPERMANENT=true` if preservation is involved. That flag seeds the SSH host
key into `/persist/etc/ssh/`; without it sshd can't load a host key after the
first rollback (preservation bind-mounts an empty file) and the host comes up
unreachable.

Reinstalling **hpp-1** without `SSH_HOST_KEY_FILE` gives it a new host key, and
`hostKey` in `modules/system/nix-cache.nix` has to follow. Otherwise
amos1/terra/luna quietly stop substituting from it and go back to building
everything locally. Adding a new cache consumer means adding its
`ssh/ed25519` public key to `consumerKeys` in the same file. The client's
assertion names the fix.

## Flake checks: `task check` and CI

`scripts/flake-checks.sh` is the one implementation of flake-validation
orchestration (#1021). `task check` runs its `local` preset; the CI
`check.yml` stages call its individual modes. The workflow keeps scheduling,
the fork guard, runner selection and the split between the public `lint` job
and the deploy-key jobs. The driver decides what to evaluate and build, in
what order, and reports what it did not run; output-shape validation is nix's
own (`nix flake check`), not re-implemented. It needs `nix`, `bash` and `jq` on
`PATH` (the NixOS runner and ubuntu-latest have all three; on a Mac `jq` comes
from the home-manager profile or Homebrew). Modes:

| Mode | Does | CI job |
| --- | --- | --- |
| `lock` | `nix flake metadata --no-update-lock-file`; a stale lock fails, nothing re-locks | `flake-check` |
| `eval-configs` | drvPath of every `nixosConfigurations`/`darwinConfigurations` toplevel and `homeConfigurations` activationPackage, discovered and evaluated one at a time (what CI did) | `flake-check` |
| `eval-outputs` | `nix flake check --no-build --all-systems`: nix's own derivation, overlay, module, app and system-name checks for every system, evaluated but not built | local only |
| `lint --system S` | builds `checks.S.pre-commit^*`, the git-hooks.nix hooks | `lint` |
| `build-checks --system S [--exclude N]` | builds every `checks.S.<name>^*`, one at a time | `checks` (`--exclude pre-commit`) |

`eval-outputs` stays out of CI: its parallel evaluation is what raced on
concurrent `addToStore` on the Linux runner (see `check.yml`), which is why CI
evaluates configurations sequentially. Locally it is the evaluation the old
`nix flake check --all-systems` gate ran, minus the native builds that `lint`
and `build-checks` now run one at a time.

Rules the driver enforces:

- **One flake identity**: every stage passes the `--flake` reference to nix
  verbatim (git metadata, `?dir=` and all).
- **All outputs**: every build requests `^*`, as `nix flake check` did,
  locally and in CI (a superset of CI's former default-output builds).
- **Required sets**: each of the three configuration kinds must exist and have
  at least one usable name, and a system selected for `build-checks` must
  have at least one check left after `--exclude`.
- **Names**: every attribute name, including the deferred listing, goes
  through one validator. It is decoded from JSON without rewriting and must
  contain no escape and match `[A-Za-z0-9_][A-Za-z0-9_+.-]*` as a whole
  string; anything else (empty, trailing newline, spaces, quotes, non-ASCII)
  fails, reported JSON-escaped.
- **Exit status**: a result is recorded only after the exit status of every
  command producing it (nix, jq) was checked; output is never trusted on its
  own. A failed item fails the run (exit 1) but the rest of its stage still
  runs, so one run reports every failure.

**Platform policy.** `lint` and `build-checks` default to this machine's
`nix config show system`; `extra-platforms` also count as native. Any other
system is refused (exit 2) unless `--remote-builder` is given *and* a
successful `nix config show builders` declares a machine for that system with
at least one build slot. The `builders` value is read as Nix's own parser
does: per line, `#` to end of line is a comment first, then `;` separates
entries, `@FILE` includes are expanded (a missing file is skipped); zero-slot
and malformed entries are ignored. That is all it verifies: Nix chooses the
machine per build, reachability is not probed, and an output already in the
store or a substituter is not rebuilt, so a pass shows the check's output
exists, not that the builder ran it.

**On a Mac**, `task check` runs locally: the lock check, every configuration
evaluation (including the Linux hosts, which evaluate fine on Darwin),
`nix flake check --no-build --all-systems`, `checks.aarch64-darwin.pre-commit`
and every other `aarch64-darwin` check. It builds no Linux derivation:

- the **x86_64-linux** checks (VM tests, Linux-only runtime suites) are
  evaluated and listed as `DEFERRED`; build them with `task check:linux`
  (delegated to the remote builder declared in `/etc/nix/machines`, here
  `terra`) or leave them to the CI `checks` job. One check:
  `nix build .#checks.x86_64-linux.<name> --no-link`;
- the **aarch64-linux** and **x86_64-darwin** checks are evaluated and stay
  `DEFERRED`: no local task or CI job builds them.

When `nix flake check --no-build` fails, every non-native system is reported
`NOT-RUN` (a failure), never `DEFERRED`. Host toplevel builds stay out of
`task check`; use `task build HOST=<host>`.

## Local VM sandbox (`task vm:*`)

`taskfiles/vm.yaml` drives one quickemu VM at a time under `~/vms/nixos-vm/`,
with an SSH host key (and matching age identity) preserved across
`vm:down`/`vm:up`.

- `task vm:up` — boot on the installer ISO (rebuilds `latest.iso` only if
  absent or `FORCE_ISO=true`).
- `task vm:sops-authorize TARGET=<host>` — one-time per real-host secret set:
  adds the VM's age key to `<host>.yaml` and to every other sops file the VM's
  flake host (`HOST`, default `tests-server`) reads, in
  `../nix-secrets/.sops.yaml`. The edit stays uncommitted, and `vm:install`
  builds it with the default `LOCAL_SECRETS=true`, so nothing needs
  publishing. `git restore` in `../nix-secrets` revokes it. To keep it, commit
  it on a `nix-secrets` branch and pin that branch with
  `task secrets:publish MSG="authorize VM"`
  ([secrets.md](secrets.md#workflow-for-a-change-that-needs-new-or-updated-secrets)).
- `task vm:install HOST=<flake-host>` — `bootstrap:reinstall` against the VM
  reusing the persistent key. HOST must be on the allow-list (`tests-server`,
  `tests-desktop`); real hosts' disk layouts won't boot under quickemu.
- `task vm:down` — kill quickemu, delete the qcow2, keep the host key.
- `task vm:reset HOST=<flake-host>` — `down` → `up` → `install`.

To add a VM-compatible flake host, add it to the `case` allow-list in
`vm.yaml`'s `install` task and import `modules/hosts/_vm-disks.nix`.

## `LOCAL_SECRETS`

`task bootstrap:{install,reinstall,new,rebuild}` and `task vm:install` take
`LOCAL_SECRETS=true|false` (default `true`). True builds with
`--override-input nix-secrets path:../nix-secrets`, picking up uncommitted
edits in the sibling checkout; false uses `flake.lock`. Use false only to test
against published secrets. These tasks and `vm:sops-authorize` use
`../nix-secrets` beside the checkout they run from (bootstrap also rsyncs it to
the target), not `SECRETS_DIR`, so run them from the primary checkout with an
up-to-date sibling.

That default exists for the cases a published pin cannot serve: first-time
bootstrap (the new host's recipients are not published yet, and the target
may lack credentials for the private input), disposable VM authorization, and
recovery drills that need unpublished sops recipient changes. Fast-forward the
sibling checkout first: a checkout behind the lock breaks every secret on the
target. After a bootstrap, push the host's keys (committed by
`bootstrap:secrets`) and pin them with `task secrets:publish`, so routine
rebuilds use the lock.

Routine `task deploy:<host>`, `task rebuild[:<host>]` and `task hashes` are the
opposite: they default to `flake.lock` (the revision `task build` and CI use;
auto-upgrade reads the lock from the GitHub flake, which can differ from your
local checkout). To test unpublished secrets on a real host, publish them on a
`nix-secrets` branch and deploy the resulting pin
([secrets.md](secrets.md#workflow-for-a-change-that-needs-new-or-updated-secrets)).
`LOCAL_SECRETS=true task deploy:<host>` still opts into the local checkout,
for the explicit cases above only.

For deployment access checks and operator handoff, see the
[host access preflight](../../skills/_shared/host-access.md#host-access-preflight).
