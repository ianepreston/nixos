# App state, backups, and recovery

## `myAppState`: preservation + backup from one declaration

`myAppState.<app>` in the owning module renders the preservation entry, the
restic path (unless `backup = false`), and the `expectedPreservedDirs` guard in
`modules/profiles/server-apps.nix`. There is no profile edit to make.

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
