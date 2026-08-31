# YubiKey - Simple Aspect
# FIDO2/U2F device access for hardware-backed SSH keys (sk-ssh-ed25519).
#
# Without these udev rules a normal user can't open the /dev/hidraw*
# node, so `ssh-keygen -t ed25519-sk` fails on a plugged-in key even
# though OpenSSH's sk helper links against libfido2 correctly — the
# "device not found" you get with nothing plugged in is not evidence
# that enrolment will work. libfido2 ships etc/udev/rules.d/70-u2f.rules,
# which services.udev.packages picks up.
#
# FIDO2 talks to the key over hidraw directly; pcscd is only needed for
# the PIV/OpenPGP applets, which nothing here uses.
_: {
  flake.modules.nixos.yubikey =
    { pkgs, ... }:
    {
      services.udev.packages = [ pkgs.libfido2 ];
      environment.systemPackages = [ pkgs.yubikey-manager ];
    };
}
