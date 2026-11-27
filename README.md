# Ian's Nix-Config

## Table of Contents

- [Feature Highlights](#feature-highlights)
- [Requirements](#requirements)
- [Structure](#structure-quick-reference)
- [Hosts](#hosts)
- [Module System](#module-system)
- [Server App Pattern](#server-app-pattern)
- [Operations runbooks](#operations-runbooks)
- [Secrets Management](#secrets-management)
- [Task Automation](#task-automation)
- [Guidance and Resources](#guidance-and-resources)

Where each kind of documentation lives, and who owns it, is set out in the
[documentation index](docs/README.md).

---

## Feature Highlights

- Flake-based multi-host, multi-platform configurations for NixOS, Darwin, and
  standalone Home-Manager
  - Modular architecture using
    [flake-parts](https://github.com/hercules-ci/flake-parts) and
    [import-tree](https://github.com/vic/import-tree) for automatic module
    discovery
  - Host specifications defined declaratively in `hostSpecs/` with a formal
    schema
  - Multi-context modules that can register NixOS, Darwin, and Home-Manager
    configs from a single file
- Secrets management via sops-nix and a private `nix-secrets` repo included as a
  flake input
- Declarative, btrfs-on-LUKS disk partitioning via disko
- Automated remote-bootstrapping of NixOS via
  [nixos-anywhere](https://github.com/nix-community/nixos-anywhere) and Taskfile
  tasks
- Custom NixOS recovery/installer ISO
- Local LLM inference: CUDA on Linux with TLS + SSO via the prod server,
  and a loopback-only Apple Metal API on `work`
- Theming via stylix
- Task automation via [go-task](https://taskfile.dev/) (`Taskfile.yaml`)

## Requirements

- Flake inputs track NixOS / nix-darwin 26.05 and Home-Manager release-26.05
  (see `flake.nix`)
- For secrets: access to the private `nix-secrets` repo via SSH
- Patience

This is a tweaked version of the repo originally provided by
[EmergentMind](https://github.com/EmergentMind/nix-config/). Check out his repos
and resources if you want to build your own.

## Structure Quick Reference

```
.
├── flake.nix              # Entrypoint — uses flake-parts + import-tree to auto-discover modules
├── Taskfile.yaml          # Task runner for build, rebuild, lint, format, etc.
├── hostSpecs/             # Declarative host specifications (hostname, platform, features)
│   ├── _host-spec.nix     # Schema definition for host specs
│   ├── luna.nix
│   ├── terra.nix
│   ├── work.nix
│   ├── penguin.nix
│   ├── toshibachromebook.nix
│   └── iso.nix
├── modules/               # All configuration modules, auto-imported by import-tree
│   ├── flake/             # Flake infrastructure (host-specs, module namespaces, dev shell, git hooks)
│   ├── profiles/          # Composable profiles (base, darwin-base, server, server-apps, workstation)
│   │   └── _ssh-keys/    # Human login pubkeys — authorized fleet-wide (see its README)
│   ├── system/            # System-level modules (sops, ssh, caddy, postgresql, mariadb, oci-containers, server-backups, observability, tailscale, …). Cross-cutting option surfaces (myCaddy.apps, myPostgresApp, myHomepage.tiles, mySqliteQuiesce.apps) are declared inline next to the service that consumes them.
│   │   └── _hm-core/     # Core home-manager config (git, zsh, starship, neovim, direnv, packages, platform-specific)
│   ├── apps/              # Server-app modules (jellyfin, bookorbit, miniflux, authentik, homepage, …) plus per-app blueprint dirs
│   ├── hardware/          # Hardware-specific modules (intel-quicksync, nvidia, yubikey, keyboards, rgb, xreal-headset)
│   ├── desktop/           # Desktop environment modules (gnome, audio, gaming, flatpak, themes, moonshine, quickemu)
│   │   └── _gnome/       # GNOME-specific sub-modules (dconf, cursor, stylix)
│   ├── programs/          # Application modules (browser, ghostty, comms, media, obsidian, etc.)
│   └── hosts/             # Per-host configurations and hardware/disk definitions
├── docs/                  # Runbooks, agent guides and the generated option reference (see docs/README.md)
├── scripts/               # Utility scripts (dconf capture)
└── assets/                # Static assets (wallpapers)
```

## Hosts

| Host                  | Platform       | Config Type            | Description                                                               |
| --------------------- | -------------- | ---------------------- | ------------------------------------------------------------------------- |
| **luna**              | x86_64-linux   | `nixosConfigurations`  | MSI GS43VR laptop — workstation + GNOME + gaming + NVIDIA GTX 1060        |
| **terra**             | x86_64-linux   | `nixosConfigurations`  | AMD desktop — workstation + GNOME + gaming + RTX 5080 + llama.cpp serving |
| **hpp-1**             | x86_64-linux   | `nixosConfigurations`  | Dev server — `server` + `server-apps` + Intel QuickSync transcoding       |
| **amos1**             | x86_64-linux   | `nixosConfigurations`  | Prod server — `server` + `server-apps` + NVIDIA transcoding               |
| **work**              | aarch64-darwin | `darwinConfigurations` | macOS work machine — Homebrew, Hammerspoon, work-specific git config      |
| **penguin**           | x86_64-linux   | `homeConfigurations`   | Standalone home-manager (WSL / non-NixOS Linux)                           |
| **toshibachromebook** | x86_64-linux   | `nixosConfigurations`  | Minimal ChromeBook config                                                 |
| **xps13**             | x86_64-linux   | `nixosConfigurations`  | Dell XPS 13 laptop — headless workstation + GNOME (built-in display dead) |
| **tests-server**      | x86_64-linux   | `nixosConfigurations`  | Server-shaped VM target — drives `task recovery:test:full` restore drill  |
| **tests-desktop**     | x86_64-linux   | `nixosConfigurations`  | Desktop-shaped VM target — workstation profile iteration                  |
| **iso**               | x86_64-linux   | `nixosConfigurations`  | Custom NixOS installer/recovery ISO                                       |

## Module System

Modules use a dendritic registration pattern powered by flake-parts. Each module
registers itself under one or more namespaces:

```nix
# Example: a module registering both NixOS and home-manager configs
flake.modules.nixos.gnome = { ... };
flake.modules.homeManager.gnome = { ... };
```

Available namespaces: `flake.modules.nixos`, `flake.modules.darwin`,
`flake.modules.homeManager`, `flake.modules.generic`.

Hosts compose their configuration by importing modules:

```nix
# In modules/hosts/terra.nix
modules = with inputs.self.modules.nixos; [
  workstation gnome docker gaming nvidia-rtx5080 ...
];
```

Home-manager modules are wired in via `home-manager.sharedModules` at the
profile level, so they automatically apply to all users on a host.

## Server App Pattern

Server-side applications (web apps hosted behind Caddy) live in
`modules/apps/<appname>.nix` and are composed into the `server-apps` profile
(which is itself layered on top of `server` — the core infra profile that owns
caddy, postgres, authentik, observability, backups, etc.). Each app module is
self-contained: it declares the OCI container or native service, contributes a
Caddy route, any database/user it needs, its sops secrets, an authentik
blueprint (if SSO-protected), and a homepage tile — all in one place.
[`modules/apps/bookorbit.nix`](modules/apps/bookorbit.nix) is the canonical
container/Postgres/OIDC example: BookOrbit runs in Podman, uses the shared
Postgres instance, and stores its OIDC settings in its own database after UI
setup. For a native service with OIDC credentials supplied as JSON through a
rendered env file,
see [`modules/apps/tandoor.nix`](modules/apps/tandoor.nix).

App modules contribute to a small set of aggregator options declared inline next
to the services that consume them (in `modules/system/` or, for `myAuthentik.*`,
`modules/apps/authentik.nix`):

- `myCaddy.apps.<name>` — hands a route block to the wildcard
  `*.${serverDomain}` virtualHost (one wildcard cert covers every app, dodging
  Let's Encrypt rate limits).
- `myPostgresApp.<name>` — provisions the database/role plus a sops-managed
  password rotation oneshot, so containerized apps connecting over TCP get a
  passworded role without per-app boilerplate.
- `myAuthentik.oidcApps.<name>` — for apps that speak OIDC: declares the sops
  secret pair, contributes a blueprint dir, stacks the necessary worker-side env
  vars onto authentik, and optionally renders a per-app env file consumed by the
  upstream image.
- `myAuthentik.forwardAuthApps.<name>` — for apps that don't speak OIDC:
  generates the proxy provider/application/policy binding blueprint and a Caddy
  `forward_auth` route in one go (the embedded outpost's `providers` list is
  owned by a single merged blueprint per host so apps don't clobber each other).
- `myHomepage.tiles.<name>` — adds a tile to the homepage dashboard.

Every one of these options, and the rest of the `my*` surface the server
configuration imports (container plumbing, service endpoints, state and
recovery, runtime credentials, observability, MQTT, and the Omnigent and
Valheim app options), is listed with its type, default and declaring file in
the generated [option reference](docs/reference/options.md), which also covers
the NixOS-side `myLlamaCpp` options and `myLlmMetrics`, `myBambuddy`, the
home-manager options `myPi` and `myVibes`, and the Darwin-only `myLlamaCpp`
options. The module conventions an app must follow (registration, container
runtime, NFS UID alignment, networking, image pins, volumes, Postgres, secrets) are in
[server app conventions](docs/server-apps.md); adding an app end to end is the
[`add-app` workflow](skills/add-app/SKILL.md).

## Operations runbooks

Operator procedures live in [`docs/runbooks/`](docs/runbooks/), one topic per
file:

| Runbook | Covers |
| ------- | ------ |
| [Backups and restore](docs/runbooks/backup-restore.md) | restic/pg_dump layout, catastrophic rebuild, per-app restore recipes, cross-host recovery testing |
| [PostgreSQL major-version upgrades](docs/runbooks/postgresql-upgrade.md) | `pg_upgrade` procedure and rollback |
| [Activating a host](docs/runbooks/activation.md) | what `scripts/activate-nixos.sh` asserts, preflight probes, SSH multiplexing rules |
| [Bootstrapping a new host](docs/runbooks/bootstrap.md) | nixos-anywhere install, secrets setup, reinstall, VM testing |
| [Recovering from a sops decryption failure](docs/runbooks/sops-recovery.md) | re-running decryption and role-password units |
| [Fetch hashes](docs/runbooks/fetch-hashes.md) | why CI regenerates fixed-output hashes, `task hashes` |
| [Authentik (SSO)](docs/runbooks/authentik-sso.md) | blueprints, adding an OIDC app, forward-auth |
| [Jellyfin](docs/runbooks/jellyfin.md) | LDAP authentication via authentik, hardware transcoding |
| [Home Assistant](docs/runbooks/home-assistant.md) | native deployment, adding devices, declarative vs stateful config |
| [Local LLM inference](docs/runbooks/local-llm.md) | llama.cpp on Apple Silicon and CUDA hosts, sizing, coding agents |
| [Coding sandboxes](docs/coding-sandbox.md) | the sandboxed coding-agent runtime |

## Secrets Management

Secrets are stored in a private `nix-secrets` repository pulled in as a flake
input and managed with [sops-nix](https://github.com/Mic92/sops-nix).

- Secrets are YAML files in the `nix-secrets` repo: `sops/<hostname>.yaml`,
  plus per-consumer files (`common.yaml`, `tailnet.yaml`, `llm.yaml`,
  `server-shared.yaml`, ...) each encrypted to exactly the hosts that read
  them. `task secrets:matrix` checks that. Its assertion logic has synthetic
  unit tests, run by CI and `task check` as the `sops-recipient-matrix` flake
  check (`nix build .#checks.<system>.sops-recipient-matrix`); they read no
  secrets and contact no host.
- Age encryption keys are bootstrapped from host SSH keys
  (`/etc/ssh/ssh_host_ed25519_key`)
- Home-manager secrets use `~/.config/sops/age/host.txt`, which activation
  derives from the same host key, so a host decrypts only the files that list
  it. `~/.config/sops/age/keys.txt` is the `sops` CLI's operator identity:
  YubiKey stubs, present only on the authoring workstations (terra, luna)
- Configured in `modules/system/sops.nix` with both NixOS and home-manager
  integration
- `sops.useSystemdActivation = true` runs decryption as a real systemd unit
  (`sops-install-secrets.service`) instead of a nixos-activation script, so
  consumer units can order against it explicitly

Recovering a host whose `sops-install-secrets.service` failed is the
[sops recovery runbook](docs/runbooks/sops-recovery.md); creating, publishing
and pinning secrets is [docs/agents/secrets.md](docs/agents/secrets.md).

## Task Automation

Common operations are automated via `Taskfile.yaml`. The bootstrap, recovery,
and secrets-management workflows live in `taskfiles/*.yaml` and are pulled in
via Task's `includes:`, so `task --list` shows the full prefixed surface
(`bootstrap:*`, `recovery:*`, `secrets:*`).

| Command                                          | Description                                                                      |
| ------------------------------------------------ | -------------------------------------------------------------------------------- |
| `task rebuild`                                   | Rebuild current NixOS host (asserts hostname + closure identity before activating) |
| `task rebuild:<host>`                            | Rebuild config `<host>` on this machine; refuses unless this machine's hostname is `<host>` |
| `task deploy:<host>`                             | Build locally, copy, and activate on a live remote host; identity asserted on target |
| `task build_darwin:<host>`                       | Rebuild a nix-darwin host                                                        |
| `task build_home:<target>`                       | Rebuild standalone home-manager                                                  |
| `task build`                                     | Build a host without switching (default: luna)                                   |
| `task build-all`                                 | Build luna, terra, hpp-1, and amos1 without switching                            |
| `task update`                                    | Update flake inputs                                                              |
| `task update_dconf`                              | Capture host dconf config into the repo via `scripts/dconf.sh`                   |
| `task fmt`                                       | Format all Nix files with nixfmt                                                 |
| `task check`                                     | Lock check, sequential eval, lint hooks, native flake checks (shared with CI)     |
| `task check:linux`                               | Build every x86_64-linux flake check natively or on a configured remote builder  |
| `task iso`                                       | Build the installer/recovery ISO                                                 |
| `task garbage_collect`                           | Collect unreachable store objects and delete generations older than 7 days       |
| `task hashes [-- --check]`                       | Regenerate the fetch hashes Renovate can't maintain; `--check` only reports      |
| `task docs:options`                              | Regenerate the public `my*` option reference in `docs/reference/options.md`      |
| `task bootstrap:new HOST=x DEST=ip`              | New host pipeline: install, hwconfig, secrets setup, sync + rebuild              |
| `task bootstrap:reinstall HOST=x DEST=ip`        | Reinstall existing host: install + sync + rebuild (no secrets pause)             |
| `task bootstrap:install HOST=x DEST=ip`          | Run nixos-anywhere to install NixOS; prints age key at end                       |
| `task bootstrap:hwconfig HOST=x DEST=ip`         | Extract hardware-configuration.nix from target                                   |
| `task bootstrap:hostkey HOST=x DEST=ip`          | Re-derive age key from live host SSH key (fallback if install output was missed) |
| `task bootstrap:secrets HOST=x DEST=ip`          | Add host age key to nix-secrets, create host secrets, commit                     |
| `task bootstrap:sync HOST=x DEST=ip`             | Rsync nixos and nix-secrets to target                                            |
| `task bootstrap:rebuild HOST=x DEST=ip`          | Build on target, then activate it after asserting hostname + closure name         |
| `task recovery:app APP=x HOST=y [SOURCE_HOST=z]` | Restore a single app from restic, driven by the generated recovery manifest      |
| `task recovery:all HOST=x`                       | Restore every enabled manifest entry in order (SOURCE_HOST defaults to HOST)     |
| `task recovery:test:full SOURCE_HOST=x`          | Quarterly drill — install tests-server VM, restore four apps, teardown           |
| `task secrets:oidc APP=x [HOST=y]`               | Generate OIDC `client_id` + `client_secret` for an app on a host                 |
| `task secrets:dbpw APP=x [HOST=y]`               | Generate a postgres `db_password` for an app on a host                           |
| `task secrets:secret APP=x KEY=k`                | Generic high-entropy hex secret at `<app>.<key>`                                 |
| `task secrets:edit:<host>`                       | Open a host's sops yaml in `$EDITOR`                                             |
| `task secrets:view:<host>`                       | Decrypt and print a host's sops yaml                                             |
| `task llm:models [HOST=x]`                       | List cached GGUFs against the configured set (default HOST=terra; local on Darwin) |
| `task llm:models:prune [HOST=x] [APPLY=true]`    | Remove unconfigured cached GGUFs; dry run unless `APPLY=true`                    |
| `task secrets:rekey`                             | Re-encrypt every `sops/*.yaml` against current `.sops.yaml`                      |


Every task that activates a closure goes through `scripts/activate-nixos.sh`,
which asserts the target's identity before switching; what it checks and how
to probe a host without building is in the
[activation runbook](docs/runbooks/activation.md). Fixed-output hashes that
Renovate can't maintain are regenerated by `task hashes`; see
[fetch hashes](docs/runbooks/fetch-hashes.md). `task docs:options` regenerates
the [option reference](docs/reference/options.md).

## Guidance and Resources

- [NixOS.org Manuals](https://nixos.org/learn/)
- [Official Nix Documentation](https://nix.dev)
  - [Best practices](https://nix.dev/guides/best-practices)
- [Noogle](https://noogle.dev/) - Nix API reference documentation.
- [Official NixOS Wiki](https://wiki.nixos.org/)
- [NixOS Package Search](https://search.nixos.org/packages)
- [NixOS Options Search](https://search.nixos.org/options?)
- [Home Manager Option Search](https://home-manager-options.extranix.com/)
- [NixOS & Flakes Book](https://nixos-and-flakes.thiscute.world/) - an excellent
  introductory book by Ryan Yin
