# Read the fleet-wide authorized SSH keys out of a directory.
#
# Only `*.pub` entries count as keys. `builtins.readDir` returns every
# file, and both call sites feed the result straight into
# `openssh.authorizedKeys.keys`, so without the filter any stray file —
# a README, an editor swapfile — would be installed verbatim as an
# authorized_keys line.
#
# Shared by modules/profiles/base.nix and modules/hosts/iso.nix so the
# two can't drift: the ISO authorizes the same set for both the primary
# user and root, and a key that stops applying to one but not the other
# is a recovery-path surprise.
dir:
let
  # Every key read here is passwordless root on every host (wheel is
  # passwordless), applied unattended by the 04:40 `nixos-upgrade`
  # timer. The README next to the keys states the contract in prose —
  # "only keys that represent *you* … never a machine identity" — and
  # prose already failed once: `id_amos1.pub` was a *server's* key
  # trusted by every workstation, so compromising prod yielded a shell
  # on terra and luna, and nobody noticed by reading (#498, #500).
  #
  # A `sk-` prefix is the one machine-checkable proxy for that
  # contract: an sk credential cannot sign without a human present at a
  # token, so it structurally cannot be a machine identity. This does
  # not defend against a hostile commit — that commit could edit this
  # file too. It defends against adding a software key "just for
  # tonight" and never taking it out, which is exactly how
  # `id_amos1.pub` persisted. Closes #501.
  #
  # Failing here fails evaluation, so `nixos-rebuild` and the nightly
  # timer refuse too, not just `nix flake check`. That is the intended
  # direction: a stalled upgrade is better than the fleet silently
  # trusting a new key. `task check` catches it before push.
  #
  # Deliberate exceptions, by file name. Adding to this list is the
  # point of the check — it makes a second software key a reviewable
  # diff rather than a one-file commit that looks like nothing.
  #
  # `id_penguin.pub` is penguin's sops `ssh/ed25519`, a passphraseless
  # machine key, kept as the break-glass path into the fleet (and, via
  # modules/hosts/iso.nix, into the recovery ISO) when no YubiKey
  # works. penguin cannot hold one: ChromeOS does not pass FIDO2 into
  # Crostini. So what this check actually asserts is not "the fleet is
  # hardware-only" but "there is exactly one software key and it is
  # this one". See the README's exception section for the full cost.
  softwareKeyExceptions = [ "id_penguin.pub" ];

  names = builtins.filter (name: builtins.match ".*\\.pub" name != null) (
    builtins.attrNames (builtins.readDir dir)
  );

  isHardwareBacked = name: builtins.substring 0 3 (builtins.readFile (dir + "/${name}")) == "sk-";

  offenders = builtins.filter (
    name: !(isHardwareBacked name || builtins.elem name softwareKeyExceptions)
  ) names;
in
# Checked here rather than per-key inside the `map` so that the throw is
# forced as soon as anything looks at the list at all. A throw buried in
# a lazy list element only surfaces when that element is forced — which
# is deep inside building the authorized_keys file, long after
# `nix flake check` has had its chance to say so.
if offenders != [ ] then
  throw ''
    Not hardware-backed: ${builtins.concatStringsSep ", " offenders} in ${toString dir}

    Every *.pub in this directory is an authorized key for the primary
    user on every host — and for root on the recovery ISO — with
    passwordless sudo, so it must be an `sk-ssh-ed25519@openssh.com` /
    `sk-ecdsa-sha2-nistp256@openssh.com` key held on a token you carry.
    Never a machine identity: a host's key lives in nix-secrets and its
    only consumer is GitHub, as a read-only nix-secrets deploy key.

    If this really is a deliberate exception, add it to
    `softwareKeyExceptions` in lib/fleetSshKeys.nix and document why in
    modules/profiles/_ssh-keys/README.md. Do not widen the check.
  ''
else
  map (name: builtins.readFile (dir + "/${name}")) names
