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
# upstream module use DynamicUser. Reason: the runner agent invokes
# `nix build` against the system daemon, which means the user needs to
# appear in `nix.settings.trusted-users` to use flake settings /
# substituters — and trusted-users is name-based. DynamicUser names
# resolve through nss-systemd, which works but is one more moving
# piece; a real user with a stable UID is simpler to reason about.
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

      # `nix build` against the system daemon needs flake / substituter
      # settings the daemon only honours for trusted users.
      nix.settings.trusted-users = [ runnerUser ];

      # Preserve the runner's registration credentials across the
      # impermanence wipe. Without this, the agent re-registers with
      # GitHub on every reboot — works (PAT-based auto-registration)
      # but churns the runner list on GitHub's side.
      preservation.preserveAt."/persist".directories = [
        "/var/lib/github-runner"
      ];
    };
}
