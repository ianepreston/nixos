{ inputs, ... }:
{
  config.hostSpecs.toshibachromebook = {
    hostName = "toshibachromebook";
    inherit (inputs.nix-secrets) email;
  };
}
