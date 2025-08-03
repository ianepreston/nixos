{ inputs, ... }:
{
  config.hostSpecs.iso = {
    hostName = "iso";

    # Needed because we don't use hosts/common/core for iso
    inherit (inputs.nix-secrets) email;
  };
}
