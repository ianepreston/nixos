# uv, the Python tool and project manager. The launcher already puts
# ~/.local/bin on the agent's PATH for `uv tool install` entrypoints.
{ pkgsUnstable, ... }:
{
  description = "uv Python tool manager; no project environment or dependencies";
  commands = [
    "uv"
    "uvx"
  ];
  # Substituted from cache.nixos.org, or built from GitHub sources.
  fetchDomains = [ ];
  packages = [ pkgsUnstable.uv ];
}
