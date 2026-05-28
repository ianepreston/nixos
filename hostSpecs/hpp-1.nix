{ inputs, ... }:
{
  config.hostSpecs.hpp-1 = {
    hostName = "hpp-1";
    isMinimal = false;
    serverEnvironment = "dev";
    serverDomain = "dnix.ipreston.net";
    serverLanIp = "192.168.10.10";
    iotTrunkInterface = "enp1s0";
    inherit (inputs.nix-secrets) email;
  };
}
