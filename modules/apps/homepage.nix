# Homepage - dashboard / launcher (https://gethomepage.dev)
# Native services.homepage-dashboard from nixpkgs (DynamicUser systemd
# unit), not a container.
#
# App entries are *distributed*: each app module appends to
# `myHomepage.services."<Group>"`. This module collapses the
# attrsOf-listOf wrapper into the list-of-single-key-map shape that the
# upstream option expects, so adding a new app is a one-attr line in
# the app's own module rather than a central edit.
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
            # Convert attrsOf-listOf wrapper into the list-of-single-key-map
            # shape upstream expects. mapAttrsToList yields alphabetical
            # group order; the settings.layout above overrides display order.
            lib.mapAttrsToList (group: items: { ${group} = items; }) (
              lib.recursiveUpdate config.myHomepage.services {
                Infrastructure = (config.myHomepage.services.Infrastructure or [ ]) ++ [
                  {
                    pfsense = {
                      href = "https://behemoth.ipreston.net:10443";
                      icon = "pfsense";
                      description = "router";
                    };
                  }
                  {
                    laconia = {
                      href = "http://laconia.ipreston.net:5001";
                      icon = "synology";
                      description = "NAS";
                    };
                  }
                  {
                    unifi = {
                      href = "https://192.168.10.41:8443";
                      icon = "unifi";
                      description = "WiFi controller";
                    };
                  }
                  {
                    xo = {
                      href = "http://xo.ipreston.net";
                      icon = "https://xcp-ng.org/assets/img/mainlogo.png";
                      description = "hypervisor";
                    };
                  }
                  {
                    blikvm = {
                      href = "http://blikvm.ipreston.net";
                      icon = "pikvm";
                      description = "KVM over IP";
                    };
                  }
                ];
              }
            );

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
      };
    };
}
