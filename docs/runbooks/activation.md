# Activating a host

Every task that activates a NixOS closure (`rebuild`, `rebuild:<host>`,
`deploy:<host>`, `bootstrap:rebuild`) goes through `scripts/activate-nixos.sh`,
which runs a bounded transport preflight before building and refuses unless
the machine's hostname, the closure name
(`/nix/store/<hash>-nixos-system-<host>-<version>`), and the closure's own
`etc/hostname` all equal `<host>`. `ACTION=boot|test|check` changes the action
(`bootstrap:rebuild` always switches). Use `task ssh:preflight HOST=<host>`
to probe the SSH agent, Nix store transport, builders and target hostname
without building. An open SSH master alone only confirms the control socket
responds. Bootstrap rebuilds warn if there is no master and continue with
the other probes. `ACTION=check` probes the store and skips the copy to the
target. Use `SKIP_PREFLIGHT=true` with deploy, rebuild, or bootstrap rebuild
tasks, or pass `--skip-preflight` directly to the helper, to bypass the
probes. The helper checks the target hostname again in the activation process.
With a separate build host every ssh leg (including `nix copy`) is forced to
`ControlMaster=no`, `ControlPath=none`, `ProxyJump=none` and
`ProxyCommand=none`, and explicit
`-J`/`ProxyJump` options are rejected (a jump client would not inherit them);
single-host deploys still accept `-J` and reuse your pre-opened ssh master
(needed for hardware-key auth): the closure is copied over the legacy `ssh://`
store (one plain `ssh` per command, which picks up the master's `ControlPath`),
the path observed to work with no touch (#1039). Whether `ssh-ng://` would
reuse the master depends on the Nix version and its `max-connections` store
option (see `skills/_shared/host-access.md`). In split-host mode every leg
authenticates afresh, so a hardware key needs a touch per leg. Split-host and builder probes can open
connections that authenticate in BatchMode. The builder probe runs from the
caller's ssh context, not the Nix daemon's, and a warm builder master can
mask a host-key or authentication failure. When a probe reports that a
touch or PIN is required, the operator handles it in their terminal.
The one accepted exception is `system.autoUpgrade`
(`modules/system/auto-rebuild.nix`): it only ever activates the local host from
`main`, so there is no remote target and no cross-host identity risk.
