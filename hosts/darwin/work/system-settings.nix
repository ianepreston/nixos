# macOS system settings for keyboard-driven workflow.
#
# AeroSpace handles workspace switching (virtual workspaces, no macOS Spaces).
# Hammerspoon handles window snapping and app launching.
{ ... }:
{
  system.defaults = {
    NSGlobalDomain = {
      # Fast key repeat — essential for comfortable hjkl navigation
      KeyRepeat = 2; # ~30ms repeat interval
      InitialKeyRepeat = 15; # ~225ms before repeat starts
      ApplePressAndHoldEnabled = false; # disable accented char picker on hold

      # Reduce window open/close animations for snappier feel
      NSAutomaticWindowAnimationsEnabled = false;
    };

    # Hot corners disabled — Mission Control doesn't work well with AeroSpace's
    # virtual workspaces (windows appear tiny and scattered). Use alt+tab for
    # window overview, alt+h/l for workspace switching.
    # corner values: 0=disabled, 2=Mission Control, 4=Desktop, 5=Screen Saver
    CustomUserPreferences."com.apple.dock" = {
      wvous-tl-corner = 0; # disabled
      wvous-tl-modifier = 0;

      # Speed up Mission Control / space-switch animation (if triggered manually)
      expose-animation-duration = "0.1";
    };

    # Dock — left side to save vertical space on wide monitor, half default size
    dock = {
      orientation = "left";
      tilesize = 64; # default is 64
      autohide = true;
      minimize-to-application = true; # keep dock tidy
      show-recents = false; # hide recent apps section
    };

  };
}
