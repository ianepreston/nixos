# Homepage - dashboard / launcher (https://gethomepage.dev)
# Native services.homepage-dashboard from nixpkgs (DynamicUser systemd
# unit), not a container.
#
# App entries are *distributed*: each app module sets one
# `myHomepage.tiles.<name> = { group; href; icon; description; ... }`
# entry. The option itself lives in modules/platform/homepage.nix; this
# module groups the accumulated tiles by `group`, sorts each group by
# (weight, displayName), and feeds the result into the upstream
# `services.homepage-dashboard.services` list-of-single-key shape.
#
# No auth in front of homepage. Per-app links go to apps that gate
# their own access (Authentik OIDC or forward_auth), so the dashboard
# itself only exposes link metadata.
{ inputs, ... }:
{
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
      imports = [ inputs.self.modules.nixos.myHomepage ];

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
                General = {
                  header = true;
                  style = "row";
                  columns = 4;
                };
              }
              {
                Consumption = {
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
                Developer = {
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

          bookmarks = [
            {
              Developer = [
                {
                  "Azure Portal" = [
                    {
                      abbr = "Az";
                      icon = "azure";
                      href = "https://portal.azure.com/";
                    }
                  ];
                }
                {
                  blog = [
                    {
                      abbr = "ip";
                      href = "http://blog.ianpreston.ca/";
                    }
                  ];
                }
                {
                  "Databricks Academy" = [
                    {
                      abbr = "db";
                      icon = "https://www.svgrepo.com/show/330261/databricks.svg";
                      href = "https://customer-academy.databricks.com/learn/signin";
                    }
                  ];
                }
                {
                  Github = [
                    {
                      abbr = "GH";
                      icon = "github";
                      href = "https://github.com/";
                    }
                  ];
                }
                {
                  HackerNews = [
                    {
                      abbr = "HN";
                      href = "https://news.ycombinator.com";
                    }
                  ];
                }
              ];
            }
            {
              General = [
                {
                  ambiphone = [
                    {
                      abbr = "ap";
                      href = "https://ambiph.one/";
                    }
                  ];
                }
                {
                  calendar = [
                    {
                      href = "https://calendar.google.com/calendar/";
                      icon = "google-calendar";
                    }
                  ];
                }
                {
                  chatGPT = [
                    {
                      href = "https://chat.openai.com/";
                      icon = "chatgpt";
                    }
                  ];
                }
                {
                  drive = [
                    {
                      href = "https://drive.google.com/";
                      icon = "google-drive";
                    }
                  ];
                }
                {
                  gmail = [
                    {
                      href = "https://mail.google.com/mail/u/0/#inbox";
                      icon = "gmail";
                    }
                  ];
                }
                {
                  openslum = [
                    {
                      href = "https://open-slum.org/";
                      icon = "google-play-books";
                    }
                  ];
                }
                {
                  annas-archive = [
                    {
                      href = "https://annas-archive.org/";
                      icon = "google-play-books";
                    }
                  ];
                }
                {
                  maps = [
                    {
                      href = "https://google.com/maps";
                      icon = "google-maps";
                    }
                  ];
                }
              ];
            }
          ];
        };

        # cpu widget needs ProcSubset=all and the upstream module already
        # flips that based on widgets[].resources.cpu, so nothing to do
        # here. Logging goes to journal -> promtail -> loki via the
        # default "LOG_TARGETS=stdout" the upstream module sets.

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
          unifi = {
            group = "Infrastructure";
            href = "https://192.168.10.41:8443";
            icon = "unifi";
            description = "WiFi controller";
          };
          xo = {
            group = "Infrastructure";
            href = "http://xo.ipreston.net";
            icon = "https://xcp-ng.org/assets/img/mainlogo.png";
            description = "hypervisor";
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
