# macOS system settings for keyboard-driven workflow with AeroSpace.
#
# Scope is intentionally narrow: fast key repeat only.
#
# With opt/alt as the AeroSpace modifier instead of cmd, no macOS system
# shortcuts need to be patched out. Previously cmd+h (Hide Application) and
# the Chrome URL-bar shortcut required workarounds; those are gone.
{ ... }:
{
  system.defaults = {
    NSGlobalDomain = {
      # Fast key repeat — essential for comfortable hjkl navigation
      KeyRepeat = 2; # ~30ms repeat interval
      InitialKeyRepeat = 15; # ~225ms before repeat starts
      ApplePressAndHoldEnabled = false; # disable accented char picker on hold
    };
  };
}
