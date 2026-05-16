# Loki — single-node log store with filesystem backend, ~7d retention.
# Listens on loopback only; Grafana queries via the Loki datasource
# provisioned in ./grafana.nix.
#
# Data is intentionally ephemeral per issue #65 thread — no backup
# hook. If the host dies, only historical logs are lost; the runtime
# config and Promtail wire-up recreate themselves declaratively.
_: {
  flake.modules.nixos.loki =
    _:
    let
      lokiPort = 3100;
    in
    {
      services.loki = {
        enable = true;
        configuration = {
          auth_enabled = false;
          server = {
            http_listen_address = "127.0.0.1";
            http_listen_port = lokiPort;
            grpc_listen_address = "127.0.0.1";
          };
          common = {
            path_prefix = "/var/lib/loki";
            replication_factor = 1;
            ring.kvstore.store = "inmemory";
            # In monolithic mode every component talks to every other
            # over gRPC. Without instance_addr Loki picks up the LAN
            # IP (192.168.x.x) for self-registration, which doesn't
            # match the loopback-only listener — queries hit a
            # `dial: connection refused` and silently time out while
            # ingestion still works. Pin to loopback so all
            # components agree on where the frontend lives.
            instance_addr = "127.0.0.1";
          };
          schema_config.configs = [
            {
              from = "2024-01-01";
              store = "tsdb";
              object_store = "filesystem";
              schema = "v13";
              index = {
                prefix = "index_";
                period = "24h";
              };
            }
          ];
          storage_config = {
            tsdb_shipper = {
              active_index_directory = "/var/lib/loki/tsdb-index";
              cache_location = "/var/lib/loki/tsdb-cache";
            };
            filesystem.directory = "/var/lib/loki/chunks";
          };
          compactor = {
            working_directory = "/var/lib/loki/compactor";
            retention_enabled = true;
            delete_request_store = "filesystem";
          };
          limits_config = {
            # 30d gives enough history to catch slow-burn issues (gradual
            # OOM creep, weekly cron failures, certificate-near-expiry
            # warnings) while staying well within the host's free space.
            # Bumped from 7d per #157; revisit if /var/lib/loki growth
            # becomes a problem.
            retention_period = "720h"; # 30d
            allow_structured_metadata = true;
            reject_old_samples = true;
            reject_old_samples_max_age = "720h";
          };
          analytics.reporting_enabled = false;
        };
      };
    };
}
