# Databricks Unity Gateway (`ug`), packaged from a fixed release tag.
#
# Not in nixpkgs. Its Python dependency floors (databricks-sdk, mcp, typer)
# are met only by nixpkgs-unstable. Upstream derives the version from Git
# tags with uv-dynamic-versioning, which a source tarball cannot provide, so
# the build substitutes the pinned version instead.
{ pkgsUnstable, lib, ... }:
let
  python = pkgsUnstable.python3Packages;
  unity-gateway = python.buildPythonApplication rec {
    pname = "unity-gateway";
    # renovate: datasource=github-releases depName=databricks/unity-gateway
    version = "0.2.1";
    src = pkgsUnstable.fetchFromGitHub {
      owner = "databricks";
      repo = "unity-gateway";
      tag = "v0.2.1";
      hash = "sha256-wGlATpVeOzgHmWLRD7bMQZCnvxk2bBUYfkrT/QB8L2c=";
    };
    pyproject = true;

    postPatch = ''
      substituteInPlace pyproject.toml \
        --replace-fail 'dynamic = ["version"]' 'version = "${version}"' \
        --replace-fail ', "uv-dynamic-versioning>=0.7.0"' ""
      sed -i '/^\[tool\.hatch\.version\]/,/^source = /d' pyproject.toml
    '';

    build-system = [ python.hatchling ];
    dependencies = with python; [
      databricks-sdk
      httpx
      mcp
      questionary
      tomlkit
      typer
      websockets
    ];
    pythonImportsCheck = [ "ucode" ];

    meta = {
      description = "Bootstrap coding agents against a Databricks workspace";
      homepage = "https://github.com/databricks/unity-gateway";
      license = lib.licenses.unfree;
      mainProgram = "ug";
    };
  };
in
{
  description = "Databricks Unity Gateway CLI; no workspace, OAuth state, or token";
  commands = [
    "ug"
    "ucode"
  ];
  # Substituted from cache.nixos.org, or built from GitHub sources.
  fetchDomains = [ ];
  packages = [ unity-gateway ];
}
