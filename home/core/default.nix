{ hostSpec, ... }:
{
  imports = [
    ./direnv.nix
    ./git.nix
    ./starship.nix
    ./zsh.nix
  ];
  inherit hostSpec;
  service.ssh-agent.enable = true;
}
