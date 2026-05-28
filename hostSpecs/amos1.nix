{ inputs, ... }:
{
  config.hostSpecs.amos1 = {
    hostName = "amos1";
    isMinimal = false;
    serverEnvironment = "prod";
    serverDomain = "amos.ipreston.net";
    serverLanIp = "192.168.10.11";
    iotTrunkInterface = "enp4s0";
    inherit (inputs.nix-secrets) email;
  };
}
