# Homepage option surface (platform-tier).
# Owns the `myHomepage` option namespace that app modules contribute to.
# The leaf service (services.homepage-dashboard) is deployed by
# modules/apps/homepage.nix, which imports this module to read the
# accumulated tile contributions.
_: {
  flake.modules.nixos.myHomepage =
    { lib, ... }:
    {
      options.myHomepage = {
        services = lib.mkOption {
          type = lib.types.attrsOf (lib.types.listOf (lib.types.attrsOf lib.types.anything));
          default = { };
          example = lib.literalExpression ''
            {
              Consumption = [
                { Mealie = { href = "https://mealie.example"; icon = "mealie"; description = "Recipes"; }; }
              ];
            }
          '';
          description = ''
            App entries for the homepage dashboard, keyed by group name.
            Each list item is a single-key attrset whose key is the
            display name; module-system list merging concatenates entries
            from every contributor under the same group.
          '';
        };
      };
    };
}
