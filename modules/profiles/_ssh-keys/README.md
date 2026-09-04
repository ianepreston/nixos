# `_ssh-keys/` — human login keys only

Every `*.pub` in this directory is installed as an authorized key for the
primary user on **every** host (`modules/profiles/base.nix`), and for both the
primary user *and root* on the recovery ISO (`modules/hosts/iso.nix`). Combined
with `security.sudo.wheelNeedsPassword = false`, that makes any private key
whose public half lives here **passwordless root across the whole fleet**.

So the contract is narrow:

> Only keys that represent *you*, held on a machine you interactively log in
> from. Never a machine identity.

## Not machine keys

Each host has its own `ssh/ed25519` in `nix-secrets`, rendered to
`/run/secrets/ssh/ed25519`, used by `nixos-upgrade` to fetch the private
`nix-secrets` flake input from GitHub. That is a *machine* identity — it does
not belong here.

Its consumer is GitHub, as a **read-only deploy key on `ianepreston/nix-secrets`**,
titled by hostname. That scoping is the point: a host needs read access to one
repo, and a deploy key gives exactly that, with per-host revocation. List them
with `gh repo deploy-key list --repo ianepreston/nix-secrets`.

This was not always so. Until #543 every host key was an *account-level* SSH key
on the `ianepreston` account — read-write on every repo the account can reach —
so popping any host yielded write access to all source. Account keys are now
exactly the two YubiKeys plus one work laptop; no machine key is among them.

Two consequences worth keeping straight:

- Removing a `.pub` from this directory does **not** retire that key. It ends
  fleet *login* only; the key stays live as a machine identity on GitHub until
  its deploy key is deleted too.
- Conversely, deleting a host's deploy key does not de-authorize it for login.
  The two halves are now genuinely independent, which is the whole point of the
  split: **sops `ssh/ed25519` is machine identity for GitHub; this directory is
  human identity for login; the two never mix.**

`task bootstrap:secrets` used to write each new host's machine key into this
directory automatically, which is how `id_amos1.pub` — a **server's** key —
came to be trusted by every workstation, handing anyone who compromised prod an
SSH session on `terra` and `luna`. That behaviour was removed in #498; the task
now prints the key instead.

A machine pubkey is never lost by not being committed here. Recover it with
either of:

```sh
cd ../nix-secrets && sops -d --extract '["ssh"]["ed25519"]' sops/<host>.yaml \
  | ssh-keygen -y -f /dev/stdin

ssh ipreston@<host> 'sudo ssh-keygen -y -f /run/secrets/ssh/ed25519'
```

## Adding a key

Drop the `.pub` in and deploy. Non-`.pub` files (this README included) are
ignored by `lib/fleetSshKeys.nix`, which is what both call sites use.

Prefer hardware-backed keys (`sk-ssh-ed25519@openssh.com`). The fleet is
migrating to hardware-only — see #499 for enrolment and #501 for the check that
will eventually reject anything else.

## `id_penguin.pub` is a deliberate exception

Everything else here is now hardware-backed — the last software key,
`id_terra.pub`, went with wave 3 of #500. `id_penguin.pub` is the exception, and
is **kept on purpose** as the break-glass path into the fleet when no YubiKey
works. Because `modules/hosts/iso.nix` authorizes this same directory for both
`ipreston` and root, keeping it also keeps a non-sk way into the recovery ISO.

penguin cannot hold a hardware key: ChromeOS does not pass FIDO2 into Crostini.
`vmc key-attach` is U2F/FIDO1 only, and `vmc usb-attach` hands over the PIV/CCID
applet rather than the hidraw FIDO2 interface — while taking an exclusive lock
that stops the browser using the key for WebAuthn. `fido2-token -L` returns
nothing inside the container.

Be clear about what the exception costs: `id_penguin.pub` is penguin's sops
`ssh/ed25519`, a passphraseless machine key, and by the rules at the top of this
file that makes it passwordless root fleet-wide — the exact property this
migration removes everywhere else. It is an accepted trade for a recovery path,
not drift, and #501's `sk-`-only check carries it as a named exception.

