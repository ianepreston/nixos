# Darwin Desktop - Simple Aspect
# macOS system settings for keyboard-driven workflow.
#
# Native macOS Spaces for workspaces (ctrl+number, ctrl+arrows).
# Hammerspoon handles window tiling (hyper+hjk) and alt+tab switching.
_: {
  flake.modules.darwin.desktop = _: {
    system.defaults = {
      NSGlobalDomain = {
        # Fast key repeat — essential for comfortable hjkl navigation
        KeyRepeat = 2; # ~30ms repeat interval
        InitialKeyRepeat = 15; # ~225ms before repeat starts
        ApplePressAndHoldEnabled = false; # disable accented char picker on hold

        # Reduce window open/close animations for snappier feel
        NSAutomaticWindowAnimationsEnabled = false;
      };

      # Mission Control hot corner (top-left) + fast animation
      # corner values: 0=disabled, 2=Mission Control, 4=Desktop, 5=Screen Saver
      CustomUserPreferences."com.apple.dock" = {
        # Speed up Mission Control / space-switch animation
        expose-animation-duration = "0.1";
        # Auto-switch to a Space when an app receives focus (e.g. clicking
        # launcher icons, opening links from Slack). Disabled briefly but
        # re-enabled — the real culprit for unwanted switches is Obsidian CLI
        # stealing focus; see note in workflows.md.
        workspaces-auto-swoosh = true;
      };

      # ctrl+number Space switching via symbolic hotkeys
      CustomUserPreferences."com.apple.symbolichotkeys" = {
        AppleSymbolicHotKeys = {
          # Switch to Desktop 1: ctrl+1
          "118" = {
            enabled = true;
            value = {
              type = "standard";
              parameters = [
                49
                18
                262144
              ];
            };
          };
          # Switch to Desktop 2: ctrl+2
          "119" = {
            enabled = true;
            value = {
              type = "standard";
              parameters = [
                50
                19
                262144
              ];
            };
          };
          # Switch to Desktop 3: ctrl+3
          "120" = {
            enabled = true;
            value = {
              type = "standard";
              parameters = [
                51
                20
                262144
              ];
            };
          };
          # Switch to Desktop 4: ctrl+4
          "121" = {
            enabled = true;
            value = {
              type = "standard";
              parameters = [
                52
                21
                262144
              ];
            };
          };
          # Switch to Desktop 5: ctrl+5
          "122" = {
            enabled = true;
            value = {
              type = "standard";
              parameters = [
                53
                23
                262144
              ];
            };
          };

          # ctrl+left/right for workspace navigation
          # Mission Control: Move left a space (ID 79): ctrl+left
          "79" = {
            enabled = true;
            value = {
              type = "standard";
              parameters = [
                65535
                123
                262144
              ];
            };
          };
          # Mission Control: Move right a space (ID 81): ctrl+right
          "81" = {
            enabled = true;
            value = {
              type = "standard";
              parameters = [
                65535
                124
                262144
              ];
            };
          };
        };
      };

      # Dock — left, small icons, always visible
      dock = {
        orientation = "left";
        tilesize = 32;
        autohide = false;
        minimize-to-application = true; # keep dock tidy
        show-recents = false; # hide recent apps section
        mru-spaces = false; # don't rearrange Spaces based on most recent use
        wvous-tl-corner = 2; # Mission Control
      };

    };

    # Apply symbolic hotkey changes immediately
    system.activationScripts.postActivation.text = ''
      /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
    '';
  };
}
