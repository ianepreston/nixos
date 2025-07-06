{ inputs, ... }:
{
  config.hostSpecs.luna = {
    hostName = "luna";
    inherit (inputs.nix-secrets) email;
    isMobile = true;
  };
}
