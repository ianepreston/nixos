{ config, hostSpec, ... }:
{

  # Set a temp password for use by minimal builds like installer and iso
  users.users.${hostSpec.username} = {
    isNormalUser = true;
    hashedPassword = "$y$j9T$oZTIDlBknKDsymZVWi9KP/$990/4NIQDrTf.rcbDkrSZ7SP/lcjA2spoQstRlMbx/C";
    extraGroups = [ "wheel" ];
  };
}
