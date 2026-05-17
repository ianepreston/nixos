# Authentik - identity provider / SSO
# Uses the nix-community authentik-nix module: native systemd units
# (server, worker, migrate) running under DynamicUser, talking to
# postgres over the unix socket via peer auth and to a localhost Redis.
# Configuration (groups, users, applications, OAuth/proxy providers,
# group bindings) is managed declaratively via authentik blueprints —
# upstream's bundled blueprints plus everything under
# ./authentik-blueprints (and any paths added by other app modules via
# `myAuthentik.extraBlueprints`) are merged into a single dir that
# authentik scans on startup and reconciles periodically.
#
# Secrets in blueprints (user passwords, OAuth client secrets, token
# values) are passed via `!Env VAR_NAME`; the `VAR_NAME` is rendered
# into the systemd EnvironmentFile from sops, so the secret never lands
# in /nix/store. Add the corresponding env line to
# `sops.templates."authentik.env"` whenever a new `!Env` reference is
# introduced.
{ inputs, ... }:
let
  sopsFolder = (builtins.toString inputs.nix-secrets) + "/sops";
in
{
  flake.modules.nixos.authentik =
    {
      config,
      hostSpec,
      lib,
      pkgs,
      ...
    }:
    let
      authentikHost = "authentik.${hostSpec.serverDomain}";
      authentikPort = 9000;
      sopsSecretNames = [
        "secret_key"
        "bootstrap_email"
        "bootstrap_password"
        "bootstrap_token"
        "ian_password"
      ];
      restartAuthentik = [
        "authentik.service"
        "authentik-worker.service"
        "authentik-migrate.service"
      ];
      # Stack upstream blueprints + every contributed dir + this module's
      # local set into a single real-file directory. Copy with `-L` to
      # dereference: authentik's `retrieve_file` calls
      # `Path(...).resolve()` on every blueprint and rejects anything
      # that resolves outside `blueprints_dir`, so `symlinkJoin` (top-level
      # entries are symlinks back to source store paths) makes every
      # apply fail with "Invalid blueprint path".
      #
      # `@serverDomain@` substitution is not done here. Each contributor
      # that uses the placeholder renders its own files first: OIDC app
      # blueprints go through `renderedBlueprintDir` in
      # `modules/platform/authentik.nix`; `fwBlueprintDir` interpolates
      # the domain via Nix strings. This module's local
      # `./authentik-blueprints/*.yaml` files don't reference the
      # placeholder, so they cp in unmodified.
      mergedBlueprints = pkgs.runCommandLocal "authentik-blueprints-merged" { } ''
        mkdir -p $out
        cp -rL ${config.services.authentik.authentikComponents.staticWorkdirDeps}/blueprints/. $out/
        ${lib.concatMapStringsSep "\n" (p: "cp -rL ${p}/. $out/") config.myAuthentik.extraBlueprints}
        cp -rL ${./authentik-blueprints}/. $out/
        chmod -R u+w $out
      '';
    in
    {
      imports = [
        inputs.authentik-nix.nixosModules.default
        inputs.self.modules.nixos.myAuthentik
      ];

      config = {
        sops.secrets = builtins.listToAttrs (
          map (n: {
            name = "authentik/${n}";
            value = {
              sopsFile = "${sopsFolder}/${hostSpec.hostName}.yaml";
              restartUnits = restartAuthentik;
            };
          }) sopsSecretNames
        );

        # Authentik uses DynamicUser; real on-disk state (UI-uploaded
        # icons, certs, branding assets) lives at /var/lib/private/authentik.
        # Postgres dump covers blueprint-managed objects; this is the
        # gap closer. Restic doesn't follow symlinks, so /var/lib/authentik
        # (a symlink) would capture only the link. Closes #120.
        preservation.preserveAt."/persist".directories = [ "/var/lib/private/authentik" ];
        services.restic.backups.server.paths = [ "/var/lib/private/authentik" ];

        # authentik-nix hardcodes DynamicUser=true across server/worker/
        # migrate (and the optional outpost units) with no exposed user
        # override. We can't cleanly pin a static UID the way prowlarr/
        # mealie/readeck do without `mkForce`-ing every unit and tracking
        # the set as the flake evolves. Instead, heal the persisted
        # state dir's ownership to whatever UID systemd allocated this
        # boot — so a fresh `bootstrap:reinstall` against preserved
        # /persist self-recovers. The dynamic UID is registered in NSS
        # via nss-systemd as soon as the unit is loaded, so `id` resolves
        # pre-start; on the very first start `id` fails and the chown
        # is skipped (authentik creates its dir with the freshly
        # allocated UID — fine).
        systemd.services.authentik-state-chown = {
          description = "Re-own /var/lib/private/authentik to the current dynamic authentik UID";
          wantedBy = restartAuthentik;
          before = restartAuthentik;
          serviceConfig.Type = "oneshot";
          script = ''
            if uid=$(${pkgs.coreutils}/bin/id -u authentik 2>/dev/null) \
            && gid=$(${pkgs.coreutils}/bin/id -g authentik 2>/dev/null); then
              ${pkgs.coreutils}/bin/chown -R "$uid:$gid" /var/lib/private/authentik
            fi
          '';
        };

        sops.templates."authentik.env" = {
          content = ''
            AUTHENTIK_SECRET_KEY=${config.sops.placeholder."authentik/secret_key"}
            AUTHENTIK_BOOTSTRAP_EMAIL=${config.sops.placeholder."authentik/bootstrap_email"}
            AUTHENTIK_BOOTSTRAP_PASSWORD=${config.sops.placeholder."authentik/bootstrap_password"}
            AUTHENTIK_BOOTSTRAP_TOKEN=${config.sops.placeholder."authentik/bootstrap_token"}
            IAN_PASSWORD=${config.sops.placeholder."authentik/ian_password"}
          '';
          restartUnits = restartAuthentik;
        };

        services = {
          authentik = {
            enable = true;
            environmentFile = config.sops.templates."authentik.env".path;
            # createDatabase = true (default) adds authentik to the shared
            # postgres via ensureDatabases/ensureUsers and points the app at
            # the unix socket; DynamicUser=authentik + peer auth means no
            # role password is required.
            settings = {
              disable_startup_analytics = true;
              avatars = "initials";
              blueprints_dir = "${mergedBlueprints}";
            };
          };

          # Authentik defaults to redis://localhost:6379. Use the unnamed
          # NixOS redis instance (services.redis.servers."") so the default
          # config works as-is.
          redis.servers."" = {
            enable = true;
            port = 6379;
          };

          # Reusable snippet for protected apps on this host: a route
          # block can `import authentik_forward_auth` and the embedded
          # outpost gates the request. The /outpost.goauthentik.io/*
          # routes are reverse-proxied with `handle` (not `handle_path`)
          # so the path prefix is preserved when forwarded to authentik
          # — the outpost serves its login flow at the original URI.
          caddy.extraConfig = ''
            (authentik_forward_auth) {
              forward_auth localhost:${toString authentikPort} {
                uri /outpost.goauthentik.io/auth/caddy
                copy_headers X-authentik-username X-authentik-groups X-authentik-entitlements X-authentik-email X-authentik-name X-authentik-uid X-authentik-jwt X-authentik-meta-jwks X-authentik-meta-outpost X-authentik-meta-provider X-authentik-meta-app X-authentik-meta-version
                trusted_proxies private_ranges
              }
              handle /outpost.goauthentik.io/* {
                reverse_proxy localhost:${toString authentikPort}
              }
            }
          '';
        };

        myCaddy.apps.authentik = {
          host = authentikHost;
          routeConfig = ''
            reverse_proxy localhost:${toString authentikPort}
          '';
        };

        myHomepage.tiles.Authentik = {
          group = "Infrastructure";
          href = "https://${authentikHost}";
          icon = "authentik";
          description = "SSO";
        };
      };
    };
}
