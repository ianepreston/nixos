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
{ config, lib, ... }:
let
  cfg = config.rollbackRoot;
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
  };
}
