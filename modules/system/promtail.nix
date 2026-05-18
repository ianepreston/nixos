# Promtail — ships the systemd journal into VictoriaLogs
# (see ./victorialogs.nix). VictoriaLogs accepts the Loki
# `/loki/api/v1/push` payload as a compatibility endpoint at
# `/insert/loki/api/v1/push`, so the promtail config doesn't need to
# learn a new protocol — only the URL changed when we migrated off
# Loki (#126). Loopback-only; no external exposure.
_: {
  flake.modules.nixos.promtail =
    { config, ... }:
    let
      victorialogsPort = 9428;
      promtailPort = 9080;
    in
    {
      services.promtail = {
        enable = true;
        configuration = {
          server = {
            http_listen_address = "127.0.0.1";
            http_listen_port = promtailPort;
            grpc_listen_address = "127.0.0.1";
            # Promtail doesn't actually need its gRPC listener
            # exposed; park it on a non-default port so it can't
            # collide with anything else on loopback.
            grpc_listen_port = 9096;
          };
          clients = [
            { url = "http://127.0.0.1:${toString victorialogsPort}/insert/loki/api/v1/push"; }
          ];
          scrape_configs = [
            {
              job_name = "journal";
              journal = {
                max_age = "12h";
                labels = {
                  job = "systemd-journal";
                  host = config.networking.hostName;
                };
              };
              relabel_configs = [
                {
                  source_labels = [ "__journal__systemd_unit" ];
                  target_label = "unit";
                }
                {
                  source_labels = [ "__journal_priority_keyword" ];
                  target_label = "level";
                }
              ];
            }
          ];
        };
      };

      # Promtail needs to read the journal — the upstream NixOS module
      # already runs it as `promtail`, but doesn't add the user to the
      # `systemd-journal` group, so without this it can only see its
      # own unit's messages.
      users.users.promtail.extraGroups = [ "systemd-journal" ];
    };
}
