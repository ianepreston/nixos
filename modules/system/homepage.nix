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
      pkgs,
      ...
    }:
    let
      homepageHost = "homepage.${hostSpec.serverDomain}";
      homepagePort = 8082;
      credentials = config.myHomepage.credentials;
      hasCredentials = credentials != { };
      credentialsEnvFile = "/run/homepage-credentials/env";
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
                      the matching reader under `myHomepage.credentials`.
                      See https://gethomepage.dev/widgets/.
                    '';
                  };
                };
              }
            )
          );
        };

        credentials = lib.mkOption {
          default = { };
          description = ''
            Per-widget API key readers. The attribute name is the
            placeholder suffix: an entry `SONARR_API_KEY` is referenced
            from widget configs as `{{HOMEPAGE_VAR_SONARR_API_KEY}}`
            (Homepage requires the `HOMEPAGE_VAR_` prefix on substituted
            env vars; this module prepends it when writing the env file
            so the option key stays uncluttered). The reader runs as
            root in a oneshot ordered before homepage-dashboard.service;
            the rendered env file is consumed via EnvironmentFile, so
            keys never land in /nix/store.
          '';
          type = lib.types.attrsOf (
            lib.types.submodule (_: {
              options = {
                sourceUnit = lib.mkOption {
                  type = lib.types.str;
                  description = ''
                    Systemd unit that produces the config file or DB the
                    reader pulls from. Pulled into After=/Wants= so the
                    upstream service has started (and on first boot,
                    has written its config) before we try to read it.
                  '';
                };
                readScript = lib.mkOption {
                  type = lib.types.lines;
                  description = ''
                    Shell snippet that prints the API key value to
                    stdout (no trailing newline). Runs as root with
                    coreutils + gnugrep + gnused + sqlite + gawk on PATH.
                    Empty/missing output is tolerated — the env line is
                    omitted and the widget renders an error rather than
                    blocking homepage boot.
                  '';
                };
              };
            })
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

        # Widget credentials. The oneshot runs at boot ordered after the
        # apps whose config we read from, writes one env file homepage
        # consumes via EnvironmentFile, and re-runs (with homepage
        # bouncing) whenever its content changes. Per-credential reads
        # retry briefly so first-boot timing (app just started, config
        # file not yet written) isn't fatal; an empty result skips the
        # line so homepage stays up with a broken widget rather than
        # failing to render the dashboard.
        systemd.services.homepage-credentials = lib.mkIf hasCredentials {
          description = "Render homepage widget credentials env file";
          after = [
            "sops-install-secrets.service"
          ]
          ++ (lib.unique (lib.mapAttrsToList (_: c: c.sourceUnit) credentials));
          wants = lib.unique (lib.mapAttrsToList (_: c: c.sourceUnit) credentials);
          before = [ "homepage-dashboard.service" ];
          wantedBy = [ "homepage-dashboard.service" ];
          path = with pkgs; [
            coreutils
            gnugrep
            gnused
            gawk
            sqlite
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            RuntimeDirectory = "homepage-credentials";
            RuntimeDirectoryPreserve = "yes";
            UMask = "0077";
          };
          script = ''
            set -uo pipefail
            out=${credentialsEnvFile}
            tmp="$out.tmp"
            : > "$tmp"
            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (envVar: cred: ''
                val=""
                for _ in 1 2 3 4 5; do
                  raw="$( {
                  ${cred.readScript}
                  } 2>/dev/null || true)"
                  val="$(printf '%s' "$raw" | tr -d '\n\r' | head -c 256)"
                  [ -n "$val" ] && break
                  sleep 2
                done
                if [ -n "$val" ]; then
                  printf '%s=%s\n' 'HOMEPAGE_VAR_${envVar}' "$val" >> "$tmp"
                else
                  echo "homepage-credentials: empty value for HOMEPAGE_VAR_${envVar} (sourceUnit=${cred.sourceUnit}), skipping" >&2
                fi
              '') credentials
            )}
            chmod 0400 "$tmp"
            mv "$tmp" "$out"
            # Homepage reads EnvironmentFile only at unit start, and a
            # credentials change doesn't bust the unit's drv hash, so a
            # plain `nixos-rebuild switch` won't bounce homepage on its
            # own. Cycle it explicitly on every credentials run (cheap —
            # homepage starts in ~1s). `--no-block` is required:
            # homepage-dashboard.service has After=homepage-credentials.service,
            # so a blocking try-restart enqueues a job that waits for *us*
            # to finish, deadlocking the unit forever. With --no-block,
            # systemd enqueues the restart and returns immediately, letting
            # this oneshot exit so the restart can actually proceed.
            ${pkgs.systemd}/bin/systemctl --no-block try-restart homepage-dashboard.service || true
          '';
        };

        services.homepage-dashboard.environmentFile = lib.mkIf hasCredentials credentialsEnvFile;

        systemd.services.homepage-dashboard = lib.mkIf hasCredentials {
          after = [ "homepage-credentials.service" ];
          wants = [ "homepage-credentials.service" ];
        };

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
