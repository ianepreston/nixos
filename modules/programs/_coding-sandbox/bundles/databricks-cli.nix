# Databricks CLI, from upstream's statically linked release binary.
#
# nixpkgs-unstable's databricks-cli is unfree, so cache.nixos.org never holds
# it and the guest would build it from source. That build downloads its Go
# module tree from proxy.golang.org, which a workstation's network policy can
# block (the work Mac's does, for its guests too). The release tarball is a
# single hash-pinned download from GitHub instead. Stable nixpkgs trails
# upstream by several major releases, so it is no alternative.
{ pkgsUnstable, lib, ... }:
let
  # renovate: datasource=github-releases depName=databricks/cli
  version = "1.27.0";
  release =
    { arch, hash }:
    pkgsUnstable.fetchurl {
      url = "https://github.com/databricks/cli/releases/download/v${version}/databricks_cli_${version}_linux_${arch}.tar.gz";
      inherit hash;
    };
  # One tarball per guest system. A fixed-output path depends only on its
  # name and hash, so CI regenerates both hashes on its x86_64 builder.
  sources = {
    aarch64-linux = release {
      arch = "arm64";
      # regen-hash: legacyPackages.x86_64-linux.coding-sandbox-bundle-sources.databricks-cli.aarch64-linux
      hash = "sha256-4ckkqVgZ18eS9xpBwhbSqtlVAMrtqbhY3uZ2gwd6WgY=";
    };
    x86_64-linux = release {
      arch = "amd64";
      # regen-hash: legacyPackages.x86_64-linux.coding-sandbox-bundle-sources.databricks-cli.x86_64-linux
      hash = "sha256-UiSIhClyoGk2IHpQNCatNk2AYdouMwY22mD0RKMoQPU=";
    };
  };
  databricks-cli = pkgsUnstable.stdenvNoCC.mkDerivation {
    pname = "databricks-cli";
    inherit version;
    src = sources.${pkgsUnstable.stdenv.hostPlatform.system};
    # The tarball has no top-level directory.
    sourceRoot = ".";
    dontConfigure = true;
    dontBuild = true;
    # Ship upstream's bytes: a static Go binary needs no patching or stripping.
    dontStrip = true;
    dontPatchELF = true;
    installPhase = ''
      runHook preInstall
      install -Dm0755 databricks "$out/bin/databricks"
      runHook postInstall
    '';
    meta = {
      description = "Databricks CLI";
      homepage = "https://github.com/databricks/cli";
      license = lib.licenses.unfree;
      mainProgram = "databricks";
      platforms = builtins.attrNames sources;
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    };
  };
in
{
  description = "Databricks CLI; no profile, workspace, or token";
  commands = [ "databricks" ];
  # Unfree, so never in cache.nixos.org: the guest downloads the release,
  # which GitHub redirects to its release-asset host.
  fetchDomains = [
    "github.com"
    "release-assets.githubusercontent.com"
  ];
  packages = [ databricks-cli ];
  inherit sources;
}
