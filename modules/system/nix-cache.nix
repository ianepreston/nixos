# Nix cache - hpp-1's /nix/store as a signed, read-only substituter (#936)
#
# CI builds every host's toplevel on hpp-1 (`build` job in
# .github/workflows/check.yml, self-hosted runner sharing hpp-1's store). Without
# this, each host's only substituter is cache.nixos.org, so every custom build
# (overrides, unstable pins, private Python sets) is rebuilt independently on
# every host, test suites included. That is a fresh draw on every flaky test in
# the closure, under the full load of an upgrade (2026-11-12: amos1 burned
# 8h of CPU across two failed attempts reproducing a toplevel hpp-1 already
# held).
#
# CI runs on PRs only and builds GitHub's test-merge commit. The toplevel
# embeds the commit, so the host's own toplevel, `etc` and `activate` never
# hit this cache and are built locally: a handful of trivial derivations.
# Everything expensive below them has the same hash and comes from hpp-1.
#
# Two halves, both owned here so the public key, the address and the authorized
# consumer keys are declared exactly once:
#
#   nix-cache-server  imported by hpp-1. The daemon signs every path it builds
#                     (whoever asked — the github-runner stays untrusted), and
#                     `nix.sshServe` exposes the store over the existing sshd as
#                     the `nix-ssh` user. No new listening port.
#   nix-cache-client  imported by consumers. Adds hpp-1 ahead of cache.nixos.org
#                     and trusts its signing key. `require-sigs` stays on.
#
# Transport is ssh-ng from nix-daemon (root) on the consumer, authenticating
# with the per-host root key auto-rebuild.nix already provisions for the
# nix-secrets fetch. Root's ssh settings for the connection live in a Host
# alias in /etc/ssh/ssh_config so nothing else depends on root's
# ~/.ssh or a user's known_hosts.
#
# ConnectTimeout is load-bearing: nix's own `connect-timeout` (base.nix)
# applies to HTTP substituters only. Measured on terra against a blackholed
# address, an ssh-ng substituter with no ssh timeout stalled every nix
# invocation for 2m15s (kernel SYN retries) before falling back. A refused or
# timed-out connection falls back to cache.nixos.org + local builds, but only
# while hpp-1 is ordered first (see `priority` below). Nix prints
# "opening a connection to remote store ... previously failed" and carries on.
{ hostSpecs, ... }:
let
  cacheHost = hostSpecs.hpp-1;

  publicKey = "hpp-1-cache-1:2P1UXXCwUFo3j7/FWwZ5qrOBNdMk0YmM3wYjW7FJ5cs=";

  # Name the consumers' ssh config and known_hosts entry use. An alias rather
  # than `hpp-1` so the pinned host key and the timeout don't leak into any
  # other ssh to hpp-1 made as root.
  sshAlias = "${cacheHost.hostName}-nix-cache";

  # hpp-1's sshd host key, which is also what sops-nix derives hpp-1's age
  # identity from (modules/system/sops.nix). It's stable across deploys, but
  # `task bootstrap:reinstall` without SSH_HOST_KEY_FILE generates a new one.
  # Update this literal when that happens. A mismatch doesn't error: under
  # StrictHostKeyChecking the consumers just fall back to building locally.
  hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPN8rQy4QyY5J8FdOLsv31mJ2dVsmPfmHowAgGf/IJjN";

  # Public halves of each consumer's sops `ssh/ed25519` root key
  # (auto-rebuild.nix). Recover with:
  #   sops -d --extract '["ssh"]["ed25519"]' sops/<host>.yaml | ssh-keygen -y -f /dev/stdin
  # Deliberately not in modules/profiles/_ssh-keys/: base.nix authorizes every
  # key there for interactive login fleet-wide. Here they only reach
  # `nix-daemon --stdio` as nix-ssh.
  consumerKeys = {
    amos1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK/BENi+DXWovCfVBCgPIlYVzSddtOxnyVhe+Tk+3l2Y";
    terra = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAQ+F0W3B6SVHG3vGaCfu5tYvcbTXjrZRjFsg0xCgbzz";
    luna = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFOetjTYxFVxXampjkX6i4iH3JXM1Ix/KPD2/P+i7Dz8";
  };
