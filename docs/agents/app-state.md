# App state, backups, and recovery

## `myAppState`: preservation + backup from one declaration

`myAppState.<app>` in the owning module renders the preservation entry, the
restic path (unless `backup = false`), and the `expectedPreservedDirs` guard in
`modules/profiles/server-apps.nix`. There is no profile edit to make.

## Two state checks, and what each catches

Both run only where preservation is enabled (the server hosts).

- **`expectedPreservedDirs`** (`modules/profiles/server-apps.nix`) is derived
  from `myAppState`, so it catches a *declared* directory that was later
  dropped from `preservation.preserveAt` (a `mkForce`, a filter). It cannot see
  state nobody declared.
- **`myAppStateAudit`** (`modules/system/app-state.nix`, path rules in
  `modules/system/_app-state/state-directory-audit.nix`) is the independent
  check (#1024). It reads every enabled unit's systemd `StateDirectory=` and
  fails eval naming `<unit>: <dir>` for any directory no preserved directory
  covers. Directories are normalized to `/var/lib/<dir>`, or
  `/var/lib/private/<dir>` when the unit sets `DynamicUser` (the
  `/var/lib/<dir>` symlink is not storage); each entry of a multi-directory
  `StateDirectory=` is checked on its own; `:<symlink>` suffixes are dropped. A
  preserved directory covers itself and its descendants on a path-component
  boundary: `/var/lib/foo` covers `/var/lib/foo/bar`, not `/var/lib/foobar`.

The audit only sees `StateDirectory=` declared through `systemd.services`. It
does not see state an app writes elsewhere, `CacheDirectory=`, bind mounts, or
directories set only in an upstream unit file shipped via `systemd.packages`;
those still depend on the owner declaring `myAppState`.

### Fixing an audit failure

Preserve it: declare `myAppState.<app>` in the owning module (with
`dynamicUser = true` and the private path for a DynamicUser unit). That also
backs it up unless `backup = false`.

Or, if the owner decides the state may be lost, declare an exemption **beside
the service**, never in a central list:

```nix
myAppStateAudit.exemptions.<owner> = {
  unit = "<unit>.service";
  directories = [ "/var/lib/<dir>" ]; # exactly as the audit names it
  disposition = "disposable";
  reason = "Why losing this on every reboot is fine.";
};
```

`disposition = "pending"` records a known uncovered directory whose owner has
not decided yet. It passes eval but prints a warning on every build, so it is
never silent. Eval also fails on an exemption with an empty `reason`, or one
that no longer names an uncovered directory of that unit (renamed, removed or
since preserved), so exemptions cannot outlive what they excuse.

Current exemptions (`rg -n 'myAppStateAudit.exemptions' modules`) are all
`pending` from the #1024 audit: the redis instances (`authentik.nix`,
`paperless-ngx.nix`, `manyfold.nix`), `homepage.nix`, `vector.nix`,
`llm-metrics.nix`, `github-runner.nix`, and NetworkManager and dhcpcd in
`preservation-server.nix`.

`nix build .#checks.x86_64-linux.state-directory-audit --no-link` runs the
synthetic compositions (`modules/flake/checks-state-directory-audit.nix`).

## Recovery metadata: declare it beside the app

`taskfiles/recovery.yaml` holds the generic restore templates; app modules
contribute `myRecovery.apps.<app>`. `task recovery:app APP=<app> HOST=<host>`
evaluates the generated manifest, and `recovery:all` runs enabled entries
sorted by their `order`. Don't add a Taskfile registry entry or an aggregate
list. An app that is preserved and backed up but has no `myRecovery.apps`
entry is restorable only by hand.

| Shape                                              | `kind`       | Metadata to declare                                                                                                                                                     |
| -------------------------------------------------- | ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Container, no postgres                             | `"volume"`   | `units = [ "podman-<app>.service" ]; paths = [ ... ];`                                                                                                                  |
| Container + `myPostgresApp.<app>`                  | `"postgres"` | Container unit, database name (respecting any override), paths outside `/var/backup/postgresql`                                                                         |
| Native + `myPostgresApp.<app>`                     | `"postgres"` | Every consumer service, database role/name, any on-disk state path                                                                                                      |
| Native + `mySqliteQuiesce.apps.<app>`              | `"sqlite"`   | Unit and state path. `/var/backup/sqlite/<app>` and the staged-to-live swaps derive from `mySqliteQuiesce.apps.<app>.databases`; `sqliteOwner = "@env@"` is the default |
| Native, no postgres or quiesce                     | `"volume"`   | Unit and state path                                                                                                                                                     |
| Timer-driven oneshot container (e.g. spierscraper) | `"volume"`   | Empty `units` and its state path                                                                                                                                        |

For apps with an HTTP endpoint, set `health.url` so the dispatcher fails a
botched restore. Override the default 200 / 30 retries / 2 s only when needed
(jellyfin uses 60 retries for its longer warm-up).

## `restartUnits` goes on the template, not the secret

When an app declares its own `sops.templates."<app>.env"` (not threaded
through `myAuthentik.oidcApps`), put `restartUnits` on the **template only**.
sops-nix re-renders the template whenever any referenced placeholder changes,
so one declaration covers every rotation; splitting it across secret and
template invites drift.

Exceptions:

- Aggregators (`myPostgresApp`, `myAuthentik.oidcApps`) already attach
  `restartUnits` to the secrets they own — leave those.
- A secret consumed directly (`config.sops.secrets.<k>.path` in an
  `ExecStart`, oneshot, or config-file reference) has no template, so the
  trigger goes on the secret (e.g. `grafana/bootstrap_password`, read via
  `$__file{}` from grafana.ini).

`pinchflat.nix` still has it on both; converge to template-only on a drive-by.

## Startup ordering

`EnvironmentFile=` and `restartUnits` add no ordering against sops. Units
listed in `myPostgresApp.<app>.consumerService` or
`myAuthentik.oidcApps.<app>.appRestartUnit` inherit an edge from the
aggregator; any other unit that reads a sops file at startup races it (#580).
Declare the edge on the unit itself:

```nix
systemd.services.<svc> = {
  after = [ "sops-install-secrets.service" ];
  wants = [ "sops-install-secrets.service" ];
};
```

When adding or pinning a module, check *every* generated unit that reads the
file (`systemctl show <unit> -p After`), not just the ones you listed.
