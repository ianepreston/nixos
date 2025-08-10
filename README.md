# Ian's Nix-Config

## Table of Contents

- [Feature Highlights](#feature-highlights)
- [Roadmap of TODOs](docs/TODO.md)
- [Requirements](#requirements)
- [Structure](#structure-quick-reference)
- [Adding a New Host](docs/addnewhost.md)
- [Secrets Management](#secrets-management)
- [Initial Install Notes](docs/installnotes.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Acknowledgements](#acknowledgements)
- [Guidance and Resources](#guidance-and-resources)

---

Watch NixOS related videos on EmergentMind's [YouTube channel](https://www.youtube.com/@Emergent_Mind).

## Feature Highlights

- Flake-based multi-host, multi-user configurations for NixOS, Darwin, and Home-Manager

  - Core configs for hosts and users dynamically handle nixos- or darwin-based host specifications
  - Optional configs for user and host-specific needs
  - Facilitation for custom modules, overlays, packages, and library
  - Handle Home-manager standalone configuration for Linux environments other than NixOS

- Secrets management via sops-nix and a _private_ nix-secrets repo that is included as a flake input
- Declarative, LUKS-encrypted btrfs partitions via disko
- Automated remote-bootstrapping of NixOS, nix-config, and _private_ nix-secrets
- Handles multiple YubiKey devices and agent forwarding for touch-based/passwordless authentication during:

    - login
    - sudo
    - ssh
    - git commit signing
    - LUKS2 decryption

- Automated borg backups
- NixOS and Home-Manager automation recipes


## Requirements

- When using NixOS, v23.11 or later is required to properly receive passphrase prompts when building in the private nix-secrets repo
- Patience
- Attention to detail
- Persistence
- More disk space

This is a tweaked version of the repo provided by [EmergentMind](https://github.com/EmergentMind/nix-config/). Generally you should
check out his repos and other resources if you want to build your own rather than trying to copy my copy of his copy.

## Structure Quick Reference

For details about design concepts, constraints, and how structural elements interact, see the article and/or Youtube video [Anatomy of a NixOS Config](https://unmovedcentre.com/posts/anatomy-of-a-nixos-config/).

- `flake.nix` - Entrypoint for hosts and user home configurations. Also exposes a devshell for  manual bootstrapping tasks (`nix develop` or `nix-shell`).
- `hosts` - NixOS configurations accessible via `task rebuild:<host>`.
  - `common` - Shared configurations consumed by the machine specific ones.
    - `core` - Configurations present across all hosts. This is a hard rule! If something isn't core, it is optional.
    - `disks` - Declarative disk partition and format specifications via disko.
    - `optional` - Optional configurations present across more than one host.
    - `users` - Host level user configurations present across at least one host.
        - `<user>/keys` - Public keys for the user that are symlinked to ~/.ssh
  - `nixos` - machine specific configurations for NixOS-based hosts
      - `iso` - Custom NixOS ISO that incorporates some quality of life configuration for use during installations and recovery
- `home/<user>` - Home-manager configurations, built automatically during host rebuilds.
  - `common` - Shared home-manager configurations consumed the user's machine specific ones.
    - `core` - Home-manager configurations present for user across all machines. This is a hard rule! If something isn't core, it is optional.
    - `optional` - Optional home-manager configurations that can be added for specific machines. These can be added by category (e.g. options/media) or individually (e.g. options/media/vlc.nix) as needed.
      The home-manager core and options are defined in host-specific .nix files housed in `home/<user>`.
- `lib` - Custom library used throughout the nix-config to make import paths more readable. Accessible via `customLib`.
- `nixos-installer` - A stripped down version of the main nix-config flake used exclusively during installation of NixOS and nix-config on hosts.
- `scripts` - Custom scripts for automation, including remote installation and bootstrapping of NixOS and nix-config.

## Secrets Management

Secrets for this config are stored in a private repository called `nix-secrets` that is pulled in as a flake input and managed using the sops-nix tool.

For details on how this is accomplished, how to approach different scenarios, and troubleshooting for some common hurdles, please see EmergentMind's article and accompanying YouTube video [NixOS Secrets Management](https://unmovedcentre.com/posts/secrets-management/). There is also a [nix-secrets-reference](https://github.com/EmergentMind/nix-secrets-reference) repository that can be used in conjunction with the article.

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
- [Impermanence](https://github.com/nix-community/impermanence)
- Yubikey
  - <https://wiki.nixos.org/wiki/Yubikey>
  - [DrDuh YubiKey-Guide](https://github.com/drduh/YubiKey-Guide)

