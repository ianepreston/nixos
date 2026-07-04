# mkNixosHost — the single constructor every host in modules/hosts/ goes
# through to build its `nixosConfiguration`.
#
# The point of the helper is to make `networking.hostName` a *derived*
# value rather than a per-host string literal. Previously each host module
# hardcoded `networking.hostName = "<host>"` inline, duplicating a value
# that already lives (authoritatively) in `hostSpecs/<host>.nix` as
# `hostSpec.hostName`. Two copies of the same fact is a drift footgun — a
# rename in one place silently disagrees with the other. Here we source it
# once, from the hostSpec, so the literal exists in exactly one place.
#
# Everything else (specialArgs, system, the host's own module list) is
# passed straight through unchanged, so this is a pure authoring-site
# refactor: the evaluated config surface is identical to the old inline form.
{
  inputs,
  hostSpec,
  system ? "x86_64-linux",
  extraModules ? [ ],
}:
inputs.nixpkgs.lib.nixosSystem {
  inherit system;
  specialArgs = {
    inherit inputs hostSpec;
  };
  modules = extraModules ++ [
    # Single-sourced from hostSpec — see the header comment.
    { networking.hostName = hostSpec.hostName; }
  ];
}
