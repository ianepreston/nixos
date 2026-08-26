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
# No auth in front of homepage — a deliberate, accepted risk, re-confirmed
# in the 2026-08-26 service-exposure audit. Per-app links go to apps that
# gate their own access (Authentik OIDC or forward_auth).
#
# This is NOT "link metadata only" any more — that claim predates the
# widgets. Unauthenticated, this page renders:
#   - host CPU / memory / disk for this server (the `widgets` block below)
#   - live queue + library activity for jellyfin, lidarr, prowlarr, radarr,
#     sabnzbd, seerr, sonarr (tiles that declare a `widget`)
#   - the internal hostname map, including behemoth's admin URL on :10443
#
# Anything added here is readable by anyone who can reach Caddy on this
# host — which includes recipients of a tailnet node share, not just the
# home network. Weigh new tiles and widgets accordingly.
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
      # Every declared reader; homepage renders the lot, since each one
      # exists precisely because some widget on this dashboard wants it.
      credentialNames = lib.attrNames config.myRuntimeCredentials.readers;
      hasCredentials = credentialNames != [ ];
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
                  widget = lib.mkOption {
                    type = lib.types.nullOr (lib.types.attrsOf lib.types.unspecified);
                    default = null;
                    description = ''
                      Optional homepage widget block emitted on this tile.
                      The attrset is passed through to the rendered
                      services.yaml verbatim; required keys (e.g. `type`,
                      `url`, `key`) depend on the widget type. Reference
                      credentials via `{{HOMEPAGE_VAR_<NAME>}}` and register
                      the matching reader under `myRuntimeCredentials.readers`.
                      See https://gethomepage.dev/widgets/.
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
                }
                // lib.optionalAttrs (t.widget != null) { inherit (t) widget; };
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

        # Widget credentials. Homepage needs the API keys the *arrs,
        # sabnzbd and jellyfin generate for themselves, and those live in
        # each app's own config file rather than sops. The reader
        # machinery is shared (modules/system/runtime-credentials.nix)
        # because shelfmark pulls from the same registry; homepage just
        # subscribes to every declared reader, since each one exists for
        # a widget on this dashboard. `HOMEPAGE_VAR_` is homepage's
        # required prefix on anything substituted into widget config,
        # which is why the readers are registered under the bare name
        # and prefixed here.
        myRuntimeCredentials.consumers.homepage = lib.mkIf hasCredentials {
          vars = credentialNames;
          envVarPrefix = "HOMEPAGE_VAR_";
          units = [ "homepage-dashboard.service" ];
        };

        services.homepage-dashboard.environmentFiles = lib.mkIf hasCredentials [
          config.myRuntimeCredentials.consumers.homepage.envFile
        ];

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
            displayName = "pfSense";
            href = "https://behemoth.ipreston.net:10443";
            icon = "pfsense";
            description = "router";
          };
          laconia = {
            group = "Infrastructure";
            displayName = "Laconia";
            href = "http://laconia.ipreston.net";
            icon = "synology";
            description = "NAS";
          };
          blikvm = {
            group = "Infrastructure";
            displayName = "BliKVM";
            href = "http://blikvm.ipreston.net";
            icon = "pikvm";
            description = "KVM over IP";
          };
          # Same NAS as the Infrastructure tile above, surfaced again in
          # Home next to its photo app for day-to-day file access.
          laconia-home = {
            group = "Home";
            displayName = "Laconia";
            href = "http://laconia.ipreston.net";
            icon = "synology";
            description = "NAS";
          };
          synology-photos = {
            group = "Home";
            displayName = "Photos";
            href = "http://photos.laconia.ipreston.net";
            icon = "synology-photos";
            description = "Photo library";
          };
        };
      };
    };
}
