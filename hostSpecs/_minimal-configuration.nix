{ lib, ... }:
{
  config.hostSpecs.minimal-configuration = {
    isMinimal = lib.mkForce true;
    hostName = "installer";
  };
}
