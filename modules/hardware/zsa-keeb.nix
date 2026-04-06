# ZSA Keyboard - Simple Aspect
# ZSA keyboard support + Keymapp configuration tool
_: {
  flake.modules.nixos.zsa-keeb =
    { pkgs, ... }:
    {
      hardware.keyboard.zsa.enable = true;
      environment.systemPackages = [ pkgs.keymapp ];
    };
}
