# Ian's Nix-Config

## Table of Contents

- [Feature Highlights](#feature-highlights)
- [Requirements](#requirements)
- [Structure](#structure-quick-reference)
- [Hosts](#hosts)
- [Module System](#module-system)
- [Secrets Management](#secrets-management)
- [Task Automation](#task-automation)
- [Bootstrapping a New Host](#bootstrapping-a-new-host)
- [Guidance and Resources](#guidance-and-resources)

---

## Feature Highlights

- Flake-based multi-host, multi-platform configurations for NixOS, Darwin, and standalone Home-Manager
  - Modular architecture using [flake-parts](https://github.com/hercules-ci/flake-parts) and [import-tree](https://github.com/vic/import-tree) for automatic module discovery
  - Host specifications defined declaratively in `hostSpecs/` with a formal schema
  - Multi-context modules that can register NixOS, Darwin, and Home-Manager configs from a single file
- Secrets management via sops-nix and a private `nix-secrets` repo included as a flake input
- Declarative, btrfs-on-LUKS disk partitioning via disko
- Automated remote-bootstrapping of NixOS via [nixos-anywhere](https://github.com/nix-community/nixos-anywhere) and Taskfile tasks
- Custom NixOS recovery/installer ISO
- Theming via stylix
- Task automation via [go-task](https://taskfile.dev/) (`Taskfile.yaml`)

## Requirements

- NixOS 25.11+ / nix-darwin 25.11+ / Home-Manager release-25.11
- For secrets: access to the private `nix-secrets` repo via SSH
- Patience

This is a tweaked version of the repo originally provided by [EmergentMind](https://github.com/EmergentMind/nix-config/). Check out his repos and resources if you want to build your own.

## Structure Quick Reference

```
.
├── flake.nix              # Entrypoint — uses flake-parts + import-tree to auto-discover modules
├── Taskfile.yaml          # Task runner for build, rebuild, lint, format, etc.
├── hostSpecs/             # Declarative host specifications (hostname, platform, features)
│   ├── host-spec.nix      # Schema definition for host specs
│   ├── luna.nix
│   ├── terra.nix
│   ├── work.nix
│   ├── penguin.nix
│   ├── toshibachromebook.nix
│   └── iso.nix
├── modules/               # All configuration modules, auto-imported by import-tree
│   ├── flake/             # Flake infrastructure (host-specs, module namespaces, dev shell, git hooks)
│   ├── profiles/          # Composable profiles (base, darwin-base, workstation)
│   │   ├── _hm-core/     # Core home-manager config (git, zsh, starship, neovim, direnv)
│   │   └── _ssh-keys/    # Public SSH keys
│   ├── system/            # System-level modules (sops, ssh, docker, homebrew, smbclient)
│   ├── hardware/          # Hardware-specific modules (nvidia, yubikey, keyboards, rgb)
│   ├── desktop/           # Desktop environment modules (gnome, audio, gaming, flatpak, themes)
│   │   └── _gnome/       # GNOME-specific sub-modules (dconf, cursor, stylix)
│   ├── programs/          # Application modules (browser, ghostty, comms, media, obsidian, etc.)
│   └── hosts/             # Per-host configurations and hardware/disk definitions
├── scripts/               # Utility scripts (dconf, sops check)
└── assets/                # Static assets (wallpapers)
```

## Hosts

| Host | Platform | Config Type | Description |
|------|----------|-------------|-------------|
| **luna** | x86_64-linux | `nixosConfigurations` | MSI GS43VR laptop — workstation + GNOME + gaming + NVIDIA GTX 1060 |
| **terra** | x86_64-linux | `nixosConfigurations` | AMD desktop — workstation + GNOME + gaming + NVIDIA RTX 5080 + streaming |
| **work** | aarch64-darwin | `darwinConfigurations` | macOS work machine — Homebrew, Hammerspoon, work-specific git config |
| **penguin** | x86_64-linux | `homeConfigurations` | Standalone home-manager (WSL / non-NixOS Linux) |
| **toshibachromebook** | x86_64-linux | `nixosConfigurations` | Minimal ChromeBook config |
| **testvm** | x86_64-linux | `nixosConfigurations` | Minimal VM for bootstrap testing (quickemu) |
| **iso** | x86_64-linux | `nixosConfigurations` | Custom NixOS installer/recovery ISO |

## Module System

Modules use a dendritic registration pattern powered by flake-parts. Each module registers itself under one or more namespaces:

```nix
# Example: a module registering both NixOS and home-manager configs
flake.modules.nixos.gnome = { ... };
flake.modules.homeManager.gnome = { ... };
```

Available namespaces: `flake.modules.nixos`, `flake.modules.darwin`, `flake.modules.homeManager`, `flake.modules.generic`.

Hosts compose their configuration by importing modules:

```nix
# In modules/hosts/terra.nix
modules = with inputs.self.modules.nixos; [
  workstation gnome docker gaming nvidia-rtx5080 ...
];
```

Home-manager modules are wired in via `home-manager.sharedModules` at the profile level, so they automatically apply to all users on a host.

## Secrets Management

Secrets are stored in a private `nix-secrets` repository pulled in as a flake input and managed with [sops-nix](https://github.com/Mic92/sops-nix).

- Secrets are YAML files in the `nix-secrets` repo (`sops/shared.yaml`, `sops/<hostname>.yaml`)
- Age encryption keys are bootstrapped from host SSH keys (`/etc/ssh/ssh_host_ed25519_key`)
- Home-manager secrets use `~/.config/sops/age/keys.txt`
- Configured in `modules/system/sops.nix` with both NixOS and home-manager integration

## Task Automation

Common operations are automated via `Taskfile.yaml`:

| Command | Description |
|---------|-------------|
| `task rebuild` | Rebuild current NixOS host |
| `task rebuild:<host>` | Rebuild a specific NixOS host |
| `task build_darwin:<host>` | Rebuild a nix-darwin host |
| `task build_home:<target>` | Rebuild standalone home-manager |
| `task build` | Build a host without switching (default: luna) |
| `task build-all` | Build all NixOS host configurations |
| `task update` | Update flake inputs |
| `task lint` | Run statix and deadnix |
| `task fmt` | Format all Nix files with nixfmt |
| `task check` | Full pre-push check (format + lint + flake check) |
| `task iso` | Build the installer/recovery ISO |
| `task garbage_collect` | Remove store objects older than 7 days |
| `task bootstrap:new HOST=x DEST=ip` | New host pipeline: install, hwconfig, secrets setup, sync + rebuild |
| `task bootstrap:reinstall HOST=x DEST=ip` | Reinstall existing host: install + sync + rebuild (no secrets pause) |
| `task bootstrap:install HOST=x DEST=ip` | Run nixos-anywhere to install NixOS; prints age key at end |
| `task bootstrap:hwconfig HOST=x DEST=ip` | Extract hardware-configuration.nix from target |
| `task bootstrap:hostkey HOST=x DEST=ip` | Re-derive age key from live host SSH key (fallback if install output was missed) |
| `task bootstrap:secrets HOST=x DEST=ip` | Add host age key to nix-secrets, create host secrets, commit |
| `task bootstrap:sync HOST=x DEST=ip` | Rsync nixos and nix-secrets to target |
| `task bootstrap:rebuild HOST=x DEST=ip` | Run nixos-rebuild switch on target |

## Bootstrapping a New Host

### Prerequisites

- Target machine booted into a NixOS ISO (use `task iso` for a custom one)
- This repo and `nix-secrets` cloned on the source machine (e.g. `~/src/{nixos,nix-secrets}`)
- A key on the source machine that can decrypt secrets (`~/.config/sops/age/keys.txt`)

### 1. Create host config files

Before bootstrapping, the target host needs configuration in this repo:

- `hostSpecs/newhostname.nix` — host specification (copy from an existing host)
- `modules/hosts/_newhostname-disks.nix` — disko disk layout
- `modules/hosts/newhostname.nix` — host module (which modules to compose)
- A placeholder `modules/hosts/_newhostname-hardware.nix` (copy from an existing host, replaced post-install)

Also add the new host to `hostSpecs/default.nix` imports list, then `git add` all new files — the
flake uses `git+file://` and won't see untracked files.

The real hardware config is extracted after installation via `task bootstrap:hwconfig`.

### 2. Run the bootstrap

```bash
# Full pipeline for a new host — pauses twice: once for reboot, once for secrets setup:
task bootstrap:new HOST=newhostname DEST=192.168.1.50

# With LUKS encryption:
task bootstrap:new HOST=newhostname DEST=192.168.1.50 LUKS_PASS=temp-passphrase
```

The pipeline pauses once for the target to reboot after install, then automatically configures
secrets in nix-secrets via `bootstrap:secrets`.

Individual steps can be run independently for partial re-runs after failures:

```bash
task bootstrap:install  HOST=newhostname DEST=192.168.1.50  # nixos-anywhere + prints age key
task bootstrap:hwconfig HOST=newhostname DEST=192.168.1.50  # extract hardware config
task bootstrap:hostkey  HOST=newhostname DEST=192.168.1.50  # re-derive age key from live host
task bootstrap:secrets  HOST=newhostname DEST=192.168.1.50  # configure nix-secrets for host
task bootstrap:sync     HOST=newhostname DEST=192.168.1.50  # rsync configs to target
task bootstrap:rebuild  HOST=newhostname DEST=192.168.1.50  # remote nixos-rebuild switch
```

### 3. Secrets setup

`bootstrap:new` handles secrets automatically via `bootstrap:secrets`, which:

1. Derives the host's age key from its SSH host key
2. Adds the key to `nix-secrets/.sops.yaml` (host anchor + creation rules)
3. Creates `nix-secrets/sops/newhostname.yaml` with a generated SSH key
4. Re-encrypts shared secrets for the new host
5. Commits nix-secrets (locally — not pushed)

To run this step manually (e.g. after a partial re-run):

```bash
task bootstrap:secrets HOST=newhostname DEST=192.168.1.50
```

The rebuild uses `--override-input nix-secrets path:../nix-secrets`, so the local commit
is sufficient during bootstrap. After the host is up, push nix-secrets and run
`nix flake update nix-secrets` in this repo so normal rebuilds work without the override.

### Reinstalling an existing host

For hosts that already have keys and secrets configured, use `bootstrap:reinstall` — it skips
the secrets setup pause:

```bash
task bootstrap:reinstall HOST=existinghost DEST=192.168.1.50
```

### VM testing

A `testvm` host config is included for bootstrap testing. Build the ISO if needed
(`task iso`), then:

```bash
# Create a quickemu config (adjust paths as needed)
mkdir -p ~/vms/testvm
cat > ~/vms/testvm.conf <<'EOF'
guest_os="linux"
disk_img="/home/ipreston/vms/testvm/testvm.qcow2"
iso="/home/ipreston/src/nixos/latest.iso"
disk_size="20G"
ram="4G"
cpu_cores="2"
EOF

# Boot the VM headlessly with a fixed SSH port
quickemu --vm ~/vms/testvm.conf --display none --ssh-port 22222
```

Then run the full bootstrap pipeline using `127.0.0.1` (not `localhost` — QEMU only forwards
IPv4):

```bash
task bootstrap:new HOST=testvm DEST=127.0.0.1 SSH_PORT=22222
```

Or run individual steps for debugging:

```bash
task bootstrap:install  HOST=testvm DEST=127.0.0.1 SSH_PORT=22222
# Wait for reboot, then:
task bootstrap:hwconfig HOST=testvm DEST=127.0.0.1 SSH_PORT=22222
task bootstrap:hostkey  HOST=testvm DEST=127.0.0.1 SSH_PORT=22222
# Follow the secrets steps above, then:
task bootstrap:sync     HOST=testvm DEST=127.0.0.1 SSH_PORT=22222
task bootstrap:rebuild  HOST=testvm DEST=127.0.0.1 SSH_PORT=22222
```

To start fresh, delete the VM disk and OVMF vars:

```bash
rm -f ~/vms/testvm/testvm.qcow2 ~/vms/testvm/OVMF_VARS.fd
```

## Guidance and Resources

- [NixOS.org Manuals](https://nixos.org/learn/)
- [Official Nix Documentation](https://nix.dev)
  - [Best practices](https://nix.dev/guides/best-practices)
- [Noogle](https://noogle.dev/) - Nix API reference documentation.
- [Official NixOS Wiki](https://wiki.nixos.org/)
- [NixOS Package Search](https://search.nixos.org/packages)
- [NixOS Options Search](https://search.nixos.org/options?)
- [Home Manager Option Search](https://home-manager-options.extranix.com/)
- [NixOS & Flakes Book](https://nixos-and-flakes.thiscute.world/) - an excellent introductory book by Ryan Yin
