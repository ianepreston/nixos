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
  adds the VM's age key to `<host>.yaml` + `shared.yaml` creation rules in
  `../nix-secrets/.sops.yaml`. Uncommitted; `task secrets:publish` to keep it,
  `git restore` in `../nix-secrets` to revoke.
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
against published secrets.

Deploying from an agent session (no tty for FIDO2): see
[skills/_shared/host-access.md](../../skills/_shared/host-access.md).
