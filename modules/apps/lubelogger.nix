# LubeLogger - vehicle service / fuel / reminder tracker (#802).
# Native NixOS module (services.lubelogger); nixpkgs ships it on the
# tracked stable channel, so no container.
#
# Postgres: peer auth over /run/postgresql. The module runs as the
# static `lubelogger` system user, which matches the role name, so
# Npgsql's socket connection needs no password (homeassistant's recorder
# is the same shape). /var/lib/lubelogger still holds uploaded documents,
# images, root's user config and the ASP.NET data-protection keys that
# sign login cookies, hence myAppState.
#
# Auth. LubeLogger has a root user outside its user table, configured by
# `UserNameHash` / `UserPasswordHash` (sha256 hex of the plaintext):
#
#   * Day to day you log in via authentik as root: EnableRootUserOIDC
#     makes an OIDC login whose email claim equals `DefaultReminderEmail`
#     the root user. That email is the operator's, so it comes from sops
#     (`lubelogger/root_email`), never from this file.
#   * The root username/password are random sops values. They are the
#     break-glass login (regular login is hidden, but /Login still takes
#     them if OIDC is down — see `LogOutURL` below) and the notifier's
#     API credentials (Basic auth), so there is no API key to mint in the
#     UI after first boot.
#   * The hashes reach the app through LUBELOGGER_SECRETS_PATH, the
#     app's own key-per-file config source, written by a pre-start into
#     a tmpfs. That source is layered *above* data/config/userConfig.json,
#     which matters: root saving its preferences copies the current
#     hashes into that JSON file, and a source layered below it (plain
#     env) would then keep the old hash after a sops rotation.
#
# OIDC: `DisableRegularLogin` only auto-redirects /Login to the IdP when
# `LogOutURL` is set too (LoginController.Index), so both are set.
#
# Server config is declarative. The UI's server settings page writes
# data/config/serverConfig.json, which is layered above the environment
# and would silently override everything set here (postgres, OIDC,
# domain). The pre-start deletes it, so a UI change there lasts until
# the next restart; make the change in this file instead.
#
# Due-service reminders: LubeLogger's webhook fires only on record CRUD
# and its due-reminder delivery is email, so lubelogger-reminders.timer
# polls the API daily and posts tier changes to Discord. See
# _lubelogger/reminder-notify.py.
_: {
  flake.modules.nixos.lubelogger =
    {
      config,
      hostSpec,
      pkgs,
      ...
    }:
    let
      lubeloggerHost = "lubelogger.${hostSpec.serverDomain}";
      authentikOidc = "https://authentik.${hostSpec.serverDomain}/application/o";
      port = 8092;
      stateDir = "/var/lib/lubelogger";
      secretsDir = "/run/lubelogger/secrets";

      # doCheck = false: ruff (git-hooks.nix) is the single Python authority;
      # writePython3's flake8 pass conflicts with ruff-format's W503 style.
      # See modules/apps/llm-metrics.nix for the full rationale.
      reminderNotify = pkgs.writers.writePython3 "lubelogger-reminder-notify" {
        doCheck = false;
      } (builtins.readFile ./_lubelogger/reminder-notify.py);
    in
    {
      myObservability.monitoredSystemdUnits = [
        "lubelogger"
        "lubelogger-reminders"
      ];

      myRecovery.apps.lubelogger = {
        kind = "postgres";
        order = 115;
        units = [ "lubelogger.service" ];
        paths = [ stateDir ];
        database = "lubelogger";
        # Anonymous, and reports `fail` (HTTP 500) when the database
        # check fails, so a restore that left postgres unreachable fails
        # the health gate rather than passing on a rendered login page.
        health.url = "http://127.0.0.1:${toString port}/health";
      };

      myAppState.lubelogger = {
        inherit stateDir;
        user = "lubelogger";
        group = "lubelogger";
      };

      myAuthentik.oidcApps.lubelogger = {
        blueprintsDir = ./lubelogger-blueprints;
        appRestartUnit = [ "lubelogger.service" ];
        clientIdVar = "OpenIDConfig__ClientId";
        clientSecretVar = "OpenIDConfig__ClientSecret";
        extraSecrets."lubelogger/root_email".sopsFile = hostSpec.sopsFile;
        extraEnvLines = ''
          DefaultReminderEmail=${config.sops.placeholder."lubelogger/root_email"}
        '';
        homepage = {
          group = "Home";
          icon = "lubelogger";
          description = "Vehicle service tracker";
        };
        displayName = "LubeLogger";
      };

      sops.secrets = {
        # Consumed by path (LoadCredential below), not through a template,
        # so the restart trigger lives on the secrets themselves.
        "lubelogger/root_username" = {
          inherit (hostSpec) sopsFile;
          restartUnits = [ "lubelogger.service" ];
        };
        "lubelogger/root_password" = {
          inherit (hostSpec) sopsFile;
          restartUnits = [ "lubelogger.service" ];
        };
        # Read fresh on every timer run; nothing to restart.
        "discord/lubelogger_webhook".sopsFile = hostSpec.sopsFile;
      };

      services = {
        postgresql = {
          ensureDatabases = [ "lubelogger" ];
          ensureUsers = [
            {
              name = "lubelogger";
              ensureDBOwnership = true;
            }
          ];
        };

        lubelogger = {
          enable = true;
          inherit port;
          environmentFile = config.sops.templates."lubelogger.env".path;
          settings = {
            POSTGRES_CONNECTION = "Host=/run/postgresql;Username=lubelogger;Database=lubelogger";
            LUBELOGGER_DOMAIN = "https://${lubeloggerHost}";
            LUBELOGGER_SECRETS_PATH = secretsDir;
            # Metric household: dates/currency as en-CA (yyyy-MM-dd, $),
            # and root's default fuel-economy unit as L/100km. UseMPG is a
            # per-user preference, so this is only root's starting value.
            LUBELOGGER_LOCALE_OVERRIDE = "en-CA";
            UseMPG = "false";

            EnableAuth = "true";
            EnableRootUserOIDC = "true";

            OpenIDConfig__Name = "Authentik";
            OpenIDConfig__AuthURL = "${authentikOidc}/authorize/";
            OpenIDConfig__TokenURL = "${authentikOidc}/token/";
            OpenIDConfig__UserInfoURL = "${authentikOidc}/userinfo/";
            OpenIDConfig__JwksURL = "${authentikOidc}/lubelogger/jwks/";
            OpenIDConfig__LogOutURL = "${authentikOidc}/lubelogger/end-session/";
            OpenIDConfig__RedirectURL = "https://${lubeloggerHost}/Login/RemoteAuth";
            OpenIDConfig__Scope = "openid email profile";
            OpenIDConfig__UsePKCE = "true";
            OpenIDConfig__ValidateState = "true";
            OpenIDConfig__DisableRegularLogin = "true";
          };
        };
      };

      systemd = {
        services.lubelogger = {
          after = [
            "postgresql.service"
            "postgresql-setup.service"
          ];
          wants = [
            "postgresql.service"
            "postgresql-setup.service"
          ];
          serviceConfig = {
            RuntimeDirectory = "lubelogger";
            RuntimeDirectoryMode = "0700";
            LoadCredential = [
              "root_username:${config.sops.secrets."lubelogger/root_username".path}"
              "root_password:${config.sops.secrets."lubelogger/root_password".path}"
            ];
          };
          preStart = ''
            rm -f data/config/serverConfig.json
            mkdir -p ${secretsDir}
            sha() { printf '%s' "$(cat "$CREDENTIALS_DIRECTORY/$1")" | sha256sum | cut -d' ' -f1; }
            sha root_username > ${secretsDir}/UserNameHash
            sha root_password > ${secretsDir}/UserPasswordHash
          '';
        };

        services.lubelogger-reminders = {
          description = "Post due LubeLogger service reminders to Discord";
          after = [ "lubelogger.service" ];
          wants = [ "lubelogger.service" ];
          serviceConfig = {
            Type = "oneshot";
            User = "lubelogger";
            Group = "lubelogger";
            ExecStart = reminderNotify;
            # Inside the app's preserved + backed-up state dir, so dedupe
            # survives a reboot without a second myAppState entry.
            StateDirectory = "lubelogger/reminder-notify";
            LoadCredential = [
              "root_username:${config.sops.secrets."lubelogger/root_username".path}"
              "root_password:${config.sops.secrets."lubelogger/root_password".path}"
              "webhook:${config.sops.secrets."discord/lubelogger_webhook".path}"
            ];
            Environment = [
              "LUBELOGGER_URL=http://127.0.0.1:${toString port}"
              "LUBELOGGER_PUBLIC_URL=https://${lubeloggerHost}"
              "STATE_FILE=${stateDir}/reminder-notify/state.json"
            ];
          };
        };

        timers.lubelogger-reminders = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "*-*-* 08:00:00";
            # Catch up after a host was down at 08:00.
            Persistent = true;
            Unit = "lubelogger-reminders.service";
          };
        };
      };

      myCaddy.apps.lubelogger = {
        host = lubeloggerHost;
        routeConfig = ''
          reverse_proxy localhost:${toString port}
        '';
      };
    };
}
