# Add your reusable common modules to this directory, on their own file (https://wiki.nixos.org/wiki/NixOS_modules).
# These are modules not specific to either nixos, darwin, or home-manger that you would share with others, not your personal configurations.

_: {
  imports = [
    ./host-spec.nix
    ./iso.nix
    ./luna.nix
    ./minimal-configuration.nix
    ./penguin.nix
    ./terra.nix
    ./testvm.nix
    ./d-nix-1.nix
    ./hpp-1.nix
    ./toshibachromebook.nix
    ./work.nix
  ];
}
