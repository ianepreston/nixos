{ inputs, ... }:
{
  config.hostSpecs.workwsl = {
    hostName = "N0021-739";
    inherit (inputs.nix-secrets) email;
  };
}
