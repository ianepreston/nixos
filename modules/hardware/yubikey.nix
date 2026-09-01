# YubiKey - Multi Context Aspect
# FIDO2/U2F device access for hardware-backed SSH keys (sk-ssh-ed25519),
# plus the client-side wiring that makes the enrolled keys usable.
#
# NixOS half: without these udev rules a normal user can't open the
# /dev/hidraw* node, so `ssh-keygen -t ed25519-sk` fails on a plugged-in
# key even though OpenSSH's sk helper links against libfido2 correctly —
# the "device not found" you get with nothing plugged in is not evidence
# that enrolment will work. libfido2 ships etc/udev/rules.d/70-u2f.rules,
# which services.udev.packages picks up.
#
# FIDO2 talks to the key over hidraw directly; pcscd is only needed for
# the PIV/OpenPGP applets, which nothing here uses.
#
# home-manager half: distributes the two enrolled credentials' *stub*
# files and points ssh at them. See the `tokens` comment below.
{ inputs, ... }:
let
  sopsFile = builtins.toString inputs.nix-secrets + "/sops/shared.yaml";
  sshKeysDir = ../profiles/_ssh-keys;

  # The enrolled YubiKeys, by the suffix in their file names. Both
  # credentials are *resident* (`-O resident`), so what lives in
  # `ssh/ed25519_sk_<n>` in shared.yaml is only a credential handle plus
  # the public half — inert without the physical token in hand. It is in
  # sops rather than committed next to the pubkeys because
  # `_ssh-keys/` is contractually pubkeys-only (see its README), and
  # because `~/.ssh/id_ed25519` already arrives by exactly this route.
  #
  # Being resident is what makes this distribution *optional* rather than
  # load-bearing: a machine without the stub can still recover it from the
  # token with `ssh-keygen -K`. This just means you never have to. Never
  # re-run `ssh-keygen -t ed25519-sk` for an existing token — that mints a
  # new credential with a new public key, which then has to be added to
  # `_ssh-keys/` and rebuilt across the fleet.
  tokens = [
    "1"
    "2"
  ];
in
{
  flake.modules.nixos.yubikey =
    { pkgs, ... }:
    {
      services.udev.packages = [ pkgs.libfido2 ];
      environment.systemPackages = [ pkgs.yubikey-manager ];

      home-manager.sharedModules = [ inputs.self.modules.homeManager.yubikey ];
    };

  flake.modules.homeManager.yubikey =
    { config, lib, ... }:
    let
      inherit (config.home) homeDirectory;
      stubPath = n: "${homeDirectory}/.ssh/id_ed25519_sk_${n}";
    in
    {
      # Self-contained: the workstation profile already pulls in the
      # homeManager sops module via modules/system/sops.nix, but importing
      # it here means this aspect works anywhere it's imported. Module
      # identity dedups the double import.
      imports = [ inputs.self.modules.homeManager.sops ];

      sops.secrets = lib.listToAttrs (
        map (
          n:
          lib.nameValuePair "ssh/ed25519_sk_${n}" {
            inherit sopsFile;
            path = stubPath n;
          }
        ) tokens
      );

      # ssh reads the public half out of the stub itself, so these are a
      # convenience for `ssh-keygen -l` / `ssh-copy-id` rather than a
      # requirement — same role as the `.ssh/id_ed25519.pub` seeding in
      # modules/profiles/base.nix.
      home.file = lib.listToAttrs (
        map (
          n:
          lib.nameValuePair ".ssh/id_ed25519_sk_${n}.pub" {
            source = sshKeysDir + "/id_ed25519_sk_${n}.pub";
          }
        ) tokens
      );

      # `~/.ssh/id_ed25519_sk_<n>` is not one of the file names ssh probes
      # by default (it looks for a bare `id_ed25519_sk`), so the stubs have
      # to be named explicitly or they are never offered.
      #
      # id_ed25519 has to be re-listed even though it *is* a default:
      # OpenSSH appends its built-in identity list only when no
      # IdentityFile was configured at all (readconf.c), so naming the sk
      # keys here would otherwise silently drop the sops-provisioned
      # software key — removing the fallback that keeps a host reachable
      # when no token is plugged in.
      #
      # Order matters, and the software key goes *first* on purpose. A
      # resident credential only exists on its own token, so an sk key
      # listed ahead of it makes every connection attempt a hardware
      # signature: with the other YubiKey in the slot (or none) ssh burns
      # the attempt on `signing failed ... invalid format`, and with the
      # right one it demands a PIN + touch. That breaks unattended ssh —
      # `task deploy:*`'s nix-copy-closure died exactly this way, and the
      # recovery/bootstrap taskfiles fire many discrete ssh calls each.
      #
      # Software-first costs nothing in migration terms: `task
      # ssh:verify-keys` is what deliberately exercises the hardware keys,
      # and once #500 prunes the per-host software keys out of
      # `_ssh-keys/` the servers stop accepting id_ed25519 and these
      # entries take over on their own. At that point drop it from this
      # list (#501).
      programs.ssh.settings."*".IdentityFile = [
        "${homeDirectory}/.ssh/id_ed25519"
      ]
      ++ (map stubPath tokens);
    };
}
