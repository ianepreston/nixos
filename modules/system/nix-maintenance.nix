# Nix maintenance - Simple Aspect
# Periodic store garbage collection + automatic store optimisation,
# plus an interactive-session nofile bump so `sudo nixos-rebuild` and
# other client-side nix invocations don't EMFILE during parallel
# substitution of large closures.
_: {
  flake.modules.nixos.nix-maintenance = _: {
    # Keep four weeks of generations so a subtly-broken auto-upgrade
    # (e.g. an app's HTTP listener regressed but the unit still starts)
    # has rollback targets even if it goes unnoticed past the weekly
    # auto-rebuild cadence. ~1-2 GiB extra in /nix/store is trivial vs.
    # losing every known-good generation. See issue #134.
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
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