in
{
  flake.modules.nixos.nix-cache-server =
    { config, hostSpec, ... }:
    {
      assertions = [
        {
          assertion = hostSpec.hostName == cacheHost.hostName;
          message = "nix-cache-server is ${cacheHost.hostName}'s; the clients' address and trusted key point there.";
        }
      ];

      sops.secrets."nix-cache/signing_key" = {
        inherit (hostSpec) sopsFile;
        owner = "root";
        group = "root";
        mode = "0400";
      };

      # Signs paths the daemon builds from here on, regardless of the
      # requesting user (so CI's builds as the untrusted runner are signed).
      nix.settings.secret-key-files = [ config.sops.secrets."nix-cache/signing_key".path ];

      # `secret-key-files` only signs at build time. A path that arrives any
      # other way stays unsigned, and CI never rebuilds a path that's already
      # valid. That covers a `task deploy:hpp-1` closure copied from a
      # workstation, and everything that predates the key. Consumers would
      # reject those under `require-sigs` and rebuild them, so re-sign the
      # whole store ahead of the 04:40 autoUpgrade window. Already-signed
      # paths are a no-op.
      systemd.services.nix-cache-sign = {
        description = "Sign hpp-1's nix store for the fleet substituter";
        after = [ "nix-daemon.socket" ];
        requires = [ "nix-daemon.socket" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${config.nix.package}/bin/nix store sign --all --key-file ${
            config.sops.secrets."nix-cache/signing_key".path
          }";
          Nice = 19;
          IOSchedulingClass = "idle";
        };
      };
      systemd.timers.nix-cache-sign = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*-*-* 04:00";
          Persistent = true;
        };
      };
      myObservability.monitoredSystemdUnits = [ "nix-cache-sign" ];

      # `write` only governs the legacy `ssh` protocol; with ssh-ng nix-ssh is
      # an ordinary untrusted daemon client. It can't register an
      # input-addressed path without a valid signature, and gets nothing a
      # local unprivileged user doesn't.
      nix.sshServe = {
        enable = true;
        protocol = "ssh-ng";
        write = false;
        keys = builtins.attrValues consumerKeys;
      };
    };

  flake.modules.nixos.nix-cache-client =
    { config, hostSpec, ... }:
    {
      assertions = [
        {
          assertion = consumerKeys ? ${hostSpec.hostName};
          message = "nix-cache-client on ${hostSpec.hostName}: add its ssh/ed25519 public key to consumerKeys in modules/system/nix-cache.nix, or hpp-1 will refuse it.";
        }
      ];

      nix.settings = {
        # Priority 30 puts hpp-1 *ahead* of cache.nixos.org (40). The obvious
        # 50, which would keep upstream paths on the CDN, is broken in nix
        # 2.34.9: an unreachable ssh-ng substituter ordered after
        # cache.nixos.org aborts the whole build ("failed to start SSH
        # connection to 'hpp-1-nix-cache'") instead of falling back. Ordered
        # first, the failure is swallowed ("... previously failed") and the
        # build carries on. Both verified on terra with hpp-1:22 dropped and
        # rejected. The cost is that hpp-1 also serves upstream paths it
        # holds, over the LAN.
        extra-substituters = [ "ssh-ng://${sshAlias}?priority=30" ];
        extra-trusted-public-keys = [ publicKey ];
      };

      programs.ssh = {
        knownHosts.${sshAlias} = {
          hostNames = [ sshAlias ];
          publicKey = hostKey;
        };
        # The key file is root-only (auto-rebuild.nix), so this block is
        # effectively nix-daemon's alone.
        extraConfig = ''
          Host ${sshAlias}
            HostName ${cacheHost.serverLanIp}
            User nix-ssh
            HostKeyAlias ${sshAlias}
            IdentityFile ${config.sops.secrets."ssh/ed25519".path}
            IdentitiesOnly yes
            BatchMode yes
            StrictHostKeyChecking yes
            ConnectTimeout 5
            ServerAliveInterval 15
            ServerAliveCountMax 3
        '';
      };
    };
}
