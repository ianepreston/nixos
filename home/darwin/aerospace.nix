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
    # Primary modifier is opt/alt. macOS apps almost never bind alt as a primary
    # shortcut (it's used for character variants), so this namespace is clean.
    # Using cmd caused too many collisions: cmd+enter (modal accept), cmd+l (URL
    # bar), cmd+[/] (browser back/forward), cmd+1-9 (browser tabs), etc.
    [mode.main.binding]

    # Window focus (hjkl)
    alt-h = 'focus left'
    alt-j = 'focus down'
    alt-k = 'focus up'
    alt-l = 'focus right'

    # Window movement
    alt-shift-h = 'move left'
    alt-shift-j = 'move down'
    alt-shift-k = 'move up'
    alt-shift-l = 'move right'

    # Workspace switching
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

    # Move window to workspace
    alt-shift-1 = 'move-node-to-workspace 1'
    alt-shift-2 = 'move-node-to-workspace 2'
    alt-shift-3 = 'move-node-to-workspace 3'
    alt-shift-4 = 'move-node-to-workspace 4'
    alt-shift-5 = 'move-node-to-workspace 5'
    alt-shift-6 = 'move-node-to-workspace 6'
    alt-shift-7 = 'move-node-to-workspace 7'
    alt-shift-8 = 'move-node-to-workspace 8'
    alt-shift-9 = 'move-node-to-workspace 9'
    alt-shift-0 = 'move-node-to-workspace 10'

    # Workspace cycling (browser back/forward is cmd+[/] again — no trade-off)
    alt-leftSquareBracket  = 'workspace prev'
    alt-rightSquareBracket = 'workspace next'
    alt-backslash          = 'workspace-back-and-forth'

    # Layout controls
    ctrl-cmd-f = 'fullscreen'           # matches macOS green traffic-light button
    alt-space  = 'layout floating tiling'
    alt-comma  = 'layout h_tiles v_tiles'

    # Enter resize mode
    alt-r = 'mode resize'

    # App launching — terminal and browser only; everything else via Spotlight (cmd+space)
    alt-enter       = "exec-and-forget open -na Ghostty"
    alt-shift-enter = "exec-and-forget open -a 'Google Chrome'"

    # ---- Resize mode ----
    # Enter via alt-r, exit via esc or enter
    [mode.resize.binding]
    h     = 'resize width -50'
    l     = 'resize width +50'
    j     = 'resize height +50'
    k     = 'resize height -50'
    enter = 'mode main'
    esc   = 'mode main'
  '';
}
