# Pi coding agent, from nixpkgs-unstable as on the workstations (vibes.nix).
{ pkgsUnstable, ... }:
{
  description = "Pi coding-agent client only; no provider, model, or credential";
  commands = [ "pi" ];
  # Substituted from cache.nixos.org, or built from GitHub sources.
  fetchDomains = [ ];
  packages = [ pkgsUnstable.pi-coding-agent ];
}
