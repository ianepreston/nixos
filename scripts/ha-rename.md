# Home Assistant device and entity renames

`scripts/ha-rename.py` runs on a workstation and connects to Home Assistant's
WebSocket API. It reads a JSON plan and a **current local copy** of the HA
configuration, including `.storage`. The copy must include `automations.yaml`,
`scripts.yaml`, `scenes.yaml`, and all `.storage/lovelace` and
`.storage/lovelace.*` dashboard files that exist on the server. Missing YAML
files are treated as absent. Keep the copy current and avoid concurrent edits
or registry changes during the run; the script cannot detect a stale copy.

Example plan (all identifiers here are fictional):

```json
{
  "devices": [
    {
      "name": "Sample",
      "model": "Model A",
      "area_id": "test_room",
      "new_name": "New sample",
      "old_prefix": "sample",
      "new_prefix": "new_sample",
      "entities": {
        "sensor.sample_temperature": {
          "name": "Temperature",
          "labels": ["test_label"]
        }
      }
    }
  ]
}
```

`name` is the current user-set device name, or the integration name if none
is set; `model` and `area_id` are exact registry values (area ID, not display
name). The match must be unique. Prefixes are entity object IDs without the
domain: every registered entity on the device must have that prefix as its
whole object ID or followed by `_`. The `entities` map is optional. Its `name`
sets an entity's user display name (`null` clears it); `labels` replaces its
label-ID list. Omitted fields are left alone. The tool refuses existing or
duplicate device and entity targets, including targets occupied by a live
state or that another planned rename would vacate.

Create a short-lived local file containing a long-lived admin token with mode
`600`. Do not put the token in the plan, command line, or repository; delete
the token file after use. Run from the repository root with the pinned nixpkgs
Python and `websockets` dependency (the URL is an example):

```sh
nix shell --impure --expr 'let pkgs = import (builtins.getFlake (toString ./.)).inputs.nixpkgs { system = builtins.currentSystem; }; in pkgs.python3.withPackages (p: [ p.websockets ])' -c python3 scripts/ha-rename.py \
  --url wss://ha.example.invalid/api/websocket \
  --token-file "$HOME/.config/ha-token" --plan /path/to/plan.json \
  --config-dir /path/to/current-config-copy --log /path/to/dry-run.json
```

The default is a dry run; inspect every printed change and reference. A new,
mode-600 JSON log is written before any update, both on dry runs and on apply.
Use a different `--log` path for each run: existing files are never overwritten.
The log contains old and new IDs, device names, prior entity names and labels,
and old and new person tracker lists. It is an **intended plan**, not an audit
of completed calls; a failed or interrupted apply may be partial. Inspect live
registries and use the log to restore only the changes that actually happened.
Restoring a previously unset device or entity user name requires clearing it,
not setting the integration-provided display name. The tool does not perform
an automatic rollback.

After resolving references, make a fresh local config copy, rerun the dry run,
and add `--apply` to make the changes. Literal entity IDs in the three YAML
files and storage dashboard files are reported; file contents are never
rewritten. A run with file references refuses to apply unless `--force` is
explicitly supplied, in which case those references remain broken until fixed
separately. This literal scan cannot find dynamically constructed IDs, external
integrations, or references in other files. UI-managed person tracker
references are always repointed during apply, including with `--force`.
YAML-managed people cannot be updated via `person/update`: their references
are reported and cause apply to refuse even with `--force`. Update and reload
those configurations before retrying. Afterwards the tool
reads the live device/entity registries, people and states, and fails if the
requested registry changes or affected tracker states do not resolve. It does
not read registry `.storage` files for verification. A disconnected or
unavailable tracker with no state causes verification to fail even if the
rename succeeded; inspect the live system before deciding how to recover.
