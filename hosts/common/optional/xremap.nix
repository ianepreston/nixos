# Cross-platform parity: super+{c,x,v,t,w,n} → ctrl+{c,x,v,t,w,n}
# Mirrors macOS cmd+key behavior for common shortcuts.
# Excludes terminals where ctrl+c = SIGINT, ctrl+w = delete word, etc.
{ hostSpec, ... }:
{
  services.xremap = {
    enable = true;
    withGnome = true;
    serviceMode = "user";
    userName = hostSpec.username;
    # Explicitly specify keyboards to avoid selecting virtual "Keyboard passthrough" device
    watch = true;
    deviceNames = [ "ZSA Technology Labs Voyager" ];
    config = {
      keymap = [
        {
          name = "macOS parity (excluding terminals)";
          application.not = [ "/ghostty/" "/[Cc]onsole/" "/kitty/" "/[Aa]lacritty/" "/konsole/" "/wezterm/" "/terminal/" ];
          remap = {
            "Super-c" = "C-c";
            "Super-x" = "C-x";
            "Super-v" = "C-v";
            "Super-t" = "C-t";
            "Super-w" = "C-w";
            "Super-n" = "C-n";
          };
        }
      ];
    };
  };
}
