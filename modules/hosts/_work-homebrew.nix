# Work-specific Homebrew packages — Databricks tooling
_: {
  homebrew = {
    taps = [
      "hashicorp/tap"
      "databricks/tap"
    ];
    brews = [
      "awscli"
      "azure-cli"
      "sf"
      "databricks/tap/databricks"
      "hashicorp/tap/terraform"
    ];
    casks = [
      "gcloud-cli"
    ];
  };
}
