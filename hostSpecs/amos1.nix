{ inputs, ... }:
{
  config.hostSpecs.amos1 = {
    hostName = "amos1";
    isMinimal = false;
    serverEnvironment = "prod";
    serverDomain = "amos.ipreston.net";
    serverLanIp = "192.168.10.11";
    iotTrunkInterface = "enp4s0";
    # bambuddy Virtual Printer is dormant (blocked upstream — see #298), so its
    # pinned macvlan MAC/IP are omitted to keep `iot-static` from being created
    # with no consumer. Restore when re-enabling bambuddy:
    #   bambuddyVpMac = "3a:3c:3e:21:8f:55";   # router: -> bambuddy-guest
    #   bambuddyVpIp  = "192.168.30.64";
    inherit (inputs.nix-secrets) email;
  };
}
