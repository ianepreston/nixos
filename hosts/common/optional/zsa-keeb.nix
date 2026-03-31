{ pkgs, ... }:
{
  hardware.keyboard.zsa.enable = true;
  environment.systemPackages = [ pkgs.keymapp ];

  # Prevent systemd-logind from grabbing Voyager as a "power-switch" device.
  # The Voyager exposes Consumer Control and System Control HID interfaces that
  # trigger logind to "watch system buttons" with an exclusive grab. This blocks
  # xremap from grabbing the device at boot (race condition). By clearing
  # ID_INPUT_KEY before 70-power-switch.rules runs, logind ignores the device.
  # Rule must be numbered 61-69 to run after 60-input-id but before 70-power-switch.
  services.udev.packages = [
    (pkgs.writeTextFile {
      name = "65-zsa-voyager-no-powerswitch";
      destination = "/etc/udev/rules.d/65-zsa-voyager-no-powerswitch.rules";
      text = ''
        # ZSA Voyager: prevent systemd-logind power-switch grab (fixes xremap race)
        # Clears ID_INPUT_KEY so 70-power-switch.rules won't tag as power-switch
        SUBSYSTEM=="input", KERNEL=="event*", ATTRS{idVendor}=="3297", ATTRS{idProduct}=="1977", ENV{ID_INPUT_KEY}="0"
      '';
    })
  ];
}
