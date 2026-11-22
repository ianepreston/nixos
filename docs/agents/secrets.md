# Provisioning per-app secrets (`task secrets:*`)

Secrets live in the private repo `nix-secrets`, consumed as the `nix-secrets`
flake input. Routine builds, deploys and rebuilds read the revision pinned in
`flake.lock`, so they need no local checkout. The `task secrets:*` tasks
(`taskfiles/secrets.yaml`) run from **this** repo and act on a `nix-secrets`
checkout. The generators default to `HOST=hpp-1` and refuse to overwrite an
existing key unless `FORCE=true`.

## Which checkout

Every secrets task acts on `SECRETS_DIR`, resolved by `scripts/secrets-dir.sh`
in this order:

1. `SECRETS_DIR=<checkout>`, as a task variable or in the environment;
2. `NIX_SECRETS_PATH` (the same variable `--local-secrets` reads);
3. `../nix-secrets` beside this checkout;
4. `../nix-secrets` beside the primary checkout, when run from a linked
   worktree.

Concurrent jobs should each use their own `nix-secrets` worktree and pass it
explicitly, e.g. `task secrets:oidc APP=foo SECRETS_DIR=~/src/nix-secrets-foo`.

| Task                                              | Needs                                                                                                                       |
| ------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `oidc`, `dbpw`, `secret`, `view`, `edit`, `rekey` | a checkout plus the operator identity (below); writes land in that checkout, uncommitted                                    |
| `matrix`                                          | a checkout. It inspects that checkout's recipients, not the lock: to audit what is deployed, check out the locked rev first |
| `publish`                                         | a checkout with HEAD on a branch, push access to `origin`, and network for `nix flake update`                              |
| `pin-main`                                        | no checkout, except with `EXPECT=` (fetches `main` into `SECRETS_DIR`)                                                      |

## Tasks

| Task                                                    | Writes                                                               | Use for                                                                |
| ------------------------------------------------------- | -------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| `task secrets:oidc APP=<app>`                           | `<app>.oidc_client_id` (hex 16), `<app>.oidc_client_secret` (hex 32) | `myAuthentik.oidcApps.<app>`                                           |
| `task secrets:dbpw APP=<app>`                           | `<app>.db_password` (hex 16)                                         | `myPostgresApp` with TCP + password (not peer auth)                    |
| `task secrets:secret APP=<app> KEY=<key> [LEN=<bytes>]` | `<app>.<key>` (hex)                                                  | app-specific tokens: session keys, signing secrets, API keys           |
| `task secrets:edit:<host>` / `secrets:view:<host>`      | —                                                                    | pasted-in, non-random values                                           |
| `task secrets:rekey`                                    | —                                                                    | after changing the key registry in `.sops.yaml`                        |
| `task secrets:publish [MSG="..."]`                      | a `nix-secrets` commit; `flake.nix` + `flake.lock` here              | commit, push the checkout's branch, pin the input to that exact commit |
| `task secrets:pin-main [EXPECT=<commit>]`               | `flake.nix` + `flake.lock` here                                      | restore the canonical `?ref=main` input before the NixOS PR            |

`secrets:publish` (`scripts/secrets-publish.sh`):

- refuses untracked files, a detached HEAD, a merge, rebase, cherry-pick or
  revert in progress, uncommitted changes without `MSG`, a path with both
  staged and unstaged changes, and any change (staged, unstaged or committed)
  outside `sops/` and `.sops.yaml`. Push those by hand. Paths are listed
  without rename detection, so a rename out of another directory counts as a
  change there. With `MSG` it stages the changed files whole and commits them;
- refuses when the branch does not contain the locked revision (a stale
  branch would drop published secrets);
- plaintext guard: every `sops/` file in the index and in **every** commit the
  push would publish (not just the net diff) must be a single `.yaml`/`.json`
  sops document with no duplicate keys. Every value outside its `sops` block
  must be an `ENC[AES256_GCM,…]` envelope or null (sops keeps null
  placeholders), `sops.mac` must be encrypted, and the file must have no
  comments other than `#ENC[…]`. Keys that sops leaves in clear
  (`_unencrypted` suffixes, `unencrypted_regex`) are refused too. If an
  earlier commit leaked plaintext, rewrite the unpushed history before
  publishing. The guard runs again on the commit it creates, before the push,
  in case a commit hook changed the tree;
