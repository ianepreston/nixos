# Wealthfolio - personal investment and net-worth tracker (#835).
#
# Native `services.wealthfolio` and `wealthfolio-server` arrive only in
# nixos-unstable, so this imports the matching upstream module and package while
# leaving the rest of the hosts on the tracked stable channel. The service uses
# DynamicUser; its StateDirectory's real storage is therefore
# /var/lib/private/wealthfolio, not the public symlink under /var/lib.
#
# Wealthfolio's own password login stays off because Caddy's Authentik
# forward-auth is the sole login boundary and the listener is loopback-only.
# `secret_key` still protects encrypted broker credentials/API keys at rest and
# signs the app's JWTs, so losing it makes those encrypted values unrecoverable.
{ inputs, ... }:
{
  flake.modules.nixos.wealthfolio =
    {
      config,
      hostSpec,
      pkgs,
      ...
    }:
    let
      port = 8093;
      stateDir = "/var/lib/private/wealthfolio";
      wealthfolioHost = "wealthfolio.${hostSpec.serverDomain}";
      pkgsUnstable = import inputs.nixpkgs-unstable {
        inherit (pkgs.stdenv.hostPlatform) system;
        inherit (pkgs) config;
      };
    in
    {
      # Stable has only the Tauri desktop package. Its server module appeared
      # after the stable branch, so import it with the matching package.
      imports = [ "${inputs.nixpkgs-unstable}/nixos/modules/services/web-apps/wealthfolio.nix" ];

      myObservability.monitoredSystemdUnits = [ "wealthfolio" ];

      myAuthentik.forwardAuthApps.wealthfolio = {
        inherit port;
        displayName = "Wealthfolio";
        authentikGroup = "Home";
        homepage = {
          group = "Home";
          icon = "wealthfolio";
          description = "Investment tracker";
        };
      };

      sops.secrets."wealthfolio/secret_key" = {
        inherit (hostSpec) sopsFile;
        restartUnits = [ "wealthfolio.service" ];
      };

      services.wealthfolio = {
        enable = true;
        package = pkgsUnstable.wealthfolio-server;
        inherit port;
        secretKeyFile = config.sops.secrets."wealthfolio/secret_key".path;
        authRequired = false;
        corsAllowOrigins = "https://${wealthfolioHost}";
      };

      # DynamicUser + StateDirectory stores data at the private path. Leave
      # ownership to systemd's id-mapped mount, as with matter-server.
      myAppState.wealthfolio = {
        inherit stateDir;
        user = null;
        group = null;
      };

      # 3.9 keeps one database per profile under a UUID it generates on first
      # start; WF_DB_PATH only names a legacy file to adopt, which never existed
      # here. Glob it so the quiesce follows whichever profile the host has.
      mySqliteQuiesce.apps.wealthfolio.databases = [ "${stateDir}/profiles/*/app.db" ];

      myRecovery.apps.wealthfolio = {
        kind = "sqlite";
        order = 285;
        units = [ "wealthfolio.service" ];
        paths = [ stateDir ];
        # DynamicUser's id-mapped StateDirectory persists files as nobody.
        sqliteOwner = "nobody";
        health.url = "http://127.0.0.1:${toString port}/api/v1/healthz";
      };
    };
}
