# Host specifications aggregate root.
#
# Auto-discovers every `hostSpecs/<host>.nix` so adding a host is a single
# file drop — no bookkeeping edit here. This mirrors how `flake.nix` scans
# `modules/` with `import-tree`, and reuses the same leading-underscore
# "skip this file" convention as `modules/hosts/_rollback-root.nix`.
#
# Non-host infra files are underscore-prefixed and imported explicitly so
# they stay in effect while being excluded from the scan:
#   - `_host-spec.nix`             the hostSpec option schema (types/defaults)
#   - `_minimal-configuration.nix` the installer's `minimal-configuration` spec
# Dropping either from the imports would silently loosen type validation and
# defaults, so they stay explicit — auto-discovery deliberately skips any
# `_`-prefixed file (and `default.nix` itself, to avoid self-recursion).
{ lib, ... }:
let
  isHostSpecFile =
    path:
    let
      name = baseNameOf path;
    in
    lib.hasSuffix ".nix" name && name != "default.nix" && !(lib.hasPrefix "_" name);
  autoDiscovered = builtins.filter isHostSpecFile (lib.filesystem.listFilesRecursive ./.);
in
{
  imports = [
    ./_host-spec.nix
    ./_minimal-configuration.nix
  ]
  ++ autoDiscovered;
}
