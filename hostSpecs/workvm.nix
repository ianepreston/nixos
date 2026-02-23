{ inputs, ... }:
{
  config.hostSpecs.workvm = {
    hostName = inputs.nix-secrets.workvm_hostname;
    hostNameFile = "workvm";
    username = inputs.nix-secrets.workvm_username;
    inherit (inputs.nix-secrets) email;
    isWork = true;
    isDarwin = true;
  };
}
