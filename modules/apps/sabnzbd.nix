# Sabnzbd - usenet downloader
# Native services.sabnzbd from nixpkgs (Python service; user/group
# overridden to the shared server-${env}:servers user so writes
# against /mnt/content/Downloads keep their NFS UID alignment).
# auth/caddy/homepage wiring is generated from
# `myAuthentik.forwardAuthApps.sabnzbd` by modules/platform/authentik.nix.
#
# Sabnzbd refuses any HTTP request whose Host header doesn't match the
# local hostname or an entry in `host_whitelist`. The home-operations
# container baked an entrypoint that re-applied
# SABNZBD__HOST_WHITELIST_ENTRIES to the .ini on every start; we
# reproduce that behaviour with a one-shot that patches sabnzbd.ini
# before sabnzbd.service comes up. The oneshot also pins
# `host = 0.0.0.0` so co-located containers (e.g. shelfarr) can reach
# sabnzbd via `host.containers.internal:8080` — without that the
# service binds to 127.0.0.1 only and bridge traffic gets refused at
# the TCP layer. `host.containers.internal` is whitelisted alongside
# the public FQDN for the same reason.
_: {
  flake.modules.nixos.sabnzbd =
    {
      config,
      hostSpec,
      ...
    }:
    let
      port = 8080;
      sabnzbdHost = "sabnzbd.${hostSpec.serverDomain}";
      sabnzbdUser = "server-${hostSpec.serverEnvironment}";
      iniFile = "/var/lib/sabnzbd/sabnzbd.ini";
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
        };
      };

      services.sabnzbd = {
        enable = true;
        user = sabnzbdUser;
        group = "servers";
      };

      preservation.preserveAt."/persist".directories = [ "/var/lib/sabnzbd" ];

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
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          EnvironmentFile = config.sops.templates."apprise-sabnzbd.env".path;
        };
        script = ''
          set -e
          install -d -m 0750 -o ${toString serverUid} -g ${toString serverGid} ${appriseConfigDir}
          umask 027
          cat > ${appriseConfigFile} <<EOF
          urls:
            - $DISCORD_WEBHOOK
          EOF
          chown ${toString serverUid}:${toString serverGid} ${appriseConfigFile}
          chmod 0640 ${appriseConfigFile}
        '';
      };

      # Reapplies host + host_whitelist on every start (idempotent),
      # matching what the home-operations entrypoint used to do via
      # SABNZBD__HOST_WHITELIST_ENTRIES. Creates a minimal [misc] block
      # if the .ini is missing entirely (clean install).
      systemd.services.sabnzbd-host-whitelist = {
        description = "Pin sabnzbd bind host and host_whitelist";
        before = [ "sabnzbd.service" ];
        wantedBy = [ "sabnzbd.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -e
          ini=${iniFile}
          # Scope substitution to one section — sabnzbd's `[servers]`
          # subsections also use `host = …` (the upstream usenet
          # provider), and an unscoped sed would overwrite those.
          pin_kv() {
            section=$1
            key=$2
            val=$3
            if sed -n "/^\[$section\]/,/^\[/p" "$ini" | grep -q "^$key *="; then
              sed -i "/^\[$section\]/,/^\[/{s|^$key *=.*|$key = $val|}" "$ini"
            else
              sed -i "/^\[$section\]/a $key = $val" "$ini"
            fi
          }
          ensure_section() {
            section=$1
            if ! grep -q "^\[$section\]" "$ini"; then
              printf '\n[%s]\n' "$section" >> "$ini"
            fi
          }
          if [ -f "$ini" ]; then
            ensure_section misc
            pin_kv misc host 0.0.0.0
            pin_kv misc host_whitelist '${sabnzbdHost},host.containers.internal'
            ensure_section apprise
            pin_kv apprise apprise_enable 1
            pin_kv apprise apprise_urls '${appriseUrl}'
          else
            install -d -m 0750 -o ${sabnzbdUser} -g servers /var/lib/sabnzbd
            cat > "$ini" <<EOF
          [misc]
          host = 0.0.0.0
          host_whitelist = ${sabnzbdHost},host.containers.internal

          [apprise]
          apprise_enable = 1
          apprise_urls = ${appriseUrl}
          EOF
            chown ${sabnzbdUser}:servers "$ini"
            chmod 0640 "$ini"
          fi
        '';
      };
    };
}
