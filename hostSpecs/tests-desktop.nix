{ inputs, ... }:
{
  config.hostSpecs.tests-desktop = {
    hostName = "tests-desktop";
    isMinimal = true;
    inherit (inputs.nix-secrets) email;
  };
}
