{ ... }:
{
  xdg.configFile."aerospace/aerospace.toml".text = ''
    start-at-login = true

    default-root-container-layout = 'tiles'
    default-root-container-orientation = 'auto'
    accordion-padding = 30

    # Gaps matching Omarchy feel (5px inner, 10px outer)
    [gaps]
    inner.horizontal = 5
    inner.vertical   = 5
    outer.left       = 10
    outer.bottom     = 10
    outer.top        = 10
    outer.right      = 10

    # Workspaces 1-5 on the main display, 6-10 on the secondary.
    # Uses 'main'/'secondary' so standalone-laptop mode works without conflict.
    [workspace-to-monitor-force-assignment]
    1 = 'main'
    2 = 'main'
    3 = 'main'
    4 = 'main'
    5 = 'main'
    6 = 'main'
    7 = 'main'
    8 = 'secondary'
    9 = 'secondary'
    10 = 'secondary'

    # ---- Main mode ----
    [mode.main.binding]

    # Window focus (hjkl — no arrow keys needed)
    # cmd+h replaces macOS "Hide Application" (disabled in system-settings.nix)
    # cmd+l replaces browser URL bar; use ctrl+l instead (configured for Chrome)
    cmd-h = 'focus left'
    cmd-j = 'focus down'
    cmd-k = 'focus up'
    cmd-l = 'focus right'

    # Window movement
    cmd-shift-h = 'move left'
    cmd-shift-j = 'move down'
    cmd-shift-k = 'move up'
    cmd-shift-l = 'move right'

    # Workspace switching
    cmd-1 = 'workspace 1'
    cmd-2 = 'workspace 2'
    cmd-3 = 'workspace 3'
    cmd-4 = 'workspace 4'
    cmd-5 = 'workspace 5'
    cmd-6 = 'workspace 6'
    cmd-7 = 'workspace 7'
    cmd-8 = 'workspace 8'
    cmd-9 = 'workspace 9'
    cmd-0 = 'workspace 10'

    # Move window to workspace
    cmd-shift-1 = 'move-node-to-workspace 1'
    cmd-shift-2 = 'move-node-to-workspace 2'
    cmd-shift-3 = 'move-node-to-workspace 3'
    cmd-shift-4 = 'move-node-to-workspace 4'
    cmd-shift-5 = 'move-node-to-workspace 5'
    cmd-shift-6 = 'move-node-to-workspace 6'
    cmd-shift-7 = 'move-node-to-workspace 7'
    cmd-shift-8 = 'move-node-to-workspace 8'
    cmd-shift-9 = 'move-node-to-workspace 9'
    cmd-shift-0 = 'move-node-to-workspace 10'

    # Workspace cycling (sacrifices browser back/forward; use trackpad gestures)
    cmd-leftSquareBracket  = 'workspace prev'
    cmd-rightSquareBracket = 'workspace next'
    cmd-backslash          = 'workspace-back-and-forth'

    # Layout controls
    # ctrl+cmd+f matches macOS fullscreen convention (green traffic-light button)
    ctrl-cmd-f      = 'fullscreen'
    cmd-shift-space = 'layout floating tiling'
    cmd-comma       = 'layout h_tiles v_tiles'

    # Enter resize mode
    cmd-r = 'mode resize'

    # App launching — terminal and browser only; everything else via Spotlight (cmd+space)
    cmd-enter       = "exec-and-forget open -na Ghostty"
    cmd-shift-enter = "exec-and-forget open -a 'Google Chrome'"

    # ---- Resize mode ----
    # Enter via cmd-r, exit via esc or enter
    [mode.resize.binding]
    h     = 'resize width -50'
    l     = 'resize width +50'
    j     = 'resize height +50'
    k     = 'resize height -50'
    enter = 'mode main'
    esc   = 'mode main'
  '';
}
