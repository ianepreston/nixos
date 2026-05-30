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
      ...
    }:
    let
      port = 18080;
      sabnzbdHost = "sabnzbd.${hostSpec.serverDomain}";
      sabnzbdUser = "server-${hostSpec.serverEnvironment}";
      serverUid = config.users.users.${sabnzbdUser}.uid;
      serverGid = config.users.groups.servers.gid;
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

      systemd.services.apprise-sabnzbd-config = {
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
          # consumes directly).
          discord_path="''${DISCORD_WEBHOOK#https://discord.com/api/webhooks/}"
          cat > ${appriseConfigFile} <<EOF
          urls:
            - discord://$discord_path
          EOF
          chown ${toString serverUid}:${toString serverGid} ${appriseConfigFile}
          chmod 0640 ${appriseConfigFile}
        '';
      };

    };
}
