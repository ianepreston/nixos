# OpenCode, from stable nixpkgs. The workstations take nixpkgs-unstable's
# (vibes.nix), but Hydra does not cache that build and its bun/vite source
# build exhausts a default 4 GiB guest. Move to pkgsUnstable once
# cache.nixos.org serves it.
{ pkgs, ... }:
{
  description = "OpenCode client only; no provider, model, or credential";
  commands = [ "opencode" ];
  # Substituted from cache.nixos.org, or built from GitHub sources.
  fetchDomains = [ ];
  packages = [ pkgs.opencode ];
}
