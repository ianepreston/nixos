# Homepage option surface (platform-tier).
# Owns the `myHomepage.tiles` option. Each app contributes one
# attrset entry keyed by app name; the leaf service in
# modules/apps/homepage.nix folds the accumulated tiles into the
# upstream `services.homepage-dashboard.services` list.
_: {
  flake.modules.nixos.myHomepage =
    { lib, ... }:
    {
      options.myHomepage = {
        tiles = lib.mkOption {
          default = { };
          description = ''
            Flat per-tile attrset. Each entry becomes one tile under the
            named `group`. Sort within a group is by `weight` (low to
            high), then alphabetical by `displayName`. Group display
            order is controlled by services.homepage-dashboard.settings.layout
            in the leaf homepage module.
          '';
          type = lib.types.attrsOf (
            lib.types.submodule (
              { name, ... }:
              {
                options = {
                  group = lib.mkOption {
                    type = lib.types.str;
                    description = ''
                      Layout group this tile appears under (e.g.
                      "Consumption", "Acquisition", "Infrastructure").
                      Required: no implicit default.
                    '';
                  };
                  displayName = lib.mkOption {
                    type = lib.types.str;
                    default = name;
                    description = "Label shown on the tile. Defaults to the attribute name.";
                  };
                  href = lib.mkOption {
                    type = lib.types.str;
                    description = "URL the tile links to.";
                  };
                  icon = lib.mkOption {
                    type = lib.types.str;
                    description = ''
                      Icon — either a dashboard-icons slug (e.g. `sonarr`)
                      or a full URL to an image.
                    '';
                  };
                  description = lib.mkOption {
                    type = lib.types.str;
                    description = "Short blurb shown beneath the tile label.";
                  };
                  weight = lib.mkOption {
                    type = lib.types.int;
                    default = 0;
                    description = ''
                      Sort weight within the group. Lower values render
                      first. Ties break alphabetically by displayName.
                    '';
                  };
                };
              }
            )
          );
        };
      };
    };
}
