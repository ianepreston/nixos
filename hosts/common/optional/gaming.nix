{ pkgs, ... }:
{
  hardware.xone.enable = true; # Gamepad
  programs = {
    steam = {
      enable = true;
      remotePlay.openFirewall = true; # Open ports in the firewall for Steam Remote Play
      dedicatedServer.openFirewall = true; # Open ports in the firewall for Source Dedicated Server
      localNetworkGameTransfers.openFirewall = true; # Open ports in the firewall for Steam Local Network Game Transfers
      gamescopeSession.enable = true;
    };
    gamescope = {
      enable = true;

    };
  };
  environment.systemPackages = with pkgs; [
    steam-run
  ];

}
