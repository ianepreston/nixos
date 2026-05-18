# Homepage - dashboard / launcher (https://gethomepage.dev)
# Native services.homepage-dashboard from nixpkgs (DynamicUser systemd
# unit), not a container.
#
# App entries are *distributed*: each app module sets one
# `myHomepage.tiles.<name> = { group; href; icon; description; ... }`
# entry. The option is declared inline below; this module groups the
# accumulated tiles by `group`, sorts each group by (weight,
# displayName), and feeds the result into the upstream
# `services.homepage-dashboard.services` list-of-single-key shape.
#
# No auth in front of homepage. Per-app links go to apps that gate
# their own access (Authentik OIDC or forward_auth), so the dashboard
# itself only exposes link metadata.
_: {
  flake.modules.nixos.homepage =
    {
      config,
      hostSpec,
      lib,
      ...
    }:
    let
      homepageHost = "homepage.${hostSpec.serverDomain}";
      homepagePort = 8082;
    in
    {
      options.myHomepage = {
        tiles = lib.mkOption {
          default = { };
          description = ''
            Flat per-tile attrset. Each entry becomes one tile under the
            named `group`. Sort within a group is by `weight` (low to
            high), then alphabetical by `displayName`. Group display
            order is controlled by services.homepage-dashboard.settings.layout
            below.
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

      config = {
        services.homepage-dashboard = {
          enable = true;
          listenPort = homepagePort;
          allowedHosts = homepageHost;

          settings = {
            title = "Ian's homelab";
            theme = "dark";
            color = "slate";
            background = {
              image = "https://cdnb.artstation.com/p/assets/images/images/006/897/659/large/mikael-gustafsson-wallpaper-mikael-gustafsson.jpg";
              blur = "sm";
              saturate = 50;
              brightness = 50;
              opacity = 50;
            };
            useEqualHeights = true;
            # Pin group order; groups present in services but missing
            # from layout still render, just appended after.
            layout = [
              {
                Consumption = {
                  header = true;
                  style = "row";
                  columns = 4;
                };
              }
              {
                Requests = {
                  header = true;
                  style = "row";
                  columns = 4;
                };
              }
              {
                Home = {
                  header = true;
                  style = "row";
                  columns = 4;
                };
              }
              {
                Acquisition = {
                  header = true;
                  style = "row";
                  columns = 4;
                };
              }
              {
                Infrastructure = {
                  header = true;
                  style = "row";
                  columns = 4;
                };
              }
            ];
          };

          widgets = [
            {
              resources = {
                cpu = true;
                memory = true;
                disk = "/";
              };
            }
            {
              datetime = {
                text_size = "xl";
                format.timeStyle = "short";
              };
            }
            {
              # Calgary
              openmeteo = {
                latitude = 50.97;
                longitude = -114.01;
                timezone = "America/Edmonton";
                units = "metric";
                cache = 5;
              };
            }
          ];

          services =
            # Group tiles by `group`, sort within each group by (weight,
            # displayName), then collapse to the list-of-single-key-map
            # shape the upstream module expects. mapAttrsToList yields
            # groups in alphabetical order; settings.layout above pins
            # display order.
            let
              tiles = lib.attrValues (
                lib.mapAttrs (name: tile: tile // { _name = name; }) config.myHomepage.tiles
              );
              byGroup = builtins.groupBy (t: t.group) tiles;
              sortedGroup =
                items:
                lib.sort (
                  a: b: if a.weight != b.weight then a.weight < b.weight else a.displayName < b.displayName
                ) items;
              tileToEntry = t: {
                ${t.displayName} = {
                  inherit (t) href icon description;
                };
              };
            in
            lib.mapAttrsToList (group: items: {
              ${group} = map tileToEntry (sortedGroup items);
            }) byGroup;

        };

        # cpu widget needs ProcSubset=all and the upstream module already
        # flips that based on widgets[].resources.cpu, so nothing to do
        # here. Logging goes to journal -> vector -> victorialogs via
        # the default "LOG_TARGETS=stdout" the upstream module sets.

        myCaddy.apps.homepage = {
          host = homepageHost;
          routeConfig = ''
            reverse_proxy localhost:${toString homepagePort}
          '';
        };

        # Hard-wired network gear tiles. These aren't deployed by this
        # flake (they're appliances on the LAN) but live on the homepage
        # for convenience. Same option surface as every other tile.
        myHomepage.tiles = {
          pfsense = {
            group = "Infrastructure";
            href = "https://behemoth.ipreston.net:10443";
            icon = "pfsense";
            description = "router";
          };
          laconia = {
            group = "Infrastructure";
            href = "http://laconia.ipreston.net:5001";
            icon = "synology";
            description = "NAS";
          };
          blikvm = {
            group = "Infrastructure";
            href = "http://blikvm.ipreston.net";
            icon = "pikvm";
            description = "KVM over IP";
          };
        };
      };
    };
}
