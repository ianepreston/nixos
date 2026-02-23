{ inputs, ... }:
{
  config.hostSpecs.work = {
    hostName = inputs.nix-secrets.work_hostname;
    hostNameFile = "work";
    username = inputs.nix-secrets.work_username;
    inherit (inputs.nix-secrets) email;
    isWork = true;
    isDarwin = true;
  };
}
