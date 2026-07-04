# Shared helpers for the *arr stack (radarr/sonarr/prowlarr/decluttarr).
# Leading underscore keeps import-tree from auto-importing this as a
# flake module (same convention as modules/hosts/_rollback-root.nix) —
# it's a plain attrset consumed via `import ./_arr-lib.nix`.
{
  # Shell fragment that extracts a *arr API key from its config.xml.
  # Paths differ per app; only this extraction pattern is shared.
  mkArrApiKeyScript = configXmlPath: "grep -oP '(?<=<ApiKey>)[^<]+' ${configXmlPath}";
}
