# Hyprland - Simple Aspect
#
# The desktop moonshine streams for its "Remote Desktop" tile (see
# modules/desktop/moonshine.nix). Chosen because it is the only candidate that
# both nests under moonshine's deliberately small protocol set and is a
# plausible daily driver:
#
#   - GNOME can't nest at all — gnome-shell 50 always runs as a Wayland display
#     server and takes logind control (#439).
#   - COSMIC's cosmic-session never forwards WAYLAND_DISPLAY to cosmic-comp, so
#     the compositor dies with winit NoCompositor however it's launched.
#   - Plasma's kwin nests fine under a full compositor, but its Wayland backend
#     requires wp_single_pixel_buffer_manager_v1, which moonshine does not
#     implement — kwin exits instantly and plasma_session restart-loops it.
#
# Hyprland's backend (aquamarine) binds only core wl_*, xdg_wm_base/surface/
# toplevel/popup and linux-dmabuf, all of which moonshine provides, and never
# references single_pixel_buffer.
#
# Enabling this also registers a Hyprland session in GDM, so it can be trialled
# on the physical seat independently of streaming.
_: {
  flake.modules.nixos.hyprland = _: {
    programs.hyprland.enable = true;
  };
}
