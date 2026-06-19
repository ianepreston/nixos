# Shared initrd "erase your darlings" rollback service for the btrfs
# impermanence hosts (hpp-1, amos1, and the VM test targets). On every
# boot it archives the live @root into @old_roots/<timestamp> and
# recreates a pristine @root from @root-blank before sysroot is mounted.
#
# Plain NixOS module: the leading-underscore filename makes import-tree
# skip it, so it is pulled in by relative path from each _*-disks.nix
# rather than auto-registered as a flake module.
#
# Parameterised by the root partition's by-partlabel name because disko
# derives it from the disk key ("disk-primary-root" on the bare-metal
# hosts, "disk-disk0-root" on the VMs).
#
# History: see ianepreston/nixos#310. The previous version enumerated
# nested subvolumes with `awk '{print $NF}'`, but awk is not present in
# the systemd initrd, so the prune deleted nothing and then
# `btrfs subvolume delete` failed on any old root that still contained
# nested subvolumes ("directory not empty"). That failure, under the
# `set -e` NixOS injects into initrd service scripts, aborted the
# service *before* @root was recreated — leaving the host with no root
# to mount and dropping it into emergency mode. This version (a) drops
# the awk dependency by letting `btrfs subvolume delete --recursive`
# handle nested subvolumes, (b) recreates @root *before* the prune, and
# (c) makes the prune strictly best-effort so it can never block boot.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.rollbackRoot;

  # node_exporter textfile collector drop dir (same path the rest of the
  # observability stack uses, e.g. modules/system/victoriametrics.nix).
  textfileDir = "/var/lib/node-exporter-textfile-collector";
  # Marker the initrd writes (under @persist) when the prune fails.
  marker = "/persist/var/lib/rollback-root/prune-failed";
  # systemd-escape the partlabel for the .device unit name: every "-"
  # in the path component becomes "\x2d". e.g. "disk-primary-root" ->
  # "disk\x2dprimary\x2droot".
  esc = lib.replaceStrings [ "-" ] [ "\\x2d" ];
  deviceUnit = "dev-disk-by\\x2dpartlabel-${esc cfg.partlabel}.device";

  # The script is built by a config-free helper so the regression test
  # (../flake/checks-rollback-root.nix) can run this exact text against a
  # scratch btrfs instead of keeping a divergent copy.
  scriptText = import ./_rollback-root-script.nix { inherit (cfg) partlabel keepDays; };
in
{
  options.rollbackRoot = {
    enable = lib.mkEnableOption "btrfs @root blank-snapshot rollback in the initrd" // {
      default = true;
    };

    partlabel = lib.mkOption {
      type = lib.types.str;
      example = "disk-primary-root";
      description = ''
        by-partlabel name of the btrfs partition that holds @root,
        @root-blank, @nix and @persist. disko derives it from the disk
        key, e.g. "disk-primary-root" or "disk-disk0-root".
      '';
    };

    keepDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = ''
        Archived @old_roots/<timestamp> entries older than this many
        days are pruned on the next boot. Pruning is best-effort and can
        never block the boot.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # If the initrd ever fails (e.g. a future rollback bug), drop to an
    # unauthenticated emergency shell on the console instead of hanging
    # unreachable — recovering hpp-1 in #310 otherwise needed a rescue
    # ISO. Acceptable here: the root disk is unencrypted, so console
    # access already implies data access.
    boot.initrd.systemd.emergencyAccess = true;

    boot.initrd.systemd.services.rollback-root = {
      description = "Roll back @root to blank snapshot";
      wantedBy = [ "initrd.target" ];
      requires = [ deviceUnit ];
      after = [ deviceUnit ];
      before = [ "sysroot.mount" ];
      unitConfig.DefaultDependencies = "no";
      serviceConfig.Type = "oneshot";
      script = scriptText;
    };

    # Publish the prune-failed marker (written by the initrd service
    # above) as a node_exporter textfile metric so vmalert can fire
    # RollbackRootPruneFailed — journald isn't persisted across the
    # rollback, so the marker is the only post-boot trace. Atomic write
    # via tempfile + rename. See #310.
    systemd.services.rollback-root-prune-metrics = {
      description = "publish initrd @old_roots prune health to node_exporter textfile collector";
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Environment = [ "PATH=${lib.makeBinPath [ pkgs.coreutils ]}" ];
      };
      script = ''
        set -eu
        out=${textfileDir}/rollback-root.prom
        mkdir -p "$(dirname "$out")"
        failed=0
        ts=0
        if [ -e ${marker} ]; then
          failed=1
          ts=$(stat -c %Y ${marker} 2>/dev/null || echo 0)
        fi
        tmp=$(mktemp -p "$(dirname "$out")" .rollback-root.prom.XXXXXX)
        {
          echo "# HELP rollback_root_prune_failed Whether the last initrd @old_roots prune failed (1) or not (0)."
          echo "# TYPE rollback_root_prune_failed gauge"
          echo "rollback_root_prune_failed $failed"
          echo "# HELP rollback_root_prune_last_failure_timestamp_seconds Unix time the prune-failed marker was last written (0 if none)."
          echo "# TYPE rollback_root_prune_last_failure_timestamp_seconds gauge"
          echo "rollback_root_prune_last_failure_timestamp_seconds $ts"
        } > "$tmp"
        chmod 0644 "$tmp"
        mv "$tmp" "$out"
      '';
    };

    systemd.timers.rollback-root-prune-metrics = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "5m";
        Unit = "rollback-root-prune-metrics.service";
      };
    };
  };
}
