# OCI containers - Simple Aspect
# Podman backend for virtualisation.oci-containers. Backend-agnostic
# container declarations live in their own service modules.
#
# `myContainerApp.<name>` is the container analogue of `myCaddy.apps`
# (see caddy.nix): app modules declare the low-level plumbing that every
# containerized app repeats — the /var/lib/containers/<app> tmpfiles
# rules, the 127.0.0.1 host-port bind, the runtime user identity, and
# the TZ env — as a one-attr declaration here, and this module emits the
# corresponding `systemd.tmpfiles.rules` + `oci-containers.containers.*`
# fragments. App modules keep only what's genuinely app-specific (image,
# volumes, extra env). The `my`-prefix marks an option owned by this
# flake (vs upstream `virtualisation.*`).
_: {
  flake.modules.nixos.oci-containers =
    {
      config,
      hostSpec,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (hostSpec) serverUid serverGid;

      # node_exporter textfile collector drop dir (same path the rest of
      # the observability stack uses, see modules/system/victoriametrics.nix).
      textfileDir = "/var/lib/node-exporter-textfile-collector";

      # How much upstream release history to keep for images this
      # generation no longer references. Two weeks spans the weekly
      # `nixos-upgrade` cadence with margin, so rolling back to any
      # generation from the past couple of cycles still finds its images
      # locally instead of re-pulling. Longer costs real space on the
      # fast-moving repos (shelfmark is ~1.5 GB/tag, manyfold ~1.1 GB).
      retentionHours = 14 * 24;

      # Images the *current* generation declares, from every app module's
      # `virtualisation.oci-containers.containers.<app>.image` plus the
      # out-of-band refs contributed via `myPodmanPrune.keepImages`.
      # Written to a file rather than interpolated into the script so an
      # empty list stays valid shell.
      declaredImagesFile = pkgs.writeText "podman-prune-keep-images" (
        lib.concatMapStrings (ref: ref + "\n") (
          lib.unique (
            (lib.mapAttrsToList (_: c: c.image) config.virtualisation.oci-containers.containers)
            ++ config.myPodmanPrune.keepImages
          )
        )
      );
    in
    {
      options.myContainerApp = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, config, ... }:
            {
              options = {
                port = lib.mkOption {
                  type = lib.types.nullOr lib.types.port;
                  default = null;
                  description = ''
                    Host port to publish on 127.0.0.1. Left null for apps that
                    don't publish a host port at all (e.g. valheim, which uses
                    `--network=host` and opens UDP game ports on the firewall
                    directly) — no `ports` entry is emitted in that case.
                  '';
                };
                containerPort = lib.mkOption {
                  type = lib.types.nullOr lib.types.port;
                  default = config.port;
                  defaultText = lib.literalExpression "config.port";
                  description = "Port the app listens on inside the container. Defaults to `port`.";
                };
                stateDirs = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ "/var/lib/containers/${name}" ];
                  defaultText = lib.literalExpression ''[ "/var/lib/containers/''${name}" ]'';
                  description = ''
                    Host directories to create (0750, owned by stateDirOwner:stateDirGroup)
                    for this container's persistent state. Multi-subdir apps list every
                    subdir they bind-mount.
                  '';
                };
                stateDirOwner = lib.mkOption {
                  type = lib.types.str;
                  default = toString serverUid;
                  defaultText = lib.literalExpression "toString serverUid";
                  description = "Owner for the stateDirs tmpfiles rules. Defaults to the server user's uid.";
                };
                stateDirGroup = lib.mkOption {
                  type = lib.types.str;
                  default = toString serverGid;
                  defaultText = lib.literalExpression "toString serverGid";
                  description = "Group for the stateDirs tmpfiles rules. Defaults to the servers gid.";
                };
                tzEnv = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Emit `TZ = config.time.timeZone` in the container environment.";
                };
                manageUser = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = ''
                    Whether this module sets the container's runtime user identity.
                    Set false for images that take their uid/gid via app-specific env
                    vars the module doesn't model (e.g. grimmory's USER_ID/GROUP_ID) —
                    the app module then sets those itself.
                  '';
                };
                linuxServer = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = ''
                    Emit PUID/PGID env (server uid/gid) instead of a container
                    `user =` override, for images that start as root and drop
                    privileges themselves (linuxserver.io-style entrypoints).
                    Only meaningful when `manageUser` is true.
                  '';
                };
              };
            }
          )
        );
        default = { };
        description = ''
          Containerized apps' shared plumbing: per-app state dirs, the
          127.0.0.1 host-port bind, runtime user identity, and TZ. Mirrors
          `myCaddy.apps` — one declaration per app, emitted into
          `systemd.tmpfiles.rules` and `virtualisation.oci-containers.containers`.
        '';
      };

      options.myPodmanPrune.keepImages = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "ghcr.io/ianepreston/spierscraper:2026.07.17.1" ];
        description = ''
          Extra image references the prune must never remove, for images
          run outside `virtualisation.oci-containers` — a timer-driven
          `podman run --rm` oneshot has no container object between runs,
          so it is invisible to any liveness-based prune, and a
          nix-built image carries a SOURCE_DATE_EPOCH=0 manifest
          timestamp, so the age window matches it too. The
          oci-containers list is collected automatically; this is only
          for out-of-band callers. Declare it next to the `podman run`
          that uses the image so the ref and its renovate annotation stay
          in one place.
        '';
      };

      config = {
        # Guard the port-bind emitter above: it builds
        # "127.0.0.1:${port}:${containerPort}" whenever `port` is set, so a
        # null `containerPort` would emit a malformed bind ending in a bare
        # colon. `containerPort` defaults to `config.port`, so nothing trips
        # this today — it's a latent guard against a future app decoupling
        # the two.
        assertions = lib.mapAttrsToList (name: app: {
          assertion = app.port == null || app.containerPort != null;
          message = "myContainerApp.${name}: containerPort must not be null when port is set";
        }) config.myContainerApp;

        virtualisation = {
          podman = {
            enable = true;
            dockerCompat = true;
            defaultNetwork.settings.dns_enabled = true;
          };
          oci-containers.backend = "podman";

          # Per-app container fragments contributed via `myContainerApp.<name>`.
          # Each entry merges with the app module's own container definition
          # (image, volumes, extra env), which stays in the app module.
          oci-containers.containers = lib.mapAttrs (
            _: app:
            lib.mkMerge [
              (lib.optionalAttrs (app.port != null) {
                ports = [ "127.0.0.1:${toString app.port}:${toString app.containerPort}" ];
              })
              (lib.optionalAttrs (app.manageUser && app.linuxServer) {
                environment = {
                  PUID = toString serverUid;
                  PGID = toString serverGid;
                };
              })
              (lib.optionalAttrs (app.manageUser && !app.linuxServer) {
                user = "${toString serverUid}:${toString serverGid}";
              })
              (lib.optionalAttrs app.tzEnv {
                environment.TZ = config.time.timeZone;
              })
            ]
          ) config.myContainerApp;
        };

        # Containers on the default podman bridge reach host services
        # (postgres, etc.) via host.containers.internal -> 10.88.0.1.
        # Trust the bridge so the firewall doesn't drop those packets.
        networking.firewall.trustedInterfaces = [ "podman0" ];
        # Podman isn't allowed to forward packets from podman0 to the actual NIC by default
        boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
        boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;

        systemd = {
          # Parent directory for all containerized app state. Apps create their
          # own subdirs (/var/lib/containers/<app>) owned by the server user,
          # which lets a single backup path cover every app automatically.
          # Per-app subdirs come from `myContainerApp.<name>.stateDirs`.
          tmpfiles.rules = [
            "d /var/lib/containers 0755 root root -"
          ]
          ++ lib.concatLists (
            lib.mapAttrsToList (
              _: app: map (dir: "d ${dir} 0750 ${app.stateDirOwner} ${app.stateDirGroup} -") app.stateDirs
            ) config.myContainerApp
          );

          # ---- Image store garbage collection ------------------------------
          #
          # Nothing reclaimed podman's image store before #570: renovate
          # bumps image tags continuously and every superseded layer set
          # stayed forever (92 GB of /var/lib/containers/storage on hpp-1,
          # 88% of it unreferenced).
          #
          # Upstream's `virtualisation.podman.autoPrune` is deliberately not
          # used. It runs `podman system prune`, which has two properties
          # that are wrong here:
          #
          #   * "in use" means *a container object exists*. The
          #     oci-containers units `podman rm -f` in both ExecStartPre and
          #     ExecStopPost, so an app that is merely stopped protects
          #     nothing — and spierscraper, a nightly `podman run --rm`
          #     oneshot, has no container object 99% of the day. A windowed
          #     `prune -a` would delete its image every morning and re-pull
          #     it every night.
          #   * `system prune` also removes unused *networks*. On hosts with
          #     bambuddy that includes `iot-static`
          #     (modules/system/iot-network.nix), whose creator unit is
          #     `RemainAfterExit=true` — so unlike an image it does not come
          #     back on its own and bambuddy simply fails to start.
          #
          # So the keep-set is derived from the configuration instead of
          # from runtime liveness, and only images are touched.
          services.podman-image-prune = {
            description = "Prune podman images this generation no longer references";
            after = [ "podman.service" ];
            serviceConfig = {
              Type = "oneshot";
              User = "root";
              Environment = [
                "PATH=${
                  lib.makeBinPath [
                    pkgs.podman
                    pkgs.coreutils
                    pkgs.gnused
                  ]
                }"
              ];
            };
            script = ''
              set -euo pipefail

              work=$(mktemp -d)
              trap 'rm -rf "$work"' EXIT

              # Removal candidates: images built more than the retention
              # window ago. `until` filters on the build timestamp baked
              # into the image manifest, not on when this host pulled it,
              # so it is a "how much upstream release history to keep"
              # knob and nothing more. It is emphatically not a safety
              # net — when #570 was written, 8 of the 15 images backing
              # hpp-1's running apps had been built more than 14 days ago.
              podman images --filter "until=${toString retentionHours}h" --format '{{.ID}}' \
                | sed 's/^sha256://' | cut -c1-12 | sort -u >"$work/candidates"

              {
                # Every image the current generation declares. Refs are
                # resolved to IDs because one image can carry several tags
                # and a re-pull can move a tag off the image we still run
                # (digest-pinned apps show up as <none> in `podman
                # images`). A ref that was never pulled contributes
                # nothing, and says so on stderr.
                while read -r ref; do
                  [ -n "$ref" ] || continue
                  if ! podman image inspect --format '{{.Id}}' "$ref" 2>/dev/null; then
                    # Not fatal — an app that has never started has never
                    # pulled its image — but this is the one way the prune
                    # could drop something it should have kept, so say so
                    # rather than swallowing it.
                    echo "podman-image-prune: declared image $ref is not in the local store" >&2
                  fi
                done <${declaredImagesFile}

                # Backstop, not the primary guard: anything with a
                # container object attached right now. Covers images pulled
                # by hand outside the configuration; contributes nothing
                # for a stopped app, per the note above.
                podman ps -a --no-trunc --format '{{.ImageID}}'
              } | sed 's/^sha256://' | cut -c1-12 | sort -u >"$work/keep"

              comm -23 "$work/candidates" "$work/keep" >"$work/remove"

              removed=0
              skipped=0
              while read -r id; do
                [ -n "$id" ] || continue
                if podman rmi "$id" >/dev/null 2>&1; then
                  removed=$((removed + 1))
                else
                  # Unforced on purpose: `podman rmi` refuses an image a
                  # container picked up between the snapshot above and
                  # now. Log and carry on rather than failing the unit —
                  # the next run retries, and PodmanImageStoreLarge
                  # (modules/system/victoriametrics.nix) is the backstop if
                  # removals stop working outright.
                  echo "podman-image-prune: could not remove $id, leaving it in place" >&2
                  skipped=$((skipped + 1))
                fi
              done <"$work/remove"

              echo "podman-image-prune: removed $removed image(s), skipped $skipped"
            '';
          };

          timers.podman-image-prune = {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              # Placed after the `nixos-upgrade` window closes (04:40 plus
              # up to 1h of jitter, modules/system/auto-rebuild.nix) and
              # after any reboot it triggered has brought the containers
              # back up. That way last night's superseded tag is reclaimed
              # the same morning, and the freshly started containers
              # already hold their new images. Also clear of the 03:00
              # restic run and spierscraper's 04:05 (+15m) oneshot.
              #
              # Not Persistent: a missed run on a host that was down just
              # happens the next morning, which is better than pruning at
              # boot while the container units are still coming up.
              OnCalendar = "*-*-* 06:30:00";
              RandomizedDelaySec = "10m";
              Unit = "podman-image-prune.service";
            };
          };

          # Publish image store size as a node_exporter textfile metric.
          # The root filesystem is already covered by FilesystemAlmostFull,
          # but that fires late and does not say *why* — this attributes
          # the growth, and PodmanImageStoreLarge catches a prune that has
          # silently stopped reclaiming long before the disk rule would.
          services.podman-image-metrics = {
            description = "publish podman image store size to node_exporter textfile collector";
            after = [ "podman.service" ];
            serviceConfig = {
              Type = "oneshot";
              User = "root";
              Environment = [
                "PATH=${
                  lib.makeBinPath [
                    pkgs.podman
                    pkgs.jq
                    pkgs.coreutils
                  ]
                }"
              ];
            };
            script = ''
              set -eu
              out=${textfileDir}/podman-images.prom
              mkdir -p "$(dirname "$out")"

              # `podman system df` reports sizes podman already tracks
              # (~0.4s on a 125-image store); `du` over the overlay tree
              # takes ~13s and is not worth putting on a timer. It is
              # podman's own accounting, not a byte count of the
              # directory — RawSize sums per-image sizes (a shared layer
              # counted once per image) while the tree also holds
              # container rw layers and metadata it does not report.
              # Post-prune on hpp-1: RawSize 15 GB against 26 GB of
              # /var/lib/containers/storage. Good for attribution and
              # trend, not for exact space.
              stats=$(podman system df --format json \
                | jq -r '.[] | select(.Type == "Images") | "\(.Total) \(.Active) \(.RawSize) \(.RawReclaimable)"')
              if [ -z "$stats" ]; then
                echo "podman-image-metrics: podman system df reported no Images row" >&2
                exit 1
              fi
              # shellcheck disable=SC2086
              set -- $stats

              tmp=$(mktemp -p "$(dirname "$out")" .podman-images.prom.XXXXXX)
              {
                echo "# HELP podman_images_total Images present in the local podman store."
                echo "# TYPE podman_images_total gauge"
                echo "podman_images_total $1"
                echo "# HELP podman_images_active Images currently attached to a container."
                echo "# TYPE podman_images_active gauge"
                echo "podman_images_active $2"
                echo "# HELP podman_image_store_bytes Summed size of images in the local podman store (shared layers counted per image)."
                echo "# TYPE podman_image_store_bytes gauge"
                echo "podman_image_store_bytes $3"
                echo "# HELP podman_image_store_reclaimable_bytes Portion of podman_image_store_bytes podman considers unused."
                echo "# TYPE podman_image_store_reclaimable_bytes gauge"
                echo "podman_image_store_reclaimable_bytes $4"
              } > "$tmp"
              chmod 0644 "$tmp"
              mv "$tmp" "$out"
            '';
          };

          timers.podman-image-metrics = {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              # The store only moves on a pull or a prune, so 15m is plenty
              # of resolution. PodmanImageMetricsStale allows an hour, i.e.
              # roughly four missed runs.
              OnBootSec = "5m";
              OnUnitActiveSec = "15m";
              Unit = "podman-image-metrics.service";
            };
          };
        };
      };
    };
}
