# YubiKey Darwin - Simple Aspect
# YubiKey PAM authentication for sudo on macOS
_: {
  flake.modules.darwin.yubikey =
    { pkgs, ... }:
    {
      # Ensure the PAM module is installed on the system
      environment.systemPackages = with pkgs; [
        pam_u2f
      ];

      # Declaratively configure the sudo_local file
      security.pam.services.sudo_local = {
        enable = true;
        text = ''
          # Prompt the user to touch the YubiKey
          auth sufficient ${pkgs.pam_u2f}/lib/security/pam_u2f.so cue
        '';
      };
    };
}
