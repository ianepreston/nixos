# GitHub Actions self-hosted runner.
#
# Imported directly by hosts (not via the `server` profile) so a future
# move to a dedicated runner box is a single import line. Runner
# identity is derived from `hostSpec.hostName`, so dropping this module
# onto another host names the systemd unit / label after that host with
# no further edits.
#
# Architecture: bare-metal systemd unit (not container, not VM) — the
# whole point of self-hosting is to share the host's warm /nix/store
# with CI. Containerising or VMing would either bind-mount the store
# (defeating isolation) or maintain a separate one (defeating the
# speedup). The upstream `services.github-runners.<name>` module
# already applies the standard systemd hardening (NoNewPrivileges,
# ProtectSystem, PrivateDevices, ...).
#
# We pin an explicit `user = "github-runner"` rather than letting the
# upstream module use DynamicUser: DynamicUser names resolve through
# nss-systemd, which works but is one more moving piece, and a real user
# with a stable UID is simpler to reason about.
#
# The runner is deliberately NOT in `nix.settings.trusted-users`. Nix's
# own docs are blunt about what that grants: "Adding a user to
# `trusted-users` is essentially equivalent to giving that user root
# access to the system." A trusted user can point the daemon at their own
# substituters and signing keys, set `build-users-group = ""` so builds
# run as root, disable the sandbox, or install a `post-build-hook` — so
# anything executing as the runner (a third-party action, a malicious
# workflow) would own this host outright.
#
# CI does not need it. Trust governs the ability to *override* restricted
# settings from the client, not to receive them: `experimental-features`
# comes from `modules/profiles/base.nix` via /etc/nix/nix.conf and applies
# to every user. There is no `nixConfig` block in flake.nix for
# `accept-flake-config` to accept, and no custom substituters anywhere in
# this repo. If CI ever does need a setting, declare it system-wide in
# `nix.settings` (or, for caches specifically, `trusted-substituters` —
# a pre-approved list an untrusted user may opt into) rather than handing
# the runner blanket override rights.
#
# PR-from-fork safety lives in the workflow (`.github/workflows/check.yml`),
# not here: a fork PR can edit workflow YAML, so the `build` job is
# gated with an `if:` that requires the PR head to be in this repo.
_: {
  flake.modules.nixos.github-runner =
    {
      config,
      hostSpec,
      pkgs,
      ...
    }:
    let
      runnerName = hostSpec.hostName;
      runnerUser = "github-runner";
    in
    {
      users.users.${runnerUser} = {
        isSystemUser = true;
        group = runnerUser;
        # Home is the runner's StateDirectory leaf (writable, owned by
        # the runner user, per-instance) rather than the parent
        # `/var/lib/github-runner`. The upstream module sets
        # `ProtectSystem = "strict"`, which leaves only StateDirectory /
        # WorkingDirectory / LogsDirectory writable — actions that
        # expect `mkdir $HOME/.ssh` (webfactory/ssh-agent,
        # actions/checkout's git-credentials helper, etc.) fail with
        # ENOENT against an RO parent.
        home = "/var/lib/github-runner/${runnerName}";
      };
      users.groups.${runnerUser} = { };

      # Fine-grained PAT scoped to ianepreston/nixos with
      # "Administration: Read and write" (the permission GitHub
      # requires to mint runner registration tokens). The agent uses
      # the PAT to fetch fresh registration tokens itself, so we don't
      # fight the 1-hour expiry of raw registration tokens.
      #
      # The upstream module's ExecStartPre runs as root (via `+` prefix)
      # and copies this file into the state dir with 0666, so the sops
      # secret can stay root-owned 0400.
      sops.secrets."github_runner/pat" = {
        inherit (hostSpec) sopsFile;
        owner = "root";
        group = "root";
        mode = "0400";
        restartUnits = [ "github-runner-${runnerName}.service" ];
      };

      services.github-runners.${runnerName} = {
        enable = true;
        url = "https://github.com/ianepreston/nixos";
        tokenFile = config.sops.secrets."github_runner/pat".path;
        user = runnerUser;
        # Re-register an existing runner of the same name on restart
        # (e.g. after `replace`-style PAT rotation or a state wipe).
        replace = true;
        # One job per runner registration: the agent de-registers and exits
        # after each job, systemd restarts it (Restart=on-success), and it
        # comes back as a fresh registration with a wiped state directory.
        #
        # This is what stops a compromised workflow from leaving anything
        # behind. Previously the state dir persisted between jobs *and*
        # across the impermanence wipe (see the preservation entry this
        # replaced), so a foothold planted by a malicious action survived
        # reboots indefinitely.
        #
        # It does NOT cost us the warm /nix/store that this runner exists
        # for (#180). Ephemeral wipes the runner's own StateDirectory
        # (/var/lib/github-runner/<name>) and RuntimeDirectory
        # (/run/github-runner/<name>, which upstream already cleans on
        # every service start regardless — `# Always clean workDir` in the
        # module's service.nix). /nix/store is daemon-owned and system-wide,
        # outside both, and is never touched. The per-job cost is a fresh
        # `actions/checkout` clone plus a re-registration handshake —
        # seconds, not a rebuild.
        #
        # Requires `tokenFile` to be a PAT rather than a registration
        # token, since the agent mints a new registration on every start.
        # That is what `github_runner/pat` above is.
        ephemeral = true;
        extraLabels = [
          "nixos"
          runnerName
        ];
        # The module's default PATH is minimal (bash, coreutils, git,
        # tar, gz, nix, findutils, grep, sed, systemd). Workflows need:
        # - openssh: webfactory/ssh-agent invokes `ssh-agent` to load
        #   NIX_SECRETS_DEPLOY_KEY for fetching the private flake input.
        # - jq: the flake-check job pipes `nix eval --json` through it.
        extraPackages = [
          pkgs.openssh
          pkgs.jq
        ];
      };
    };
}
