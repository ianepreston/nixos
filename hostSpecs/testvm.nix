{ inputs, ... }:
{
  config.hostSpecs.testvm = {
    hostName = "testvm";
    isMinimal = true;
    inherit (inputs.nix-secrets) email;
  };
}
