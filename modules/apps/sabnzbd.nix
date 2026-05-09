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
# before sabnzbd.service comes up. Once the file exists, the user can
# edit host_whitelist freely from the UI — this oneshot only enforces
# the FQDN entry on the [misc] section, leaving everything else alone.
_: {
  flake.modules.nixos.sabnzbd =
    { hostSpec, ... }:
    let
      port = 8080;
      sabnzbdHost = "sabnzbd.${hostSpec.serverDomain}";
      sabnzbdUser = "server-${hostSpec.serverEnvironment}";
      iniFile = "/var/lib/sabnzbd/sabnzbd.ini";
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

      services.restic.backups.server.paths = [ "/var/lib/sabnzbd" ];

      systemd.services.sabnzbd-migrate-state = {
        description = "Migrate sabnzbd state from container layout";
        before = [ "sabnzbd.service" ];
        wantedBy = [ "sabnzbd.service" ];
        unitConfig.ConditionPathExists = "/var/lib/containers/sabnzbd";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          if [ ! -e /var/lib/sabnzbd ] || [ -z "$(ls -A /var/lib/sabnzbd 2>/dev/null)" ]; then
            rm -rf /var/lib/sabnzbd
            mv /var/lib/containers/sabnzbd /var/lib/sabnzbd
          fi
        '';
      };

      # Reapplies host_whitelist on every start (idempotent), matching
      # what the home-operations entrypoint used to do via
      # SABNZBD__HOST_WHITELIST_ENTRIES. Creates a minimal [misc] block
      # if the .ini is missing entirely (clean install).
      systemd.services.sabnzbd-host-whitelist = {
        description = "Pin sabnzbd host_whitelist to the public FQDN";
        before = [ "sabnzbd.service" ];
        wantedBy = [ "sabnzbd.service" ];
        after = [ "sabnzbd-migrate-state.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -e
          ini=${iniFile}
          if [ -f "$ini" ]; then
            if grep -q '^\[misc\]' "$ini"; then
              if grep -q '^host_whitelist' "$ini"; then
                sed -i 's|^host_whitelist.*|host_whitelist = ${sabnzbdHost}|' "$ini"
              else
                sed -i '/^\[misc\]/a host_whitelist = ${sabnzbdHost}' "$ini"
              fi
            else
              printf '\n[misc]\nhost_whitelist = ${sabnzbdHost}\n' >> "$ini"
            fi
          else
            install -d -m 0750 -o ${sabnzbdUser} -g servers /var/lib/sabnzbd
            cat > "$ini" <<EOF
          [misc]
          host_whitelist = ${sabnzbdHost}
          EOF
            chown ${sabnzbdUser}:servers "$ini"
            chmod 0640 "$ini"
          fi
        '';
      };
    };
}
