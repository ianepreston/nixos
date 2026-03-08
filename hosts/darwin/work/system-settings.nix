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

    # Hot corners: upper-left triggers Mission Control (workspace overview)
    # corner values: 0=disabled, 2=Mission Control, 4=Desktop, 5=Screen Saver
    # modifier values: 0=none, 131072=shift, 262144=ctrl, 524288=opt, 1048576=cmd
    CustomUserPreferences."com.apple.dock" = {
      wvous-tl-corner = 2; # top-left → Mission Control
      wvous-tl-modifier = 0; # no modifier required

      # Speed up Mission Control / space-switch animation
      expose-animation-duration = "0.1";
    };

  };
}
