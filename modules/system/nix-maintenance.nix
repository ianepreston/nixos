# Nix maintenance - Simple Aspect
# Periodic store garbage collection + automatic store optimisation,
# plus an interactive-session nofile bump so `sudo nixos-rebuild` and
# other client-side nix invocations don't EMFILE during parallel
# substitution of large closures.
_: {
  flake.modules.nixos.nix-maintenance = _: {
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
      persistent = true;
    };

    nix.optimise.automatic = true;

    # The nix-daemon already runs with LimitNOFILE=1048576, but the
    # client-side `nix build` invocation inherits the calling user's
    # interactive limits (default 1024). Bump for all login sessions
    # so `task bootstrap:rebuild` / on-host rebuilds don't trip the
    # soft limit while listing /nix/store under load.
    security.pam.loginLimits = [
      {
        domain = "*";
        type = "soft";
        item = "nofile";
        value = "65536";
      }
      {
        domain = "*";
        type = "hard";
        item = "nofile";
        value = "1048576";
      }
    ];
  };
}
