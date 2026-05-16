# Recyclarr - sync TRaSH-Guides custom formats and quality profiles into
# Sonarr/Radarr (https://github.com/recyclarr/recyclarr). Runs as a
# nightly oneshot before the *arr usage spike; no web UI, so no caddy /
# authentik wiring.
#
# Config lives in /etc/recyclarr/recyclarr.yml — declarative, fully
# expressible from Nix. API keys for sonarr/radarr come from sops via an
# EnvironmentFile and are pulled into the YAML by recyclarr's
# `!env_var` tag, so the on-disk config has no secrets.
#
# Dedicated `recyclarr` system user/group; the service only talks to
# the local *arr HTTP APIs and writes to its own state dir, so no NFS
# UID alignment is needed.
{ inputs, ... }:
let
  sopsFolder = (builtins.toString inputs.nix-secrets) + "/sops";
in
{
  flake.modules.nixos.recyclarr =
    {
      config,
      pkgs,
      hostSpec,
      ...
    }:
    {
      sops = {
        secrets = {
          "recyclarr/sonarr_api_key" = {
            sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          };
          "recyclarr/radarr_api_key" = {
            sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
          };
        };
        templates."recyclarr.env" = {
          content = ''
            SONARR_API_KEY=${config.sops.placeholder."recyclarr/sonarr_api_key"}
            RADARR_API_KEY=${config.sops.placeholder."recyclarr/radarr_api_key"}
          '';
          owner = "recyclarr";
        };
      };

      # Minimal TRaSH-Guides defaults. Sonarr WEB-1080p + anime profile;
      # Radarr HD Bluray + Web + UHD Bluray + Web. Adjust profiles in
      # tree as needed — these are the canonical TRaSH starter templates.
      environment.etc."recyclarr/recyclarr.yml".text = ''
        sonarr:
          main:
            base_url: http://127.0.0.1:8989
            api_key: !env_var SONARR_API_KEY

            delete_old_custom_formats: true
            replace_existing_custom_formats: true

            include:
              - template: sonarr-quality-definition-series
              - template: sonarr-v4-quality-profile-web-1080p
              - template: sonarr-v4-custom-formats-web-1080p

            quality_profiles:
              - name: WEB-1080p

        radarr:
          main:
            base_url: http://127.0.0.1:7878
            api_key: !env_var RADARR_API_KEY

            delete_old_custom_formats: true
            replace_existing_custom_formats: true

            include:
              - template: radarr-quality-definition-movie
              - template: radarr-quality-profile-hd-bluray-web
              - template: radarr-custom-formats-hd-bluray-web

            quality_profiles:
              - name: HD Bluray + WEB
      '';

      users.users.recyclarr = {
        isSystemUser = true;
        group = "recyclarr";
        home = "/var/lib/recyclarr";
        description = "recyclarr user";
      };
      users.groups.recyclarr = { };

      systemd.services.recyclarr = {
        description = "Recyclarr - sync TRaSH-Guides into Sonarr/Radarr";
        after = [
          "network-online.target"
          "sonarr.service"
          "radarr.service"
        ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = "recyclarr";
          Group = "recyclarr";
          StateDirectory = "recyclarr";
          EnvironmentFile = config.sops.templates."recyclarr.env".path;
          ExecStart = "${pkgs.recyclarr}/bin/recyclarr sync --app-data /var/lib/recyclarr --config /etc/recyclarr/recyclarr.yml";

          # Hardening — recyclarr only needs outbound HTTP to the *arr
          # APIs and writes to its own StateDirectory.
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectHostname = true;
          ProtectClock = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;
          PrivateNetwork = false;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
          ];
          NoNewPrivileges = true;
          RestrictSUIDSGID = true;
          RemoveIPC = true;
          CapabilityBoundingSet = "";
          LockPersonality = true;
          RestrictRealtime = true;
        };
      };

      systemd.timers.recyclarr = {
        description = "Run recyclarr nightly before *arr usage spike";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*-*-* 05:15:00";
          Persistent = true;
          RandomizedDelaySec = "30m";
        };
      };

      preservation.preserveAt."/persist".directories = [
        {
          directory = "/var/lib/recyclarr";
          user = "recyclarr";
          group = "recyclarr";
          mode = "0700";
        }
      ];
    };
}
