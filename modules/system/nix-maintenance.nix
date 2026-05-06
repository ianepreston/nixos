# Nix maintenance - Simple Aspect
# Periodic store garbage collection + automatic store optimisation
_: {
  flake.modules.nixos.nix-maintenance = _: {
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
      persistent = true;
    };

    nix.optimise.automatic = true;
  };
}
