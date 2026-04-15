# Ghostty - HM Simple Aspect
# Ghostty terminal configuration
# NixOS: managed via programs.ghostty (installed by nix)
# Darwin: config file only (installed via Homebrew)
_: {
  flake.modules.homeManager.ghostty =
    { hostSpec, ... }:
    if hostSpec.isDarwin then
      {
        home.file."Library/Application Support/com.mitchellh.ghostty/config" = {
          text = ''
            theme = Catppuccin Latte
            font-family = FiraCode Nerd Font Mono
            clipboard-read = allow
            clipboard-write = allow
            font-size = 14
          '';
        };
      }
    else
      {
        programs.ghostty = {
          enable = true;
          enableZshIntegration = true;
          settings = {
            theme = "Catppuccin Latte";
            font-family = "monospace";
            clipboard-read = "allow";
            clipboard-write = "allow";
            font-size = "11";

            # macOS parity with keyd full Ctrl↔Super swap.
            # Physical Super → Ctrl (keyd), so ctrl+key triggers app shortcuts.
            # Physical Ctrl → Super (keyd), so super+key sends terminal control chars.
            keybind = [
              # App shortcuts (physical Super+key → Ctrl+key after keyd swap)
              "ctrl+c=copy_to_clipboard"
              "ctrl+v=paste_from_clipboard"
              "ctrl+t=new_tab"
              "ctrl+w=close_surface"
              "ctrl+n=new_window"

              # Terminal control characters (physical Ctrl+key → Super+key after keyd swap)
              "super+c=text:\\x03" # SIGINT (Ctrl+C)
              "super+d=text:\\x04" # EOF (Ctrl+D)
              "super+z=text:\\x1a" # SIGTSTP - suspend (Ctrl+Z)

              # Vim split navigation: physical Ctrl+hjkl passes through as Ctrl+hjkl
              # (no keyd remap needed — terminal handles these control chars natively)
            ];
          };
        };

        home.sessionVariables = {
          TERM = "ghostty";
        };
      };
}
