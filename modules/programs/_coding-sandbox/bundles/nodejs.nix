# Node.js runtime and npm. The stable release line is the conservative
# choice for a runtime other tools build on.
{ pkgs, ... }:
{
  description = "Node.js runtime and npm; no globally installed npm tools";
  commands = [
    "node"
    "npm"
    "npx"
  ];
  # Substituted from cache.nixos.org, or built from GitHub sources.
  fetchDomains = [ ];
  packages = [ pkgs.nodejs ];
}
