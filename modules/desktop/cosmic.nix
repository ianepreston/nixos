# COSMIC Desktop - Simple Aspect
#
# The desktop moonshine streams for its "Remote Desktop" tile (see
# modules/desktop/moonshine.nix). It's what moonshine's own TIPS.md documents,
# and upstream reports it working (moonshine issues #150 and #168).
#
# Display manager comes from gnome.nix, which every desktop host imports.
# Enabling this also registers a COSMIC session in GDM, so it can be trialled
# on the physical seat independently of streaming.
_: {
  flake.modules.nixos.cosmic = _: {
    # xwayland.enable defaults to true; leave it, the streamed session still
    # needs to run X11 apps.
    services.desktopManager.cosmic.enable = true;
  };
}
