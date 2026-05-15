# Sunshine - Simple Aspect
# Game streaming server
{ inputs, ... }:
{
  flake.modules.nixos.sunshine =
    { pkgs, ... }:
    {
      services.sunshine = {
        enable = true;
        capSysAdmin = true;
        openFirewall = true;
        applications = {
          env.PATH = "$(PATH):$(HOME)/.local/bin";
          apps = [
            {
              name = "Desktop";
              image-path = "desktop.png";
            }
            {
              # `steam -bigpicture` (the CLI flag) launches BPM directly,
              # unlike the `steam://open/bigpicture` URL handler the upstream
              # default uses — which silently no-ops if steam wasn't already
              # running and the URI dispatch lost the race. Detached so
              # sunshine streams the desktop independently of steam's
              # lifetime; gamescope wrapping is unworkable nested in
              # mutter+NVIDIA today (see issue #117).
              name = "Steam Big Picture";
              detached = [ "steam -bigpicture" ];
              image-path = "steam.png";
            }
          ];
        };
      };
      environment.systemPackages = with pkgs; [
        gnomeExtensions.sunshinestatus
      ];

      # Keep the session's primary CRTC live so sunshine can capture it even
      # when the physical monitor is off. Idle-blank would tear it down on
      # mutter+NVIDIA and leave moonlight clients staring at a black frame.
      home-manager.sharedModules = [
        inputs.self.modules.homeManager.sunshine
      ];
    };

  # GNOME-specific: disable idle blanking and screen-off-on-AC so the
  # rendering pipeline keeps running while nobody's at the desk. On a non-
  # GNOME desktop these keys are simply ignored.
  flake.modules.homeManager.sunshine =
    { lib, ... }:
    with lib.hm.gvariant;
    {
      dconf.settings = {
        "org/gnome/desktop/session" = {
          idle-delay = mkUint32 0;
        };
        "org/gnome/settings-daemon/plugins/power" = {
          sleep-inactive-ac-type = "nothing";
          sleep-inactive-ac-timeout = 0;
          idle-dim = false;
        };
      };
    };
}
