{ lib, ... }:
{
  options.myObservability = {
    nodeExporterTextfileDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/node-exporter-textfile-collector";
      readOnly = true;
      description = ''
        The single node_exporter textfile-collector drop directory. Every
        producer that publishes `*.prom` files reads this, and
        victoriametrics.nix (which owns the directory's creation and the
        node_exporter `--collector.textfile.directory` flag) reads it too,
        so a move needs to change one value rather than nine hand-synced
        literals. Read-only: this is a shared contract, not a per-host knob.
      '';
    };

    monitoredSystemdUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        systemd-unit regular-expression alternatives to include in the
        node_exporter systemd collector. App modules contribute the units
        whose failure and restart behaviour they own; this stack owns the
        collector and generic alerts that consume the resulting metrics.
        Entries omit the common `.service` suffix.
      '';
      example = [ "podman-example" ];
    };

    metricRuleGroups = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.groups = lib.mkOption {
            type = lib.types.listOf lib.types.attrs;
            default = [ ];
            description = "VictoriaMetrics/vmalert rule groups contributed by one application.";
          };
        }
      );
      default = { };
      description = ''
        Application-owned VictoriaMetrics rule groups, keyed by the
        contributing module. The platform combines these with its host,
        hardware, power, and security groups when configuring vmalert.
      '';
    };

    logRuleGroups = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.groups = lib.mkOption {
            type = lib.types.listOf lib.types.attrs;
            default = [ ];
            description = "VictoriaLogs/vmalert rule groups contributed by one application.";
          };
        }
      );
      default = { };
      description = ''
        Application-owned VictoriaLogs rule groups, keyed by the
        contributing module. The platform combines these with its generic
        security and configuration-change groups.
      '';
    };
  };
}
