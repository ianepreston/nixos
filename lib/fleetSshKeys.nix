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
map (name: builtins.readFile (dir + "/${name}")) (
  builtins.filter (name: builtins.match ".*\\.pub" name != null) (
    builtins.attrNames (builtins.readDir dir)
  )
)
