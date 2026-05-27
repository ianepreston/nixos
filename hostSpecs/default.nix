# Add your reusable common modules to this directory, on their own file (https://wiki.nixos.org/wiki/NixOS_modules).
# These are modules not specific to either nixos, darwin, or home-manger that you would share with others, not your personal configurations.

_: {
  imports = [
    ./host-spec.nix
    ./amos1.nix
    ./iso.nix
    ./luna.nix
    ./minimal-configuration.nix
    ./penguin.nix
    ./terra.nix
    ./tests-desktop.nix
    ./tests-server.nix
    ./hpp-1.nix
    ./toshibachromebook.nix
    ./work.nix
    ./xps13.nix
  ];
}
