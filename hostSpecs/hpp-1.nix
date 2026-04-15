{ inputs, ... }:
{
  config.hostSpecs.hpp-1 = {
    hostName = "hpp-1";
    isMinimal = false;
    inherit (inputs.nix-secrets) email;
  };
}
