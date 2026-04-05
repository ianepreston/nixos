# Gaming - Simple Aspect
# Steam + Gamescope + Xbox gamepad support
_: {
  flake.modules.nixos.gaming =
    { pkgs, ... }:
    {
      hardware.xone.enable = true;
      programs = {
        steam = {
          enable = true;
          remotePlay.openFirewall = true;
          dedicatedServer.openFirewall = true;
          localNetworkGameTransfers.openFirewall = true;
          gamescopeSession.enable = true;
        };
        gamescope = {
          enable = true;
        };
      };
      environment.systemPackages = with pkgs; [
        steam-run
      ];
    };
}
