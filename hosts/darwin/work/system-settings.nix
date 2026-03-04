# macOS system settings for keyboard-driven workflow with Hammerspoon.
#
# Scope is intentionally narrow: fast key repeat + Mission Control shortcuts.
#
# With opt/alt as the Hammerspoon modifier, no macOS system shortcuts need to
# be patched out. Hammerspoon synthesizes ctrl+left/right to switch spaces, so
# those Mission Control shortcuts must be explicitly enabled here.
{ ... }:
{
  system.defaults = {
    NSGlobalDomain = {
      # Fast key repeat — essential for comfortable hjkl navigation
      KeyRepeat = 2; # ~30ms repeat interval
      InitialKeyRepeat = 15; # ~225ms before repeat starts
      ApplePressAndHoldEnabled = false; # disable accented char picker on hold
    };

    # Mission Control keyboard shortcuts — required for Hammerspoon space switching.
    # Hammerspoon's alt+h/l synthesize ctrl+left/right; if these are disabled,
    # the synthesized keystrokes do nothing.
    #
    # 79 = Move left a space  (ctrl+left,  keycode 123, modifier 262144)
    # 81 = Move right a space (ctrl+right, keycode 124, modifier 262144)
    CustomUserPreferences."com.apple.symbolichotkeys" = {
      AppleSymbolicHotKeys = {
        "79" = {
          enabled = true;
          value = {
            parameters = [ 65535 123 262144 ];
            type = "standard";
          };
        };
        "81" = {
          enabled = true;
          value = {
            parameters = [ 65535 124 262144 ];
            type = "standard";
          };
        };
      };
    };
  };
}
