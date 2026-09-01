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
`nix-secrets` flake input from GitHub. That is a *machine* identity. Its only
consumer is GitHub, as a deploy key — it does not belong here.

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
