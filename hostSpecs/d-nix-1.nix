{ inputs, ... }:
{
  config.hostSpecs.d-nix-1 = {
    hostName = "d-nix-1";
    isMinimal = false;
    serverEnvironment = "dev";
    inherit (inputs.nix-secrets) email;
  };
}
