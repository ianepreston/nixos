# Home Assistant - smart-home automation hub
#
# Native services.home-assistant (migrated off the podman container — see
# git history for the container era). The container's manual first-boot
# ritual is now declarative:
#   * OIDC        — the auth_oidc custom component (formerly hand-installed
#                   via HACS) ships from nixpkgs and is configured entirely
#                   in configuration.yaml below.
#   * proxy       — http.trusted_proxies set here, not edited on first boot.
#   * DHCP        — native HA gets CAP_NET_RAW, so the dhcp integration works
#                   instead of needing the default_config surgery (#201).
#   * recorder    — native postgres over the unix socket (peer auth).
#
# Version currency: HA ships ~monthly and the stable channel freezes its
# snapshot for a year (e.g. 2026.5.x on nixos-26.05). Per CLAUDE.md
# ("prefer nixpkgs services" + "wire a per-package overlay rather than
# flipping the whole flake to unstable"), the HA package and its custom
# component are pinned to nixpkgs-unstable so integrations stay current;
# the rest of the system stays on stable.
#
# Operator first-boot steps that remain (UI/.storage-owned, not yaml):
#   * MQTT: add the MQTT integration pointing at broker 127.0.0.1:1883
#     (native HA is in the host netns now, not the podman bridge). Read the
#     password with `task secrets:view:hpp-1` (homeassistant.mqtt_password),
#     username `homeassistant`.
#   * Onboarding: create the owner account / location on first launch;
#     thereafter log in via the "authentik" button (auth_oidc).
{ inputs, ... }:
{
  flake.modules.nixos.homeassistant =
    {
      config,
      hostSpec,
      lib,
      pkgs,
      ...
    }:
    let
      homeassistantHost = "homeassistant.${hostSpec.serverDomain}";
      authentikHost = "authentik.${hostSpec.serverDomain}";
      port = 8123;
      iotEnabled = hostSpec.iotTrunkInterface != null;

      # Pin just the HA package + its custom component (which must share the
      # same python interpreter, see nixpkgs#341366) to unstable.
      pkgsUnstable = import inputs.nixpkgs-unstable {
        inherit (pkgs.stdenv.hostPlatform) system;
        inherit (pkgs) config;
      };

      secretsFile = config.sops.templates."homeassistant-secrets.yaml".path;
    in
    {
      # MQTT broker user. ACL grants HA full access — HA bridges every
      # publisher's topic via its own auto-discovery prefix and re-emits
      # state on the entity-level topics, so a narrower ACL would just mean
      # maintaining a per-publisher list here.
      myMosquitto.users.homeassistant.acl = [ "readwrite #" ];

      myAuthentik.oidcApps.homeassistant = {
        blueprintsDir = ./homeassistant-blueprints;
        # Creds no longer flow through a per-app env file; auth_oidc reads
        # them from HA's own secrets.yaml (rendered from sops below). Opt out
        # of the env-file path — the sops secret pair + blueprint are still
        # provisioned by the aggregator regardless of this flag.
        clientCredsInAppEnv = false;
        homepage = {
          group = "Home";
          icon = "home-assistant";
          description = "Smart home";
        };
        displayName = "Home Assistant";
      };

      # auth_oidc resolves client_id/secret via HA's `!secret` tag, which
      # reads <configDir>/secrets.yaml. Render that file from the sops pair
      # the oidcApps aggregator provisions (homeassistant/oidc_client_*), then
      # symlink it into the config dir (tmpfiles below). The symlink (rather
      # than a direct sops `path = /var/lib/hass/...`) avoids a race where
      # /var/lib/hass doesn't exist yet at sops activation.
      sops.templates."homeassistant-secrets.yaml" = {
        owner = "hass";
        content = ''
          oidc_client_id: ${config.sops.placeholder."homeassistant/oidc_client_id"}
          oidc_client_secret: ${config.sops.placeholder."homeassistant/oidc_client_secret"}
        '';
        restartUnits = [ "home-assistant.service" ];
      };

      services.home-assistant = {
        enable = true;
        package = pkgsUnstable.home-assistant;
        configDir = "/var/lib/hass";

        # default_config pulls in the discovery/onboarding stack, but the
        # native module only ships python deps for the components listed here
        # (unlike the container image, which bundles everything). Any
        # integration you want to add in the UI must be listed so its handler
        # loads — otherwise the config flow fails "Invalid handler specified".
        # Extend as integrations are added (zha, matter, …).
        extraComponents = [
          "default_config"
          "met"
          "esphome"
          "mqtt"
          "roomba" # iRobot Roomba/Braava (needs roombapy)
        ];

        # Postgres recorder backend needs the psycopg2 driver injected.
        extraPackages = ps: [ ps.psycopg2 ];

        # Declarative OIDC — the component previously hand-installed via HACS.
        # Same unstable set as the package so the python interpreters match.
        customComponents = [ pkgsUnstable.home-assistant-custom-components.auth_oidc ];

        # Fully declarative configuration.yaml (immutable symlink from the
        # store; `configWritable` stays at its false default — the repo's
        # declarative posture). UI-configured integrations live in .storage/
        # and are unaffected.
        config = {
          default_config = { };

          # UI-authored automations/scripts/scenes write to these files in the
          # config dir (the visual editors are file-based, not .storage-based).
          # The `!include` lines are what wire them in — without them the UI
          # editors have nowhere to write. `!include` is unquoted by the
          # module's renderer just like `!secret`. The target files are
          # UI-owned runtime state, seeded empty by the tmpfiles rules below;
          # they are NOT store-managed, so UI edits persist. Device onboarding
          # (config-flow: Hue pairing, discovery, OAuth) is separate again — it
          # lives in .storage/ and needs none of this.
          automation = "!include automations.yaml";
          script = "!include scripts.yaml";
          scene = "!include scenes.yaml";

          http = {
            use_x_forwarded_for = true;
            # Caddy proxies to 127.0.0.1:8123 in the host netns — no podman
            # bridge SNAT anymore, so HA sees real loopback as the source.
            trusted_proxies = [
              "127.0.0.1"
              "::1"
            ];
          };

          recorder.db_url = "postgresql://@/hass";

          # auth_oidc, configured entirely in YAML. `!secret` values are
          # unquoted by the module's renderer and resolved from secrets.yaml.
          # slug/issuer come from homeassistant-blueprints/homeassistant.yaml
          # (per_provider issuer_mode, app slug `homeassistant`).
          auth_oidc = {
            client_id = "!secret oidc_client_id";
            client_secret = "!secret oidc_client_secret";
            discovery_url = "https://${authentikHost}/application/o/homeassistant/.well-known/openid-configuration";
            display_name = "authentik";
          };
        };
      };

      # Recorder role: peer auth on the unix socket, role == system user
      # `hass` == db name, so there's no password to plumb (mirrors mealie's
      # createLocally pattern per CLAUDE.md). Merges into the shared cluster
      # from modules/system/postgresql.nix.
      services.postgresql = {
        ensureDatabases = [ "hass" ];
        ensureUsers = [
          {
            name = "hass";
            ensureDBOwnership = true;
          }
        ];
      };

      systemd = {
        # Ordering: HA needs the postgres cluster up (recorder) and the sops
        # secret rendered + symlinked before it parses configuration.yaml
        # (auth_oidc reads !secret from /var/lib/hass/secrets.yaml). Without
        # the sops edge, a boot where HA starts before the secret renders
        # fails config parse and drops into recovery mode.
        #
        # No capability tweaks needed: the nixpkgs module already grants
        # CAP_NET_RAW / CAP_NET_ADMIN, so default_config's dhcp integration
        # works out of the box — the AF_PACKET restriction the container hit
        # (#201) is native's by default.
        services.home-assistant = {
          after = [
            "postgresql.service"
            "sops-install-secrets.service"
            "systemd-tmpfiles-setup.service"
          ];
          wants = [
            "postgresql.service"
            "sops-install-secrets.service"
          ];
          # Seed the UI-editor include targets before HA parses
          # configuration.yaml, else the `!include` lines fail on a fresh dir
          # and HA drops into recovery mode. A preStart (part of this unit's
          # own start) is race-free on `switch` — a tmpfiles rule isn't,
          # because `systemd-tmpfiles-resetup` has no ordering edge to this
          # unit. Only writes when absent, so UI/agent edits survive rebuilds.
          # Empty list for automations/scenes, empty dict for scripts.
          preStart = lib.mkAfter ''
            [ -e /var/lib/hass/automations.yaml ] || echo '[]' > /var/lib/hass/automations.yaml
            [ -e /var/lib/hass/scenes.yaml ] || echo '[]' > /var/lib/hass/scenes.yaml
            [ -e /var/lib/hass/scripts.yaml ] || echo '{}' > /var/lib/hass/scripts.yaml
          '';
        };

        # Symlink secrets.yaml into the config dir (see sops template above).
        tmpfiles.rules = [
          "L+ /var/lib/hass/secrets.yaml - - - - ${secretsFile}"
        ];
      };

      # Native on-disk state → preservation + restic, and satisfies the
      # server-apps impermanence guard. Replaces the container volume that
      # was preserved under the wholesale /var/lib/containers rule.
      myAppState.homeassistant = {
        stateDir = "/var/lib/hass";
        user = "hass";
        group = "hass";
      };

      # L2 presence on the IoT VLAN for mDNS/SSDP discovery. iot-network.nix
      # already builds the host `iot` vlan30 sub-iface (no host IP by default,
      # for bambuddy's macvlan children). Native HA is in the host netns, so
      # give the host itself a DHCP lease on vlan30 — VLAN exposure accepted.
      # The old container macvlan + podman-network unit ordering are gone.
      networking.interfaces.iot.useDHCP = lib.mkIf iotEnabled (lib.mkForce true);

      myCaddy.apps.homeassistant = {
        host = homeassistantHost;
        routeConfig = ''
          reverse_proxy localhost:${toString port}
        '';
      };
    };
}
