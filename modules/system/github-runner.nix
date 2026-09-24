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
      lib,
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
        # after each job, systemd restarts it (see the `serviceOverrides`
        # note below), and it comes back as a fresh registration with a
        # wiped state directory.
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
        # Upstream ties the restart policy to `ephemeral`:
        #
        #   Restart = if cfg.ephemeral then "on-success" else "no";
        #
        # which is correct for the success path above and leaves the
        # failure path with no recovery at all. On 2026-09-24 the
        # registration call to api.github.com hung (660B out, nothing
        # back), systemd killed ExecStartPre at the 90s
        # DefaultTimeoutStartSec, the unit latched `failed`, and CI was
        # dead for 56 minutes until someone started it by hand — with
        # two PRs queued behind it the whole time (#736).
        #
        # `Restart` is a plain assignment inside upstream's `mkMerge`
        # list and `serviceOverrides` merges last but at the same
        # priority, so a plain value here is an eval conflict rather
        # than an override. mkForce is required.
        #
        # RestartSec and the start limit stay at their defaults
        # (RestartUSec=100ms, StartLimitBurst=5 per
        # StartLimitIntervalUSec=10s). The consequence, measured on
        # hpp-1 by blocking the runner's egress to api.github.com:
        #
        # - Slow hang (the 09-24 shape, egress DROPped): each attempt
        #   burns the full 90s start timeout, so attempts are 90s apart
        #   and the 10s window never accumulates. Observed 8 restarts
        #   over 12m, `activating` throughout, never `failed`; the unit
        #   registered and went `active` 8s after egress was restored,
        #   with no human action.
        # - Fast fail (egress REJECTed, i.e. a revoked PAT or a 4xx):
        #   `config.sh` still takes ~4s per attempt even on an instant
        #   connection-refused, so the loop peaks at 3 starts in a
        #   rolling 10s window against a burst of 5. The start limit is
        #   therefore NOT reachable: observed 62 restarts over 7m, never
        #   `failed`. The unit retries indefinitely here too.
        #
        # So this unit never latches `failed` under either shape, and
        # SystemdUnitFailed will essentially never fire for it — the
        # liveness rule below is the real detector. That is the accepted
        # trade: an unbounded retry against GitHub (~13 attempts/minute,
        # with a human paged at 15m) in exchange for a runner that
        # recovers by itself the instant the fault clears.
        #
        # Do NOT widen StartLimitIntervalSec to make either path reach
        # `failed`. systemd's rate limiting counts *every* start,
        # including the ~96/day successful ephemeral re-registrations,
        # and widening it reintroduces exactly #736's defect — a
        # transient fault latching the unit off until someone starts it
        # by hand. Measured 7d on hpp-1 (694 normal starts): minimum gap
        # 20s, p05 23s, median 62s, and max starts per rolling window of
        # 1 (10s) / 2 (30s) / 3 (60s) / 5 (120s). A 60s window with
        # burst 6 would separate normal (3) from fast-fail (11) cleanly
        # if that trade is ever wanted; it is deliberately not taken.
        #
        # Upstream's `RestartForceExitStatus = [ 2 ]` becomes a no-op
        # under `always` — every exit status restarts already. Left in
        # place rather than cleared, since it costs nothing and reverts
        # cleanly if this override is ever dropped.
        serviceOverrides.Restart = lib.mkForce "always";
      };

      # Nothing watched this unit until #736 — a failed start was both
      # terminal *and* invisible, and the outage was found only by a
      # human noticing a stalled Actions queue. Keyed off `runnerName`
      # rather than hardcoded, so it follows the module to another host
      # exactly like the unit name does. Entries omit the `.service`
      # suffix (modules/system/observability-options.nix).
      myObservability.monitoredSystemdUnits = [ "github-runner-${runnerName}" ];

      myObservability.metricRuleGroups.github-runner.groups = [
        {
          name = "github-runner";
          rules = [
            {
              # The one rule that has to work, because under
              # `Restart=always` this unit never reaches `failed` (see
              # the serviceOverrides note above) and so
              # SystemdUnitFailed never fires for it.
              #
              # Phrased as absence of `active` rather than presence of
              # `activating`, for two reasons:
              #
              # 1. It is immune to sampling gaps. A retry loop is not
              #    `activating` for ~0.23s per cycle while systemd
              #    schedules the restart — 3.45% duty in the fast-fail
              #    shape, which gives a ~50% chance that one 30s scrape
              #    inside any 10m window lands in a gap and resets a
              #    `for:` timer on an instantaneous `activating == 1`.
              #    `max_over_time` over the window cannot be reset that
              #    way.
              # 2. It covers every failure shape with one expression —
              #    slow hang, fast-fail loop, latched `failed`,
              #    `inactive`, or stopped — rather than one rule per
              #    shape.
              #
              # No false positives: a healthy runner is `active` the
              # whole time it sits in "Listening for Jobs" and while it
              # runs a job, and is non-`active` only for the ~20-25s of
              # each registration. 15m of no `active` sample at all does
              # not occur in normal operation at any CI volume.
              alert = "GithubRunnerDown";
              expr = ''max_over_time(node_systemd_unit_state{name="github-runner-${runnerName}.service",state="active"}[15m]) == 0'';
              for = "0m";
              labels.severity = "warning";
              annotations = {
                summary = "GitHub Actions runner down on {{ $labels.instance }}";
                description = "github-runner-${runnerName}.service has not been active at any point in 15m — it is stuck retrying registration against api.github.com, or stopped. Self-hosted CI jobs will sit queued; GitHub holds them 24h before dropping them.";
              };
            }
          ];
        }
      ];
    };
}
