# Printing - Simple Aspect
# CUPS printing with cups-browsed disabled for security
_: {
  flake.modules.nixos.printing = _: {
    services.printing = {
      enable = true;
    };

    systemd.services.cups-browsed = {
      enable = false;
      unitConfig.Mask = true;
    };
  };
}
