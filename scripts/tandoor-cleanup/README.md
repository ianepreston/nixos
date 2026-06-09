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
python3 recommend.py                  # annotates review_merges with a first-pass dst_id + rec note

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

### Food renames vs. review-merges (operator confirmation step)

`build_mapping.py` splits non-canonical junk foods into three food buckets:

- **`merges`** — normalized name exactly matched a canonical (ODP) food.
  Auto-applied by `--phase food-merges`. No review needed.
- **`review_merges`** — no exact match, but the cleaned name shares a *content*
  token with one or more canonicals ("baby spinach" → Spinach, "ginger" →
  Ginger root / ground / paste). These can't be auto-merged — token collisions
  are real ("salted butter" shares "salted" with "Salted Pistachios") — so each
  row lists ranked `candidates` and an empty `dst_id` for you to fill. A small
  high-confidence subset (single candidate, junk is a strict less-specific form,
  same semantic descriptors) ships **pre-filled** with a suggested `dst_id`.
- **`renames`** — no canonical candidate at all; pure name cleanup.

**`recommend.py` gives you a head start.** Run it after `build_mapping.py` to
pre-fill a first-pass `dst_id` and a `rec:` note on each `review_merges` row.
It scores each candidate by IDF-weighted token overlap (so "lemon juice" matches
"Lemon Juice", not "Apple juice"), gated on descriptor compatibility (a merge
needs matching colors / salted-dried-ground / fat-content, unless the recipe
text justifies the difference) and a different-food guard (so "butter" doesn't
merge into "Peanut Butter"). It also reads the recipe `used_in` quote for
fresh-vs-dried / leaf-vs-seed signal (e.g. "Ginger // Peeled & Grated" →
Ginger root). It is conservative — when unsure it leaves the row as a rename
with a `rec: 'rename? closest …'` note rather than guessing a merge. Re-run it
after every `build_mapping.py` (which drops the annotations).

Operator pass: open `mapping.yaml` and for each `review_merges` row either

- set `dst_id` (and `dst_name`) to a canonical from `candidates` → it **merges**, or
- leave `dst_id: 0` → it falls through to an in-place **rename** to `new_name`.

The `rec:` note is the script's recommendation; trust but verify, especially
rows where the recipe quote contradicts the pick. Review the pre-filled
suggestions too — clear a `dst_id` back to `0` to reject it. Then apply, merges
before renames:

```sh
python3 apply.py --target amos1 --phase food-review-merges          # dry-run (rows with dst_id)
python3 apply.py --target amos1 --phase food-review-merges --apply  # PUT /food/{src}/merge/{dst}/
python3 apply.py --target amos1 --phase food-renames                # dry-run (renames + blank-dst review rows)
python3 apply.py --target amos1 --phase food-renames --apply        # PATCH /food/{id}/ {name}
```

Both are idempotent: `food-review-merges` skips rows whose source food is gone;
`food-renames` skips a food already named `new_name`. Like the alias phases,
neither is in `--phase all` — they consume operator decisions, so they're run by
hand after the mapping is reviewed.