## The private half of a hardware key

`id_ed25519_sk_1.pub` / `id_ed25519_sk_2.pub` are the two enrolled
YubiKeys. Their private counterparts are *stub* files — a credential
handle plus the public half, inert without the physical token — and both
credentials are **resident**, so a token can always re-emit its own stub
with `ssh-keygen -K` (which writes into `$PWD`, and names both
`id_ed25519_sk_rk` because they share the default `ssh:` application
string, so rename between downloads).

To save doing that on every machine, the stubs are distributed like any
other user secret: stored at `ssh/ed25519_sk_{1,2}` in `shared.yaml` and
rendered to `~/.ssh/` by `modules/hardware/yubikey.nix`, which also names
them in `IdentityFile`. They are not committed here — this directory is
pubkeys-only.

Never re-run `ssh-keygen -t ed25519-sk` against a token that is already
enrolled. That mints a *new* credential with a *new* public key, which
then has to be added here and rebuilt fleet-wide. Enrolment happens once
per token.

## If you lose both YubiKeys

With the fleet on hardware-only keys, losing both tokens means no remote SSH to
any NixOS host. That is not a total lockout — there are three ways back in,
listed in the order you would reach for them:

1. **`id_penguin.pub`.** Still authorized fleet-wide and on the recovery ISO,
   for exactly this. See the section above.
2. **Console password login.** `modules/profiles/base.nix` sets
   `hashedPasswordFile` from sops for the primary user, so the account has a
   real password. `modules/system/ssh.nix` sets
   `services.openssh.settings.PasswordAuthentication = false` fleet-wide, so
   that password works **at a physical console only** and is never accepted
   over SSH — which is what makes it safe to keep as a last resort. Needs
   physical (or blikvm) access to the machine.
3. **blikvm**, for the hosts it is wired to — out-of-band keyboard/video, so it
   reaches the console (and the bootloader) without SSH at all. It authenticates
   with its own password and its web UI, not with any key in this directory, so
   nothing in this migration can lock you out of it. See the non-NixOS hosts
   section below.

Route 2 has never been exercised end to end — it depends only on the sops
password secret and console access, both independent of SSH, but treat it as
documented rather than tested.

Enrolling a replacement token is not a recovery path: `ssh-keygen -t ed25519-sk`
mints a *new* credential with a new public key, which has to be added here and
rebuilt fleet-wide before it authorizes anything. You need one of the three
routes above to do that.

## Removing a key

Removal only takes effect on a host once that host has rebuilt. Deploy every
host and verify you can still log in *before* assuming a key is retired, and
remember that `laconia`, `behemoth`, and `blikvm` are outside NixOS management —
their `authorized_keys` must be pruned by hand.

## The three hosts outside NixOS management

No deploy reaches these, so their key sets are maintained by hand. State as of
2026-09-03, after the wave-2 prune:

| Host | Authorized | Notes |
|---|---|---|
| `laconia` | both sk keys only | Synology DSM. Ahead of the fleet — no software key at all, so SSH is hardware-only here. DSM's own web UI and the physical console remain the fallback. |
| `behemoth` | both sk keys, plus `ipreston@laconia` | FreeBSD. See below. |
| `blikvm` | — | Accepts no pubkey from this fleet under any of `root` / `blikvm` / `admin` / `pi`; sshd offers password auth. Its break-glass is a password and its web UI, so this migration does not affect it and there is nothing here to prune. |

### Why `behemoth` trusts a `laconia` key

`ipreston@laconia` (`SHA256:EzfGYes0zXIe2MlSYSyH5GCoNqX1Le3hYFWle19qRVs`) is a
**deliberate machine-to-machine credential**: laconia runs scheduled tasks that
ssh into behemoth to retrieve ACME certificates.

It looks exactly like the thing this migration removes — a machine identity
trusted as a login credential — so it is called out here specifically to stop a
future audit deleting it. The distinction that makes it fine: it authorizes one
known automated job between two hosts, not a human login trusted fleet-wide, and
neither host is in `_ssh-keys/`'s blast radius.
