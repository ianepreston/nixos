{ inputs, ... }:
{
  config.hostSpecs.d-nix-1 = {
    hostName = "d-nix-1";
    isMinimal = false;
    inherit (inputs.nix-secrets) email;
  };
}
