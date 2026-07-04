# Flake-level helper library, exported as `flake.lib.*`.
# Host modules under modules/hosts/ consume `mkNixosHost` via
# `config.flake.lib.mkNixosHost` to build their nixosConfiguration.
{
  flake.lib.mkNixosHost = import ../../lib/mkNixosHost.nix;
}