- pushes `HEAD` to `origin`'s `refs/heads/<branch>` by explicit refspec and
  sets the upstream, so a new branch's first push works and a branch created
  from `origin/main` never pushes to `main`. It never force-pushes, so
  rewritten history is rejected: add commits instead of amending;
- on `main`, pins `?ref=main&shallow=1`; on any other branch it rewrites the
  `flake.nix` url to `?ref=<branch>&rev=<commit>&shallow=1`. Then it runs
  `nix flake update nix-secrets`. It checks that the lock's `locked` and
  `original` entries both carry that url, ref, `shallow: true` and (for a
  branch) rev, and that no other lock node changed. Then it prints the pinned commit.

On failure `flake.nix` and `flake.lock` are always restored to their state
before the run. What happens in `nix-secrets` depends on how far the run got:

- before the commit (any refusal, a guard failure): the index is restored
  exactly and nothing is committed or pushed;
- after the commit but before the push (the post-commit guard or a rejected
  push): the commit stays local and unpushed, and the index matches it.
  `git reset --soft HEAD^` undoes it;
- after the push (the pin or lock check failed): the branch is pushed. Fix
  the cause and run `task secrets:publish` again; with a clean tree it only
  re-pins.

`secrets:pin-main` rewrites the url back to `?ref=main&shallow=1`, re-locks
only `nix-secrets` and checks the lock entry the same way. With
`EXPECT=<commit>` it first checks that `origin`'s `main` contains that commit,
and leaves the branch pin in place if it does not. A squash or rebase merge gives the commit a new
hash and fails that check, so compare the trees by hand.

## Workflow for a change that needs new or updated secrets

1. Start a dedicated branch from current `main`, ideally in its own worktree:
   `git -C <nix-secrets> fetch origin`, then
   `git -C <nix-secrets> worktree add -b <branch> <path> origin/main`. Run the
   generators against it (`SECRETS_DIR=<path>`). Keys nest under the app name,
   so `sops.secrets."<app>/oidc_client_id"` /
   `sops.placeholder."<app>/db_password"` resolve directly.
2. In the paired NixOS branch, run
   `task secrets:publish SECRETS_DIR=<path> MSG="add <app> secrets for <host>"`.
   This pushes the branch and pins the input to its exact commit. Deploy and
   validate through the normal tasks (`task deploy:<host>`, no
   `LOCAL_SECRETS`). Any authenticated checkout of this NixOS tree then builds
   with the same secrets revision. Run publish again after further commits.
3. Merge the secrets branch into `nix-secrets` `main` first. Then run
   `task secrets:pin-main EXPECT=<commit publish printed>`, rerun validation
   against the new pin, and open the NixOS PR with that `flake.nix` +
   `flake.lock` (`git diff origin/main -- flake.lock` should touch only the
   `nix-secrets` node). Delete the temporary branch after the final pin is in
   place.

When you remove a secrets file, key or recipient, remove it only after every
configuration that reads it has migrated. The scheduled lock updater follows
`main`.

Stick to `oidc_client_id`, `oidc_client_secret`, `db_password` so existing
modules (`tandoor.nix`, `paperless-ngx.nix`) stay copy-paste templates; use
`secrets:secret` only for something beyond those.

## Operator identity

Every task that decrypts (`oidc`, `dbpw`, `secret`, `view`, `rekey`) uses the
operator identity in `~/.config/sops/age/keys.txt`. It exists only on terra and
luna, and it is a YubiKey stub (#504), so it works only while one of the two
operator tokens is plugged in. No PIN and no touch are needed, so it works fine
from an agent session. `yubikey plugin: Could not open YubiKey with serial …`
means no token is present: ask the user to plug one in. Nothing is wrong with
the key. On any other host these tasks cannot decrypt at all.

## Local checkout mode (`LOCAL_SECRETS=true`)

`LOCAL_SECRETS=true` (`--local-secrets` on the activation helper) builds from
the checkout's working tree instead of the lock, uncommitted edits included.
Use it only where a published pin cannot work:

- first-time bootstrap (`task bootstrap:*` defaults to it), including runs
  before remote input credentials are provisioned;
- disposable VMs (`task vm:install`, after `vm:sops-authorize`);
- recovery drills that need unpublished sops recipient changes.

In this mode a checkout *behind* the locked revision breaks every secret on
the target, not just the missing one. The helper's preflight compares the
checkout with the lock, but fast-forward it before you run anything.
