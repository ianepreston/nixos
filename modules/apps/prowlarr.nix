# Prowlarr - indexer aggregator for the *arr stack
# Native services.prowlarr from nixpkgs, with the upstream DynamicUser
# overridden to a static "prowlarr" system user (UID 891). DynamicUser
# allocates a fresh UID after `bootstrap:reinstall` against a preserved
# /persist, which leaves the persisted state dir owned by the old UID
# and unwritable — pinning the UID statically makes that recovery path
# deterministic. State lives at /var/lib/prowlarr (the StateDirectory
# resolves to the real path, not the DynamicUser /var/lib/private/
# symlink).
# auth/caddy/homepage wiring is generated from
# `myAuthentik.forwardAuthApps.prowlarr` by modules/apps/authentik.nix.
_: {
  flake.modules.nixos.prowlarr =
    { lib, ... }:
    let
      port = 9696;
      uid = 891;
    in
    {
      myAuthentik.forwardAuthApps.prowlarr = {
        inherit port;
        displayName = "Prowlarr";
        homepage = {
          group = "Acquisition";
          icon = "prowlarr";
          description = "Indexer manager";
          widget = {
            type = "prowlarr";
            url = "http://localhost:${toString port}";
            key = "{{HOMEPAGE_VAR_PROWLARR_API_KEY}}";
          };
        };
      };

      myHomepage.credentials.PROWLARR_API_KEY = {
        sourceUnit = "prowlarr.service";
        readScript = ''
          grep -oP '(?<=<ApiKey>)[^<]+' /var/lib/prowlarr/config.xml
        '';
      };

      services.prowlarr = {
        enable = true;
        settings.server = {
          inherit port;
          bindAddress = "*";
        };
      };

      users.users.prowlarr = {
        inherit uid;
        group = "prowlarr";
        isSystemUser = true;
      };
      users.groups.prowlarr.gid = uid;

      # Override DynamicUser → static "prowlarr". Re-add the hardening
      # DynamicUser used to imply, since dropping the flag also drops
      # those implicit defaults.
      systemd.services.prowlarr.serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = "prowlarr";
        Group = "prowlarr";
        NoNewPrivileges = true;
        RemoveIPC = true;
        PrivateTmp = true;
        ProtectHome = "read-only";
        ProtectSystem = "strict";
        RestrictSUIDSGID = true;
      };

      myAppState.prowlarr = {
        stateDir = "/var/lib/prowlarr";
        user = "prowlarr";
        group = "prowlarr";
      };

      mySqliteQuiesce.apps.prowlarr.databases = [
        "/var/lib/prowlarr/prowlarr.db"
        "/var/lib/prowlarr/logs.db"
      ];
    };
}
