# Databricks CLI. nixpkgs-unstable: stable trails upstream by several major
# releases.
{ pkgsUnstable, ... }:
{
  description = "Databricks CLI; no profile, workspace, or token";
  commands = [ "databricks" ];
  # Unfree, so never in cache.nixos.org: the guest builds it, and its Go
  # module tree comes from the Go proxy, which redirects downloads to GCS.
  fetchDomains = [
    "proxy.golang.org"
    "storage.googleapis.com"
  ];
  packages = [ pkgsUnstable.databricks-cli ];
}
