# keyd - Simple Aspect
# Cross-platform parity: super+{key} → ctrl+{key}
# Makes D+t (super/cmd key on Voyager) open/close tabs and windows,
# matching macOS cmd+t/w/n behavior
_: {
  flake.modules.nixos.keyd = _: {
    services.keyd = {
      enable = true;
      keyboards.default = {
        ids = [ "*" ];
        settings = {
          meta = {
            t = "C-t";
            n = "C-n";
            r = "C-r";
            w = "C-w";
            c = "C-c";
            v = "C-v";
            x = "C-x";
            space = "C-space";
          };

          # Reverse side of the swap: physical Ctrl+key → Super+key
          # so Ghostty can map super+c/d/z/etc to terminal control chars
          control = {
            c = "M-c";
            d = "M-d";
            z = "M-z";
          };
        };
      };
    };
  };
}
