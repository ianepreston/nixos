# Omnigent desktop - HM Simple Aspect
# Electron client for an Omnigent server, from the omnigent-nix flake. Installing
# it does not make the machine a host: `programs.omnigent.host` stays off and
# nothing is started. Linux only (the flake builds no macOS bundle).
{ inputs, ... }:
{
  flake.modules.homeManager.omnigent = {
    imports = [ inputs.omnigent.homeManagerModules.omnigent ];

    programs.omnigent = {
      desktop.enable = true;
      host.autoStart = false;
    };
  };
}
