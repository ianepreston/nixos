#!/usr/bin/env bash
# Wait for a freshly installed host to boot into its installed system.
#
# Shared by the three post-install wait loops: bootstrap:reinstall
# (AUTO_WAIT=true), vm:install, and recovery:test:full. Clears the stale
# known_hosts entries for the target first — the installer ISO and the
# installed system present different host keys on the same address — then
# polls over ssh until the target is ready, and exits 1 if it never is.
#
# Usage: wait-for-boot.sh <user> <dest> <port> <minutes>
#
# ## Readiness
#
# Ready means `multi-user.target` is active, NOT `systemctl
# is-system-running` returning running|degraded. That state is effectively
# unreachable on a freshly installed tests-server: radarr cannot start
# without the NFS content paths a VM does not have, decluttarr's pre-start
# polls radarr and fails, and its Restart= loop keeps a start job queued
# every ~30s. `is-system-running` reports `starting` until the job queue
# goes idle *for the first time*, so it only flips during the brief gap
# between one decluttarr attempt exiting and the next being queued — a gap
# a 3s poll routinely steps over. Measured on 2026-09-23: multi-user.target
# active at 2min36 and stable thereafter, while the old loop polled for a
# full 12 min without once catching an idle window (#720, #727).
#
# running|degraded is still accepted as an early exit for hosts whose units
# all settle — it just isn't required. multi-user.target active means
# sshd.service (which it wants) has started, which is what bootstrap:sync's
# rsync needs next. The older reinstall loop also waited out `starting` so
# sysinit-reactivation couldn't flap sshd mid-handshake; that target is only
# started by switch-to-configuration on a live switch (see its definition in
# nixos/modules/system/boot/systemd.nix), never on a first boot, so it is no
# reason to hold out for an idle job queue here.
#
# ## ssh options
#
# `UpdateHostKeys=no`: OpenSSH 9.5+'s default behavior is to open a flurry
# of parallel verification connections (one per advertised host-key
# algorithm) on every successful connect — to learn additional host keys.
# The VM only has an ed25519 host key, so every other verification attempt
# is refused, and the burst can fill sshd's MaxStartups window. The next
# legitimate connection (bootstrap:sync's rsync) then lands
# preauth-rejected. Disabling the update kills the flood.
#
# `BatchMode=yes` is safe with the hardware keys, despite appearances. The
# enrolled sk credentials are verify-required, so signing is a two-step:
# the first attempt comes back SSH_SK_ERR_PIN_REQUIRED and ssh then retries
# `with-pin`, prompting for the FIDO2 PIN. That prompt is written to
# /dev/tty by the sk helper, not through the stdio BatchMode governs, so
# BatchMode does not suppress it — verified against a cold token (unplugged
# and replugged to clear the cached pinUvAuthToken) on 2026-09-03.
#
# Worth stating because the intermediate failure looks fatal and names the
# wrong cause:
#
#   sshsk_sign: sk_sign failed with code -3
#   ssh-sk-helper: Signing failed: incorrect passphrase supplied
#                  to decrypt private key
#
# That is a normal step on the way to a successful signature, not a
# passphrase problem. What genuinely does fail is sk auth with no tty *and*
# no warm UV cache — nothing here runs that way, since bootstrap is
# interactive by nature. #547 removed BatchMode on the mistaken reading that
# it blocked the prompt; reverted, because failing fast on *any* prompt is
# exactly what a poll loop wants.
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <user> <dest> <port> <minutes>" >&2
  exit 2
fi
user=$1
dest=$2
port=$3
minutes=$4

echo -e "\x1B[32m[+] Polling for $user@$dest:$port after reboot (up to $minutes min)\x1B[0m"
ssh-keygen -R "$dest" -f ~/.ssh/known_hosts 2>/dev/null || true
ssh-keygen -R "[$dest]:$port" -f ~/.ssh/known_hosts 2>/dev/null || true

# One probe every ~3s. Both systemctl calls exit non-zero on the states
# being waited out, hence the `|| true`s; the outer fallback covers ssh
# itself failing while the target is still down.
for _ in $(seq 1 $((minutes * 20))); do
  state=$(ssh -p "$port" -o ConnectTimeout=2 -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -o UpdateHostKeys=no \
    "$user@$dest" \
    'systemctl is-active multi-user.target || true;
     systemctl is-system-running || true' \
    2>/dev/null | paste -sd, - || echo connecting)
  case "$state" in
    active,* | *,running | *,degraded)
      echo -e "\x1B[32m[+] $dest reachable (multi-user.target + systemd: $state)\x1B[0m"
      exit 0
      ;;
    *)
      sleep 3
      ;;
  esac
done
echo -e "\x1B[31m[!] $dest did not come up within $minutes minutes after install\x1B[0m" >&2
exit 1
