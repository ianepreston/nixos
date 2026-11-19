# Claude Code, from nixpkgs-unstable as on the workstations (vibes.nix).
# Unfree: guest-pkgs.nix allows exactly this package.
{ pkgsUnstable, ... }:
{
  description = "Claude Code client only; no login, API key, or permission bypass";
  commands = [ "claude" ];
  # Unfree, so never in cache.nixos.org: the guest fetches the release.
  fetchDomains = [ "downloads.claude.ai" ];
  packages = [ pkgsUnstable.claude-code ];
}
