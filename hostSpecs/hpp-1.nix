{ inputs, ... }:
{
  config.hostSpecs.hpp-1 = {
    hostName = "hpp-1";
    isMinimal = false;
    serverEnvironment = "dev";
    serverDomain = "dnix.ipreston.net";
    inherit (inputs.nix-secrets) email;
  };
}
