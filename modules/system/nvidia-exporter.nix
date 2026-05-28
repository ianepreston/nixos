# NVIDIA GPU exporter — surfaces nvidia_smi_* (temperature, utilisation,
# memory) into the local VictoriaMetrics scrape. Feeds the host
# dashboard's GPU temperature panel and the HostGPUTemperature{High,
# Critical} alerts declared inline in modules/system/victoriametrics.nix
# (the alert rules silently no-op until a host scrapes this exporter).
#
# Opt-in: a host that imports `nvidia-server` also explicitly imports
# this. Don't auto-enable on `hardware.nvidia.package` presence —
# workstations (terra, xps13) intentionally aren't covered by the
# observability stack, so an implicit "if nvidia, scrape it" coupling
# would pull them in unintentionally. Mirrors how `intel-quicksync` is
# imported alongside the GPU on hpp-1 without dragging in scrape config.
#
# Listens on loopback only; the scrape job appended below targets it
# from the local VictoriaMetrics. The systemd unit name
# (`prometheus-nvidia-gpu-exporter.service`) is in the allow-list regex
# in modules/system/victoriametrics.nix so SystemdUnitFailed covers it.
_: {
  flake.modules.nixos.nvidia-exporter =
    { config, ... }:
    {
      services.prometheus.exporters."nvidia-gpu" = {
        enable = true;
        listenAddress = "127.0.0.1";
      };

      services.victoriametrics.prometheusConfig.scrape_configs = [
        {
          job_name = "nvidia-gpu";
          static_configs = [
            { targets = [ "127.0.0.1:${toString config.services.prometheus.exporters."nvidia-gpu".port}" ]; }
          ];
        }
      ];
    };
}
