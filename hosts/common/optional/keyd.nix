# Cross-platform parity: super+{t,w,n} → ctrl+{t,w,n}
# Makes D+t (super/cmd key on Voyager) open/close tabs and windows,
# matching macOS cmd+t/w/n behavior. ctrl+t/w/n still works natively too.
{
  services.keyd = {
    enable = true;
    keyboards.default = {
      ids = [ "*" ];
      settings = {
        meta = {
          t = "C-t";
          w = "C-w";
          n = "C-n";
        };
      };
    };
  };
}
