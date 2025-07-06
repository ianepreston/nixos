{ inputs, ... }:
{
  config.hostSpecs.wsl = {
    hostName = "wsl";
    inherit (inputs.nix-secrets) email;
  };
}
