{ inputs, ... }:
{
  config.hostSpecs.testvm = {
    hostName = "testvm";
    inherit (inputs.nix-secrets) email;
  };
}
