# macOS system settings for keyboard-driven workflow with AeroSpace.
#
# Scope is intentionally narrow: fast key repeat, and disabling exactly two
# system shortcuts that conflict with AeroSpace bindings. Everything else is
# left at macOS defaults.
{ ... }:
{
  system.defaults = {
    NSGlobalDomain = {
      # Fast key repeat — essential for comfortable hjkl navigation
      KeyRepeat = 2; # ~30ms repeat interval
      InitialKeyRepeat = 15; # ~225ms before repeat starts
      ApplePressAndHoldEnabled = false; # disable accented char picker on hold
    };

    CustomUserPreferences = {
      # Unified URL-bar shortcut: ctrl+l on both Mac (Chrome) and NixOS (Firefox).
      # cmd+l is taken by AeroSpace for focus-right, so we remap Chrome's
      # "Open Location..." menu item to ctrl+l here.
      # (^ = ctrl in NSUserKeyEquivalents notation)
      "com.google.Chrome" = {
        NSUserKeyEquivalents = {
          "Open Location..." = "^l";
        };
      };

      # Disable the macOS system shortcut that conflicts with AeroSpace.
      #
      # Symbolic hotkey ID:
      #   12 = Hide application (cmd+h) — AeroSpace focus-left takes this slot
      #
      # cmd+space (Spotlight, ID 64) is left enabled — Spotlight is used for
      # app launching.
      #
      # IMPORTANT: Changes here require a logout/login to take effect.
      # nix-darwin writes the plist on activation, but WindowServer caches
      # shortcut state per session. After `darwin-rebuild switch`, log out
      # and back in once.
      "com.apple.symbolichotkeys" = {
        AppleSymbolicHotKeys = {
          "12" = {
            enabled = false;
            value = {
              parameters = [
                104
                4
                1048576
              ];
              type = "standard";
            };
          };
        };
      };
    };
  };
}
