# Shared helpers for the *arr stack (radarr/sonarr/lidarr/prowlarr/decluttarr).
# Leading underscore keeps import-tree from auto-importing this as a
# flake module (same convention as modules/hosts/_rollback-root.nix) —
# it's a plain attrset consumed via `import ./_arr-lib.nix`.
{
  # Shell fragment that extracts a *arr API key from its config.xml.
  # Paths differ per app; only this extraction pattern is shared.
  mkArrApiKeyScript = configXmlPath: "grep -oP '(?<=<ApiKey>)[^<]+' ${configXmlPath}";

  # `services.<arr>.settings` fragment delegating authentication to the
  # reverse proxy. Every arr here sits behind authentik forward_auth in
  # its Caddy route (myAuthentik.forwardAuthApps.<app>), so the app
  # should not run a login of its own on top of it.
  #
  # `External` is the mode for exactly that, and upstream deliberately
  # keeps it out of the UI's auth dropdown — it is reachable only via
  # config.xml or the env-var overrides the nixpkgs servarr module
  # renders from `settings` (<APP>__AUTH__METHOD), which is what this
  # is. See https://wiki.servarr.com/lidarr/faq#forced-authentication.
  # Going through `settings` rather than hand-editing config.xml also
  # means the value can't drift per host or be clobbered by a config
  # rewrite: the env var wins at runtime whatever config.xml holds.
  #
  # This does NOT loosen /api — the API key is enforced independently
  # of the UI auth method, which is what keeps each module's
  # `bypassAuthPaths` honest. Verified per app by curling the bypassed
  # routes with no key (401) and with one (200).
  #
  # Only `method` is pinned. `AuthenticationRequired` (the
  # local-address carve-out) is inert once auth is external, so it's
  # left to whatever each host's config.xml already holds rather than
  # adding a second knob that does nothing.
  externalAuthSettings = {
    auth.method = "External";
  };
}
