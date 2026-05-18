# Preservation (server) — declarative persistence across ephemeral root.
#
# Pairs with a btrfs blank-snapshot rollback in initrd (configured in
# each host's disks file): on every boot the @root subvolume is deleted
# and re-created from @root-blank, leaving / pristine. /persist is a
# separate subvolume that survives, and this module bind-mounts the
# paths below from /persist back into the live root early in boot.
#
# Persistence layers:
#   - Host identity / system state (this module): SSH host keys,
#     machine-id, nixos uid/gid db, systemd state, tailscale,
#     postgres + mariadb data dirs, the /var/backup dumps, caddy ACME
#     state, observability state.
#   - Per-app state: each app module adds its own
#     `preservation.preserveAt."/persist".directories` entry alongside
#     its restic path. Keeps app modules self-contained.
#
# Server-specific by design — workstations have a different persist
# surface and aren't in scope here. Imported by modules/profiles/server.nix.
{ inputs, ... }:
{
  flake.modules.nixos.preservation-server = _: {
    imports = [ inputs.preservation.nixosModules.default ];

    # Preservation requires systemd-in-initrd to schedule its bind
    # mounts before sysinit.target.
    boot.initrd.systemd.enable = true;

    services.openssh.hostKeys = [
      {
        path = "/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];

    # The bind-mounted /etc/machine-id from /persist is already a
    # durable file, so the commit-transient-to-disk service has
    # nothing to do and fails noisily ("/etc/machine-id is not on a
    # temporary file system"). Suppress it.
    systemd.suppressedSystemUnits = [ "systemd-machine-id-commit.service" ];

    preservation = {
      enable = true;
      preserveAt."/persist" = {
        directories = [
          # ----- System / identity -----
          # nixos uid/gid allocation db; without this, dynamic users
          # reshuffle on every boot.
          "/var/lib/nixos"
          # systemd persistent state (boot counts, random seed, etc.).
          "/var/lib/systemd"
          # tailscale node identity; lose it and the host re-registers
          # as a fresh device under a new name.
          "/var/lib/tailscale"

          # ----- TLS / cert state -----
          # Caddy ACME account key + issued certs. Losing this means
          # cert re-issue on next boot — possible LE rate-limit hit.
          "/var/lib/caddy"

          # ----- Databases (data dirs; dumps are recovery) -----
          "/var/lib/postgresql"
          # mariadb writes ib_buffer_pool.incomplete and deletes tc.log
          # directly in this dir during shutdown — unlike postgres which
          # writes to a versioned subdirectory. Preservation's default
          # root:root 0755 (bind-mount source's perms on /persist/...)
          # propagates here and matches 00-nixos.conf's mode but not its
          # owner, so a `systemd-tmpfiles --create` mid-deploy reverts
          # /var/lib/mysql from mysql:mysql to root:root. Mariadb then
          # gets EACCES on the next shutdown's buffer-pool dump and
          # tc.log unlink → tc.log header left half-written → next
          # boot's crash recovery fails with "Bad magic header in tc
          # log" and an 11-minute systemd-retry cascade. Pinning owner
          # and mode to match 00-nixos.conf keeps mysql writable through
          # tmpfiles-resetup. Closes #195.
          {
            directory = "/var/lib/mysql";
            user = "mysql";
            group = "mysql";
            mode = "0755";
          }

          # ----- Dump staging -----
          # The morning's postgres/mariadb dumps land here and restic
          # picks them up overnight; restic also runs from here so the
          # repo metadata cache needs to survive (though restic's
          # repo itself is on NFS).
          "/var/backup"

          # ----- Container app state -----
          # Every podman-managed app's volumes live under here.
          "/var/lib/containers"

          # ----- Logs -----
          # Persist journald across reboots. /var/log is on the wiped
          # rootfs, so without this every boot drops prior journals and
          # `journalctl --list-boots` only sees the current boot.
          # journald's default storage=auto writes here when the dir
          # exists, so persisting it is sufficient — no extra config
          # needed. Closes #195 (diagnostic gap for the mariadb tc.log
          # corruption investigation).
          "/var/log/journal"

          # ----- Observability -----
          # Prometheus TSDB (15d) + Loki chunks/index (7d). The
          # observability module's header comment treats these as
          # ephemeral *for host-failure DR*, but routine reboots
          # shouldn't wipe history — persist them so the configured
          # retention windows actually mean what they say.
          "/var/lib/prometheus2"
          "/var/lib/loki"
        ];

        files = [
          # SSH host identity. Without these, every reboot trips
          # known_hosts warnings on every client and breaks restic's
          # NFS access if the NAS pins the host key. ed25519 only —
          # NixOS's openssh module would otherwise also generate an
          # RSA key, but preservation would bind-mount it from an
          # unseeded /persist file and sshd would refuse to load it.
          # See services.openssh.hostKeys override above.
          #
          # mode = 0600 for the private key: preservation's tmpfiles
          # default is 0644 and sshd refuses to load a key that's
          # group/world-readable.
          {
            file = "/etc/ssh/ssh_host_ed25519_key";
            mode = "0600";
          }
          "/etc/ssh/ssh_host_ed25519_key.pub"
          # journald uses this to namespace journals + as systemd's
          # stable machine identity.
          {
            file = "/etc/machine-id";
            inInitrd = true;
          }
        ];
      };
    };
  };
}
