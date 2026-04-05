# Minimal User - Simple Aspect
# Temp password for minimal builds like installer and ISO
_: {
  flake.modules.nixos.minimal-user =
    { hostSpec, ... }:
    {
      users.users.${hostSpec.username} = {
        isNormalUser = true;
        hashedPassword = "$y$j9T$oZTIDlBknKDsymZVWi9KP/$990/4NIQDrTf.rcbDkrSZ7SP/lcjA2spoQstRlMbx/C";
        extraGroups = [ "wheel" ];
      };
    };
}
