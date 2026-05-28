# Alertmanager — Discord receiver (via Discord's Slack-compatible
# `/slack` endpoint) + a Watchdog → healthchecks.io heartbeat receiver.
# Config rendered through envsubst so webhook URLs never hit /nix/store.
#
# Note: services.prometheus.alertmanager (the nixpkgs option) lives
# under the prometheus module namespace, but the runtime alertmanager
# unit is independent from the prometheus unit. Keeping the config
# next to its sops template + forward-auth registration here, even
# though the actual option lives under `services.prometheus.alertmanager`.
_: {
  flake.modules.nixos.alertmanager =
    {
      config,
      hostSpec,
      ...
    }:
    let
      alertmanagerHost = "alertmanager.${hostSpec.serverDomain}";
      alertmanagerPort = 9093;
    in
    {
      sops.secrets = {
        "discord/alerts_webhook" = {
          inherit (hostSpec) sopsFile;
          restartUnits = [ "alertmanager.service" ];
        };
        "alertmanager/heartbeat_url" = {
          inherit (hostSpec) sopsFile;
          restartUnits = [ "alertmanager.service" ];
        };
      };

      sops.templates = {
        # Alertmanager reads this via EnvironmentFile and the NixOS
        # module envsubst's $VAR references in configText at start-up.
        "alertmanager.env" = {
          content = ''
            DISCORD_WEBHOOK=${config.sops.placeholder."discord/alerts_webhook"}
            ALERTMANAGER_HEARTBEAT_URL=${config.sops.placeholder."alertmanager/heartbeat_url"}
          '';
          restartUnits = [ "alertmanager.service" ];
        };
      };

      services.prometheus.alertmanager = {
        enable = true;
        port = alertmanagerPort;
        environmentFile = config.sops.templates."alertmanager.env".path;
        # amtool runs at build time and can't see envsubst values, so
        # the unresolved $DISCORD_WEBHOOK / $ALERTMANAGER_HEARTBEAT_URL
        # placeholders look like malformed URLs to it. Skip the
        # sandboxed check; the runtime envsubst step still surfaces
        # config errors when the unit starts.
        checkConfig = false;
        configText = ''
          route:
            # Group by alertname AND `name` so per-endpoint alerts
            # (e.g. GatusEndpointDown) get their own group instead of
            # collapsing every endpoint into one. Without `name`,
            # alertmanager only sends a "resolved" notification when
            # every endpoint in the group has cleared — easy to miss a
            # single-service recovery while others stay firing.
            # `name` is a no-op label on alerts that don't carry it
            # (InstanceDown, FilesystemAlmostFull, …) so adding it is
            # safe across the rule set.
            receiver: discord
            group_by: [alertname, name]
            group_wait: 30s
            group_interval: 5m
            repeat_interval: 4h
            routes:
              - matchers:
                  - alertname="Watchdog"
                receiver: heartbeat
                group_wait: 0s
                group_interval: 1m
                repeat_interval: 1m

          receivers:
            - name: discord
              # Native discord_configs (Alertmanager ≥ 0.26) — the
              # Slack-compat path Discord exposes rejects the
              # `attachments` field that slack_configs ships by
              # default with HTTP 400.
              discord_configs:
                - webhook_url: "''${DISCORD_WEBHOOK}"
                  send_resolved: true
                  title: "{{ .Status | toUpper }} — {{ .CommonLabels.alertname }}"
                  message: |
                    {{ range .Alerts }}**{{ .Annotations.summary }}**
                    {{ .Annotations.description }}
                    {{ end }}
            - name: heartbeat
              webhook_configs:
                - url: "''${ALERTMANAGER_HEARTBEAT_URL}"
                  send_resolved: false
        '';
      };

      # Forward-auth via the embedded authentik outpost — alertmanager
      # has no built-in auth so it sits behind the
      # `authentik_forward_auth` Caddy snippet (see
      # modules/apps/authentik.nix for the aggregator that owns
      # the outpost's providers list).
      myAuthentik.forwardAuthApps.alertmanager = {
        host = alertmanagerHost;
        port = alertmanagerPort;
        displayName = "Alertmanager";
        homepage = {
          group = "Infrastructure";
          icon = "prometheus";
          description = "alerts";
        };
      };
    };
}
