# Moonshine - Simple Aspect
# Game streaming server for Moonlight clients.
#
# Replaces sunshine on terra (issue #119). Sunshine captures whatever the
# session compositor is scanning out, which made every stream hostage to the
# physical monitor: powered off, asleep, or unplugged and there is no CRTC to
# capture. Moonshine instead runs each stream in its own headless compositor,
# so nothing about the host's displays is load-bearing, and the streamed app
# gets a session of its own rather than sharing the desktop's. That second
# property is what fixes the Big Picture tile: under sunshine the steam://
# URI was handed to the desktop's Steam, so the stream came up showing the
# desktop and BPM never appeared on it (#119, requirement 3).
{ inputs, ... }:
{
  flake.modules.nixos.moonshine =
    {
      hostSpec,
      pkgs,
      ...
    }:
    let
      # The user's uid is allocated, not declared (base.nix doesn't pin one),
      # so the module can't derive it from users.users.<user>.uid. 1000 is what
      # the first normal user gets.
      uid = 1000;

      # Status of the "Remote Desktop" tile: not working yet. Full evidence
      # in #456; the load-bearing facts are:
      #
      # Moonshine gives an application 60s to report a successful launch before
      # returning 503 to the client. That bound is the hardcoded constant
      # APP_LAUNCH_HTTP_TIMEOUT_SECS in moonshine-core/src/session/mod.rs; the
      # `launch_timeout_secs` option below is a different budget (the systemd
      # start job) and cannot raise it.
      #
      # Moonshine's compositor implements compositor (v6), shm, dmabuf, output,
      # seat, xdg shell (xdg_wm_base v7), viewporter, presentation,
      # pointer_constraints, relative_pointer, data_device and xwayland_shell —
      # and nothing else. Per-compositor consequences:
      #
      #   GNOME    — cannot nest. gnome-shell 50 always runs as a Wayland
      #              display server and takes logind control (#439).
      #   Plasma   — kwin's Wayland backend requires
      #              wp_single_pixel_buffer_manager_v1, which moonshine does not
      #              implement, so kwin exits immediately and plasma_session
      #              restart-loops it.
      #   Hyprland — nests as far as dmabuf negotiation, then produces no output
      #              inside the 60s bound.
      #   COSMIC   — cosmic-comp nests successfully; cosmic-session's component
      #              startup is what fails.
      #
      # Do not use sway as a stand-in host when testing this: it advertises
      # xdg_wm_base v5, and both cosmic-comp and aquamarine require v6, so
      # nesting under sway fails for a reason that does not apply to moonshine.
      #
      # start-cosmic runs dbus-run-session itself when DBUS_SESSION_BUS_ADDRESS
      # is unset. Under moonshine's user unit it is inherited as
      # /run/user/<uid>/bus, so do not wrap this in another dbus-run-session:
      # that yields a private bus with no org.freedesktop.systemd1 on it and
      # every StartTransientUnit call cosmic-session makes then fails.
      cosmicLaunch = pkgs.writeShellScript "moonshine-cosmic-launch" ''
        set -eu
        export XDG_SESSION_TYPE=wayland
        export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/${toString uid}}"
        exec /run/current-system/sw/bin/start-cosmic
      '';

      # cosmic-session registers components as scopes/units in the *user*
      # systemd manager, which is shared with the physical seat's session, and
      # they can outlive the stream. Moonshine reuses one unit name,
      # moonshine-session.service, for every stream and allows its Stop job 2s,
      # so a leftover — an orphaned cosmic-greeter.scope, active with no
      # processes left in it, is enough — fails the *next* launch of any tile
      # with "UnitExists", Steam Big Picture included. Reap them when the
      # stream ends.
      #
      # Units only, no pkill: a COSMIC session on the physical seat would share
      # these process names.
      cosmicCleanup = pkgs.writeShellScript "moonshine-cosmic-cleanup" ''
        units="cosmic-*.scope cosmic-*.service"
        # shellcheck disable=SC2086 # deliberate glob expansion by systemctl
        ${pkgs.systemd}/bin/systemctl --user stop $units 2>/dev/null || true
        # shellcheck disable=SC2086
        ${pkgs.systemd}/bin/systemctl --user reset-failed $units 2>/dev/null || true
      '';
    in
    {
      imports = [ inputs.moonshine.nixosModules.default ];

      services.moonshine = {
        enable = true;
        user = hostSpec.username;
        inherit uid;
        openFirewall = true;
        settings = {
          application = [
            {
              title = "Steam Big Picture";
              command = [
                "/run/current-system/sw/bin/steam"
                "steam://open/bigpicture"
              ];
              # `pre_command` below is wired up as ExecStartPre on the
              # transient moonshine-session.service, and moonshine gives the
              # whole systemd start job only `launch_timeout_secs` to finish.
              # At the default of 2 that budget is smaller than the shutdown
              # wait the pre_command itself performs, so any launch that finds
              # Steam running is killed mid-wait (SIGTERM to the control
              # process) and the session fails. Must stay comfortably above
              # the ~30s worst case below plus Steam's own exec time — an
              # observed cold launch that did hit the shutdown wait took
              # 45.03s end to end, so anything near 45 has no margin at all.
              launch_timeout_secs = 90;
              # Steam is single-instance per user: with a desktop Steam
              # already running, the steam:// URL is handed to *that*
              # process, Big Picture opens on the physical desktop, and the
              # stream session dies with a 503. Ask the running one to shut
              # down first and wait for it. Upstream's recommended
              # workaround (moonshine issue #134, TIPS.md).
              pre_command = [
                [
                  "${pkgs.bash}/bin/bash"
                  "-c"
                  ''
                    if ${pkgs.procps}/bin/pgrep -x steam >/dev/null; then
                      /run/current-system/sw/bin/steam -shutdown &>/dev/null
                      for _ in $(seq 1 30); do
                        ${pkgs.procps}/bin/pgrep -x steam >/dev/null || break
                        sleep 1
                      done
                    fi
                  ''
                ]
              ];
            }
            {
              # A full desktop, not a mirror of the physical monitor —
              # moonshine has no mirroring mechanism, so this is a second
              # independent session booted inside the stream's headless
              # compositor. See the compositor notes above; this tile does not
              # work yet, it is checked in as the current state of #439 / #456.
              title = "Remote Desktop";
              command = [ "${cosmicLaunch}" ];
              post_command = [ [ "${cosmicCleanup}" ] ];
              # Only bounds the systemd start job. The client-facing bound is
              # moonshine's hardcoded 60s, which is what this tile currently
              # exceeds.
              launch_timeout_secs = 180;
            }
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
