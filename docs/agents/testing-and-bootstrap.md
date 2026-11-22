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
