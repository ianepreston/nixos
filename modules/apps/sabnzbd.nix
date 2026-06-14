# Sabnzbd - usenet downloader
# Native services.sabnzbd from nixpkgs (Python service; user/group
# overridden to the shared server-${env}:servers user so writes
# against /mnt/content/Downloads keep their NFS UID alignment).
# auth/caddy/homepage wiring is generated from
# `myAuthentik.forwardAuthApps.sabnzbd` by modules/apps/authentik.nix.
#
# Sabnzbd refuses any HTTP request whose Host header doesn't match the
# local hostname or an entry in `host_whitelist`. The home-operations
# container baked an entrypoint that re-applied
# SABNZBD__HOST_WHITELIST_ENTRIES to the .ini on every start; we get
# the same effect by pinning host/host_whitelist via
# `services.sabnzbd.settings` — the module's preStart merges these on
# top of the existing on-disk ini (allowConfigWrite is true on
# stateVersion < 26.05, so user-editable values like usenet provider
# credentials are preserved). `host = 0.0.0.0` lets co-located
# containers (e.g. shelfarr) reach sabnzbd via
# `host.containers.internal:<port>`; without that the service binds
# to 127.0.0.1 only and bridge traffic gets refused at the TCP layer.
# `host.containers.internal` is whitelisted alongside the public FQDN
# for the same reason.
#
# Port is 18080, not the sabnzbd default 8080, because UniFi's
# adoption inform endpoint owns :8080 on this host. See
# modules/apps/unifi.nix.
_: {
  flake.modules.nixos.sabnzbd =
    {
      config,
      hostSpec,
      pkgs,
      ...
    }:
    let
      port = 18080;
      sabnzbdHost = "sabnzbd.${hostSpec.serverDomain}";
      sabnzbdUser = "server-${hostSpec.serverEnvironment}";
      serverUid = config.users.users.${sabnzbdUser}.uid;
      serverGid = config.users.groups.servers.gid;
      # incomplete/ lives on the local SSD, not the NFS share. par2
      # verify and unrar then read it back without bouncing TLS-wrapped
      # NFS RX against simultaneous NFS TX. Sibling of /var/lib/sabnzbd
      # so it's NOT pulled into restic (restic snapshots /var/lib/sabnzbd
      # only). Preserved via /persist (bind mount below) but ephemeral
      # in intent — partial downloads aren't worth keeping across reboots
      # except for in-flight resume. See #276.
      incompleteDir = "/var/lib/sabnzbd-incomplete";
      # Textfile collector — set in modules/system/victoriametrics.nix.
      # Kept in sync by hand; both modules live on the same hosts.
      textfileDir = "/var/lib/node-exporter-textfile-collector";
      appriseConfigDir = "/var/lib/containers/apprise/config";
      appriseConfigFile = "${appriseConfigDir}/sabnzbd.yml";
      # Apprise URL pointing the local apprise lib at our apprise-api
      # container under the `sabnzbd` stateful key; apprise-api fans
      # this out to whatever URLs sabnzbd.yml lists (currently the
      # shared discord alerts webhook).
      appriseUrl = "apprise://localhost:8002/sabnzbd";
    in
    {
      myAuthentik.forwardAuthApps.sabnzbd = {
        inherit port;
        displayName = "Sabnzbd";
        homepage = {
          group = "Acquisition";
          icon = "sabnzbd";
          description = "Usenet downloader";
          widget = {
            type = "sabnzbd";
            url = "http://localhost:${toString port}";
            key = "{{HOMEPAGE_VAR_SABNZBD_API_KEY}}";
          };
        };
      };

      myHomepage.credentials.SABNZBD_API_KEY = {
        sourceUnit = "sabnzbd.service";
        readScript = ''
          awk -F= '/^[[:space:]]*api_key[[:space:]]*=/ { gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit }' /var/lib/sabnzbd/sabnzbd.ini
        '';
      };

      services.sabnzbd = {
        enable = true;
        user = sabnzbdUser;
        group = "servers";
        # Opt out of the stateVersion < 26.05 default that points
        # configFile at /var/lib/sabnzbd/sabnzbd.ini (deprecated). With
        # null + allowConfigWrite=true (also a stateVersion < 26.05
        # default), the module's preStart merges existing-ini ⊕ settings
        # ⊕ secretFiles on each start — same behaviour as the old
        # host_whitelist oneshot, minus the bespoke sed.
        configFile = null;
        settings = {
          misc = {
            host = "0.0.0.0";
            inherit port;
            host_whitelist = "${sabnzbdHost},host.containers.internal";
            # RAM article cache. Pinned here because the nixpkgs module
            # declares cache_limit as an option with default "" and that
            # empty default is rendered into public-settings.ini, which the
            # preStart merge layers *over* the on-disk ini — so a UI-set
            # value silently reverts to empty on every restart (same fate as
            # any other declared-with-default misc field). sabnzbd recommends
            # ~25% of RAM; 2G suits the 8GB+ servers this runs on. Empty
            # cache means every article is written to disk before assembly.
            cache_limit = "2G";
            # Incomplete on local SSD; finished media gets renamed onto
            # the NFS share by sabnzbd's post-processing step. See #276
            # for the throughput story (par2 + direct_unpack reading
            # incomplete back over NFS was eating ~30 MB/s on amos1).
            download_dir = incompleteDir;
          };
          # Codified per-account connection caps (#276). The .ini is
          # writable (allowConfigWrite=true on stateVersion<26.05), so
          # operator-side tuning sticks, but the canonical value lives
          # here so a fresh deploy doesn't silently revert to the
          # provider's default. Only `connections` is set here; other
          # fields (port, ssl, credentials) come from the on-disk ini
          # via the module's preStart merge.
          servers."news.frugalusenet.com" = {
            name = "news.frugalusenet.com";
            displayname = "news.frugalusenet.com";
            host = "news.frugalusenet.com";
            # ~50 saturates frugal's per-account throughput ceiling
            # (~40-50 MB/s); past that, extra conns just pay TLS
            # overhead without adding bandwidth. See the issue thread.
            connections = 50;
          };
          apprise = {
            apprise_enable = 1;
            apprise_urls = appriseUrl;
          };
        };
      };

      preservation.preserveAt."/persist".directories = [
        {
          directory = "/var/lib/sabnzbd";
          user = sabnzbdUser;
          group = "servers";
          mode = "0700";
        }
        # Incomplete dir: bind-mounted from /persist so partial downloads
        # survive a reboot (sabnzbd resumes them on start). Not added to
        # `restic.backups.server.paths` — there's nothing worth a backup
        # in a half-finished NZB unpack.
        {
          directory = incompleteDir;
          user = sabnzbdUser;
          group = "servers";
          mode = "0700";
        }
      ];

      services.restic.backups.server.paths = [ "/var/lib/sabnzbd" ];

      # Apprise notifications. sabnzbd's bundled apprise library posts
      # to our apprise-api container under the `sabnzbd` stateful key;
      # apprise-api itself reads /config/sabnzbd.yml (rendered below)
      # to decide where to fan out. Wiring lives here, not in
      # apprise.nix, so the destination travels with sabnzbd's module
      # and apprise stays unaware of who its consumers are.
      sops.templates."apprise-sabnzbd.env" = {
        content = ''
          DISCORD_WEBHOOK=${config.sops.placeholder."discord/alerts_webhook"}
        '';
        restartUnits = [ "apprise-sabnzbd-config.service" ];
      };

      systemd = {
        # Make sure incompleteDir exists before sabnzbd starts (the
        # preservation bind-mount creates the path, but only on
        # impermanence hosts; tmpfiles covers the non-impermanent case
        # and pins ownership either way).
        tmpfiles.rules = [
          "d ${incompleteDir} 0700 ${sabnzbdUser} servers - -"
        ];

        services = {
          sabnzbd.path = [ (pkgs.python3.withPackages (ps: [ ps.requests ])) ];
          # Publish two textfile-collector metrics for #276's alerts:
          #   sabnzbd_incomplete_oldest_seconds — age of the oldest file
          #     in the incomplete dir. >24h is a stalled download /
          #     wedged post-processor / forgotten paused queue.
          #   sabnzbd_incomplete_dir_bytes — total size of the incomplete
          #     dir. Threshold rule in modules/system/victoriametrics.nix
          #     covers the "shared with /persist, no dedicated mount" case
          #     (issue's option (a/b), not (c)).
          # Atomic write via tempfile + rename so a crashed run never
          # leaves a partial `.prom` for node_exporter to scrape.
          sabnzbd-incomplete-metrics = {
            description = "publish sabnzbd incomplete-dir metrics to node_exporter textfile collector";
            serviceConfig = {
              Type = "oneshot";
              User = "root";
              Environment = [
                "INCOMPLETE_DIR=${incompleteDir}"
                "OUT=${textfileDir}/sabnzbd.prom"
                "PATH=${
                  pkgs.lib.makeBinPath [
                    pkgs.coreutils
                    pkgs.findutils
                    pkgs.gawk
                  ]
                }"
              ];
            };
            script = ''
              set -eu
              oldest=0
              if [ -d "$INCOMPLETE_DIR" ]; then
                oldest_mtime=$(find "$INCOMPLETE_DIR" -type f -printf '%T@\n' 2>/dev/null | sort -n | head -1 || true)
                if [ -n "$oldest_mtime" ]; then
                  now=$(date +%s)
                  oldest=$(awk -v now="$now" -v t="$oldest_mtime" 'BEGIN { printf "%d", now - t }')
                fi
              fi
              bytes=$(du -sb "$INCOMPLETE_DIR" 2>/dev/null | awk '{print $1}')
              : ''${bytes:=0}
              tmp=$(mktemp -p "$(dirname "$OUT")" .sabnzbd.prom.XXXXXX)
              {
                echo "# HELP sabnzbd_incomplete_oldest_seconds Age in seconds of the oldest file under sabnzbd's incomplete dir."
                echo "# TYPE sabnzbd_incomplete_oldest_seconds gauge"
                echo "sabnzbd_incomplete_oldest_seconds $oldest"
                echo "# HELP sabnzbd_incomplete_dir_bytes Total bytes under sabnzbd's incomplete dir."
                echo "# TYPE sabnzbd_incomplete_dir_bytes gauge"
                echo "sabnzbd_incomplete_dir_bytes $bytes"
              } > "$tmp"
              chmod 0644 "$tmp"
              mv "$tmp" "$OUT"
            '';
          };

          apprise-sabnzbd-config = {
            description = "Render apprise stateful config for sabnzbd";
            wantedBy = [ "multi-user.target" ];
            before = [ "podman-apprise.service" ];
            # Explicit ordering on the sops decryption unit
            # (sops.useSystemdActivation = true in modules/system/sops.nix).
            # Without this, EnvironmentFile= points at
            # /run/secrets/rendered/apprise-sabnzbd.env before sops has
            # rendered the template, the unit fails with "Failed to load
            # environment files", and only the sops template's restartUnits
            # hook (which fires after rendering) recovers it ~minutes later.
            # See #194. ConditionPathExists below belt-and-suspenders the
            # case where sops *finishes* but this specific render failed.
            after = [ "sops-install-secrets.service" ];
            wants = [ "sops-install-secrets.service" ];
            unitConfig.ConditionPathExists = config.sops.templates."apprise-sabnzbd.env".path;
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              EnvironmentFile = config.sops.templates."apprise-sabnzbd.env".path;
            };
            script = ''
              set -e
              install -d -m 0750 -o ${toString serverUid} -g ${toString serverGid} ${appriseConfigDir}
              umask 027
              # Apprise needs Discord webhooks in discord://ID/TOKEN form,
              # not the raw https URL stored in sops (which alertmanager
              # consumes directly). Discord accepts (and pastes from its UI)
              # both discord.com and the legacy discordapp.com hostnames, so
              # strip either prefix — the second expansion is a no-op when
              # the first matched.
              discord_path="''${DISCORD_WEBHOOK#https://discord.com/api/webhooks/}"
              discord_path="''${discord_path#https://discordapp.com/api/webhooks/}"
              cat > ${appriseConfigFile} <<EOF
              urls:
                - discord://$discord_path
              EOF
              chown ${toString serverUid}:${toString serverGid} ${appriseConfigFile}
              chmod 0640 ${appriseConfigFile}
            '';
          };
        };

        timers.sabnzbd-incomplete-metrics = {
          description = "Periodic sabnzbd incomplete-dir metrics refresh";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            # 5m matches the SabnzbdIncompleteStale `for: 30m` window —
            # plenty of samples to debounce, low enough to surface a
            # newly-stalled download within an hour.
            OnBootSec = "2m";
            OnUnitActiveSec = "5m";
            AccuracySec = "30s";
          };
        };
      };

    };
}
