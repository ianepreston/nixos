{ inputs, ... }:
{
  config.hostSpecs.workvm = {
    hostName = "DLFMLDS01";
    username = "e975360@WCB.AB.CA";
    home = "/home/e975360@WCB.AB.CA";
    inherit (inputs.nix-secrets) email;
  };
}
