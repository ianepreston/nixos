# Tandoor cleanup tooling

Operator tooling for the Tandoor foods/units/supermarkets consolidation
tracked in [#280](https://github.com/ianepreston/nixos/issues/280). Not part
of the NixOS deploy — these are throwaway-ish scripts you run by hand from a
workstation that can `ssh` to the server hosts.

## Script vs. output split

Only the **scripts** live in this repo. Their **outputs** (inventory dumps,
the generated mapping, recipe-usage index) are operator-local and stay out of
tree — the scripts hardcode `~/src/tandoor-cleanup/` as the output dir:

| In repo (`scripts/tandoor-cleanup/`) | Operator-local (`~/src/tandoor-cleanup/`) |
| --- | --- |
| `fetch_inventory.py` | `inventory/*.json` (foods, units, recipes, …) |
| `build_usage.py` | `usage.json`, `inventory/recipe-detail.json` |
| `build_mapping.py` | `mapping.yaml` |
| `apply.py` | — |

So you can re-clone this repo anywhere and the scripts run; they read/write the
working data under `~/src/tandoor-cleanup/` regardless of where the scripts sit.
Create that dir (and an `inventory/` subdir is made automatically) before the
first run.

## How they reach Tandoor

There is no direct TCP path to Tandoor's API from a workstation (it binds
`127.0.0.1:8083` behind caddy). The scripts shell out to `ssh <host>` and run
`curl` on the host with the right `Host:` header, so they bypass caddy/TLS and
hit the container loopback directly.

Auth is a Tandoor API token, operator-local (not in sops). Every script reads
it from `~/.config/tandoor-cleanup/<target>.token`, so each target it talks to
needs its own token file. Tokens live in Tandoor's postgres DB, so a token is
only valid against the instance whose DB contains it.

## Targets and the chosen workflow

All four scripts take `--target {hpp-1,amos1}`, **defaulting to `amos1`** (prod).

We originally planned to mirror prod onto `hpp-1` (dev) and validate there
before touching prod, but `hpp-1`'s tandoor uses a *separate* authentik
(`authentik.dnix`) from prod's (`authentik.amos`). Copying prod's DB onto
`hpp-1` breaks OIDC login there (allauth "username already exists", because the
dev authentik issues a different OIDC subject for the same user). So the UI on a
prod-mirrored `hpp-1` is unusable for visual validation.

The workflow we settled on instead:

- **Operate directly on `amos1`**, taking a named pre-pass `pg_dump` as a
  rollback point before each destructive pass, and verifying in the working prod
  UI. API-level operations (merges/deletes/aliases) are reversible via that dump.
- `hpp-1` is kept as a **dev playground** restored from its own pre-mirror
  snapshot — *not* a prod mirror. Don't point inventory collection at it
  expecting prod data.

Take a rollback dump before a destructive pass on prod:

```sh
TS=$(date +%Y%m%d-%H%M%S)
ssh amos1 "sudo -u postgres bash -c 'pg_dump -Fc tandoor > /var/backup/postgresql/tandoor.pre-<pass>-$TS.dump'"
```

That lands in the restic-backed dir, so it's also picked up by the nightly snapshot.

## Pipeline

```sh
python3 fetch_inventory.py            # -> inventory/*.json  (default --target amos1)
python3 build_usage.py                # -> usage.json        (slow: fetches every recipe detail)
python3 build_mapping.py              # -> mapping.yaml      (proposed merges/renames/deletes — review by hand)

# dry-run (default) then apply, per phase.
python3 apply.py --target amos1 --phase units            # dry-run
python3 apply.py --target amos1 --phase units --apply    # merges + deletes
python3 apply.py --target amos1 --phase unit-aliases --apply   # forward-looking aliases (separate motion)
```

`fetch_inventory.py` / `build_usage.py` read from the chosen target;
`build_mapping.py` is offline (reads `inventory/` + `usage.json`). `apply.py` is
idempotent — it skips ops whose source row is already gone (merges/deletes) or
whose alias already exists, so re-running after a partial apply is safe.

Alias phases (`unit-aliases`, `food-aliases`) are deliberately **separate** from
the merge phases (not in `--phase all`): apply and verify the merges first, then
generate the forward-looking aliases from the same validated mapping rows.
