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
}
