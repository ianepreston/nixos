# Provisioning per-app secrets (`task secrets:*`)

Secrets live in the sibling repo `../nix-secrets` (a flake input). Run the
tasks from **this** repo (`taskfiles/secrets.yaml`). All default to
`HOST=hpp-1` and refuse to overwrite an existing key unless `FORCE=true`.

| Task                                                   | Writes                                                               | Use for                                                      |
| ------------------------------------------------------ | -------------------------------------------------------------------- | ------------------------------------------------------------ |
| `task secrets:oidc APP=<app>`                          | `<app>.oidc_client_id` (hex 16), `<app>.oidc_client_secret` (hex 32) | `myAuthentik.oidcApps.<app>`                                 |
| `task secrets:dbpw APP=<app>`                          | `<app>.db_password` (hex 16)                                         | `myPostgresApp` with TCP + password (not peer auth)          |
| `task secrets:secret APP=<app> KEY=<key> [LEN=<bytes>]` | `<app>.<key>` (hex)                                                  | app-specific tokens: session keys, signing secrets, API keys |
| `task secrets:edit:<host>` / `secrets:view:<host>`     | —                                                                    | pasted-in, non-random values                                 |
| `task secrets:rekey`                                   | —                                                                    | after changing the key registry in `.sops.yaml`              |
| `task secrets:publish MSG="..."`                       | —                                                                    | commit + push `nix-secrets`, then `nix flake update nix-secrets` here; no-op when clean, safe to run before a deploy |

Workflow for a new app:

1. Decide which secrets it needs.
2. Run the matching task(s). Keys nest under the app name, so
   `sops.secrets."<app>/oidc_client_id"` / `sops.placeholder."<app>/db_password"`
   resolve directly.
3. `task secrets:publish MSG="add <app> secrets for <host>"`. The secrets are
   usable in a deploy after that.

Stick to `oidc_client_id`, `oidc_client_secret`, `db_password` so existing
modules (`tandoor.nix`, `paperless-ngx.nix`) stay copy-paste templates; use
`secrets:secret` only for something beyond those.

Every task that decrypts (`oidc`, `dbpw`, `secret`, `view`, `rekey`) uses the
operator identity in `~/.config/sops/age/keys.txt`. It exists only on terra and
luna, and it is a YubiKey stub (#504), so it works only while one of the two
operator tokens is plugged in. No PIN and no touch are needed, so it works fine
from an agent session. `yubikey plugin: Could not open YubiKey with serial …`
means no token is present: ask the user to plug one in. Nothing is wrong with
the key. On any other host these tasks cannot decrypt at all.

A local `../nix-secrets` checkout that is *behind* origin/main breaks every
secret on a deployed target, not just the missing one — pull before deploying.
