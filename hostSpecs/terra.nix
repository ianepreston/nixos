{ inputs, ... }:
{
  config.hostSpecs.terra = {
    hostName = "terra";
    inherit (inputs.nix-secrets) email;
  };
}
