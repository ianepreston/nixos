# Sunshine - Simple Aspect
# Game streaming server
_: {
  flake.modules.nixos.sunshine =
    { pkgs, ... }:
    {
      services.sunshine = {
        enable = true;
        capSysAdmin = true;
        openFirewall = true;
      };
      environment.systemPackages = with pkgs; [
        gnomeExtensions.sunshinestatus
      ];
    };
}
