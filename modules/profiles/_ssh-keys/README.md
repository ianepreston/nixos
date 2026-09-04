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

Everything else here is or will be hardware-backed. `id_penguin.pub` is not, and
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

## Removing a key

Removal only takes effect on a host once that host has rebuilt. Deploy every
host and verify you can still log in *before* assuming a key is retired, and
remember that `laconia`, `behemoth`, and `blikvm` are outside NixOS management —
their `authorized_keys` must be pruned by hand.
