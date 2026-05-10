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
# `host = 0.0.0.0` so co-located containers (e.g. shelfmark) can reach
# sabnzbd via `host.containers.internal:8080` — without that the
# service binds to 127.0.0.1 only and bridge traffic gets refused at
# the TCP layer. `host.containers.internal` is whitelisted alongside
# the public FQDN for the same reason.
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
          # Scope substitution to the [misc] section — sabnzbd's
          # `[servers]` subsections also use `host = …` (the upstream
          # usenet provider), and an unscoped sed would overwrite
          # those.
          pin_kv() {
            key=$1
            val=$2
            if sed -n '/^\[misc\]/,/^\[/p' "$ini" | grep -q "^$key *="; then
              sed -i "/^\[misc\]/,/^\[/{s|^$key *=.*|$key = $val|}" "$ini"
            else
              sed -i "/^\[misc\]/a $key = $val" "$ini"
            fi
          }
          if [ -f "$ini" ]; then
            if ! grep -q '^\[misc\]' "$ini"; then
              printf '\n[misc]\n' >> "$ini"
            fi
            pin_kv host 0.0.0.0
            pin_kv host_whitelist '${sabnzbdHost},host.containers.internal'
          else
            install -d -m 0750 -o ${sabnzbdUser} -g servers /var/lib/sabnzbd
            cat > "$ini" <<EOF
          [misc]
          host = 0.0.0.0
          host_whitelist = ${sabnzbdHost},host.containers.internal
          EOF
            chown ${sabnzbdUser}:servers "$ini"
            chmod 0640 "$ini"
          fi
        '';
      };
    };
}
