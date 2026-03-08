{ ... }:
{
  xdg.configFile."aerospace/aerospace.toml".text = ''
    start-at-login = true

    # Floating-only mode — AeroSpace manages workspaces but does not tile.
    # Window snapping is handled by Hammerspoon (alt+arrows).

    # Force every window into floating layout on open
    [[on-window-detected]]
    run = 'layout floating'

    # No gaps in floating mode
    [gaps]
    inner.horizontal = 0
    inner.vertical   = 0
    outer.left       = 0
    outer.bottom     = 0
    outer.top        = 0
    outer.right      = 0

    # Workspaces 1-7 on main display, 8-10 on secondary
    [workspace-to-monitor-force-assignment]
    1  = 'main'
    2  = 'main'
    3  = 'main'
    4  = 'main'
    5  = 'main'
    6  = 'main'
    7  = 'main'
    8  = 'secondary'
    9  = 'secondary'
    10 = 'secondary'

    # ---- Main mode ----
    [mode.main.binding]

    # Workspace left/right (virtual workspaces — instant, no macOS animation)
    alt-h = 'workspace prev'
    alt-l = 'workspace next'

    # Move focused window to adjacent workspace and follow it
    alt-shift-h = ['move-node-to-workspace prev', 'workspace prev']
    alt-shift-l = ['move-node-to-workspace next', 'workspace next']

    # Direct workspace access
    alt-1 = 'workspace 1'
    alt-2 = 'workspace 2'
    alt-3 = 'workspace 3'
    alt-4 = 'workspace 4'
    alt-5 = 'workspace 5'
    alt-6 = 'workspace 6'
    alt-7 = 'workspace 7'
    alt-8 = 'workspace 8'
    alt-9 = 'workspace 9'
    alt-0 = 'workspace 10'

    # Move window to specific workspace and follow
    alt-shift-1 = ['move-node-to-workspace 1', 'workspace 1']
    alt-shift-2 = ['move-node-to-workspace 2', 'workspace 2']
    alt-shift-3 = ['move-node-to-workspace 3', 'workspace 3']
    alt-shift-4 = ['move-node-to-workspace 4', 'workspace 4']
    alt-shift-5 = ['move-node-to-workspace 5', 'workspace 5']
    alt-shift-6 = ['move-node-to-workspace 6', 'workspace 6']
    alt-shift-7 = ['move-node-to-workspace 7', 'workspace 7']
    alt-shift-8 = ['move-node-to-workspace 8', 'workspace 8']
    alt-shift-9 = ['move-node-to-workspace 9', 'workspace 9']
    alt-shift-0 = ['move-node-to-workspace 10', 'workspace 10']
  '';
}
