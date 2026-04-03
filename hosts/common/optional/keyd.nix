# Full Ctrl↔Super swap for macOS-like keybindings on Linux.
# Physical Super (Cmd position) sends Ctrl for standard app shortcuts.
# Physical Ctrl sends Super for terminal control character passthrough via ghostty.
{
  services.keyd = {
    enable = true;
    keyboards.default = {
      ids = [ "*" ];
      settings = {
        main = {
          leftcontrol = "leftmeta";
          leftmeta = "leftcontrol";
          rightcontrol = "rightmeta";
          rightmeta = "rightcontrol";
        };
      };
    };
  };
}
