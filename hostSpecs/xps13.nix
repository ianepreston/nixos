{ inputs, ... }:
{
  config.hostSpecs.xps13 = {
    hostName = "xps13";
    inherit (inputs.nix-secrets) email;
  };
}
