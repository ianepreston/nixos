# Moonshine - Simple Aspect
# Game streaming server for Moonlight clients.
#
# Moonshine runs each stream in its own headless compositor,
# so nothing about the host's displays is load-bearing, and the streamed app
# gets a session of its own rather than sharing the desktop's.
{ inputs, ... }:
{
  flake.modules.nixos.moonshine =
    { hostSpec, pkgs, ... }:
    {
      imports = [ inputs.moonshine.nixosModules.default ];

      services.moonshine = {
        enable = true;
        user = hostSpec.username;
        # The user's uid is allocated, not declared (base.nix doesn't pin
        # one), so the module can't derive it from users.users.<user>.uid.
        # 1000 is what the first normal user gets.
        uid = 1000;
        openFirewall = true;
        settings = {
          application = [
            {
              title = "Steam Big Picture";
              command = [
                "/run/current-system/sw/bin/steam"
                "steam://open/bigpicture"
              ];
              # NOT a launch deadline — it is a mandatory dwell. After the
              # systemd start job returns, moonshine watches the transient
              # unit for `launch_timeout_secs` and only reports failure if the
              # unit goes inactive/failed in that window; if nothing happens it
              # sleeps the whole duration and *then* reports success
              # (moonshine-core/src/session/application.rs, the
              # `Err(_) => Ok(path)` arm). Meanwhile the Moonlight client's
              # /launch request is capped by the hardcoded
              # APP_LAUNCH_HTTP_TIMEOUT_SECS = 60. So a value at or above 60
              # makes *every* launch fail at exactly 60s, no matter what the
              # app does — which is what 90 did here. Keep it well under 60;
              # it only needs to be long enough to catch a Steam that bails
              # out immediately.
              #
              # The pre_command shares this 60s budget. ExecStartPre has its
              # own hardcoded bound (START_JOB_TIMEOUT = 90s) that upstream
              # decoupled from this value, but the start job and this dwell
              # both run inside the single `launch_session()` future the
              # webserver wraps in APP_LAUNCH_HTTP_TIMEOUT_SECS
              # (moonshine-core/src/webserver/mod.rs) — so 60s is the ceiling
              # that actually binds, not 90s, and the pre_command below is
              # sized against what's left of it.
              launch_timeout_secs = 10;
              # Steam is single-instance per user: with a desktop Steam
              # already running, the steam:// URL is handed to *that*
              # process, Big Picture opens on the physical desktop, and the
              # stream session dies with a 503. Ask the running one to shut
              # down first and wait for it. Upstream's recommended
              # workaround (moonshine issue #134, TIPS.md).
              #
              # Asking is not enough on its own, so escalate: a Steam wedged
              # on a depot download ignores `-shutdown` outright and only
              # died ~128s later by segfaulting (#649). The old
              # ask-and-wait-30s loop ran to exhaustion and then launched
              # into the still-live instance — exactly the failure the guard
              # exists to prevent. Raising the bound can't fix that: the
              # whole thing has to fit the ~48s left of the 60s launch budget
              # after the dwell above, and no wait that fits is long enough
              # for a Steam that never intends to exit. SIGTERM then SIGKILL
              # is what makes the guard a guarantee rather than a request.
              # 20/10/2 is worst case ~32s, leaving ~16s of margin; a settled
              # Steam answers `-shutdown` in ~3s and never reaches SIGTERM.
              pre_command = [
                [
                  "${pkgs.bash}/bin/bash"
                  "-c"
                  ''
                    if ${pkgs.procps}/bin/pgrep -x steam >/dev/null; then
                      /run/current-system/sw/bin/steam -shutdown &>/dev/null || true
                      for _ in $(seq 1 20); do
                        ${pkgs.procps}/bin/pgrep -x steam >/dev/null || break
                        sleep 1
                      done
                      if ${pkgs.procps}/bin/pgrep -x steam >/dev/null; then
                        ${pkgs.procps}/bin/pkill -x steam || true
                        for _ in $(seq 1 10); do
                          ${pkgs.procps}/bin/pgrep -x steam >/dev/null || break
                          sleep 1
                        done
                        ${pkgs.procps}/bin/pkill -KILL -x steam || true
                        sleep 2
                      fi
                    fi
                  ''
                ]
              ];
            }
            # A full-desktop "Remote Desktop" tile alongside this one is
            # blocked on GNOME, not on moonshine: gnome-shell 50 always runs
            # as a Wayland display server and takes logind control, so it
            # cannot nest inside a stream's compositor while the seat session
            # holds that control. Needs a nesting-capable compositor to
            # revisit — see #439.
          ];
        };
      };

      # `moonshine` is what the package's polkit rule is scoped to; without it
      # moonshine can't hold a logind sleep inhibitor and the host can suspend
      # mid-stream. `input` is what lets a streamed game read the virtual
      # gamepads moonshine creates when there is no active desktop session —
      # with a session logged in, uaccess ACLs cover it, but streaming to a
      # dark/logged-out host is exactly the case this module exists for.
      users.users.${hostSpec.username}.extraGroups = [
        "moonshine"
        "input"
        # `hardware.uinput.enable` ships 99-local.rules, which sorts after
        # moonshine's own 60-moonshine.rules and resets /dev/uinput to
        # root:uinput 0660 — so the GROUP="input" the moonshine rule asks for
        # never survives. With a desktop session logged in the uaccess ACL
        # hides this; streaming to a logged-out host (the case this module
        # exists for) has no ACL and the input handler fails to open
        # /dev/uinput. Being in the node's actual group is what covers it.
        "uinput"
      ];

      home-manager.sharedModules = [
        inputs.self.modules.homeManager.moonshine
      ];
    };

  # GNOME-specific: never suspend on idle. Screen blanking no longer matters
  # (moonshine doesn't capture the desktop's output), but a suspended host
  # can't answer a Moonlight client at all.
  flake.modules.homeManager.moonshine = _: {
    dconf.settings = {
      "org/gnome/settings-daemon/plugins/power" = {
        sleep-inactive-ac-type = "nothing";
        sleep-inactive-ac-timeout = 0;
      };
    };
  };
}
