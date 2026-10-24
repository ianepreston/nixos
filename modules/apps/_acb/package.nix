{ pkgs }:
let
  # renovate: datasource=github-tags depName=tsiemens/acb
  version = "0.26.04.2";

  src = pkgs.fetchFromGitHub {
    owner = "tsiemens";
    repo = "acb";
    # Newest tag (rather than the older GitHub "latest" release): it has the
    # same web build and fixes shipped after v0.26.04.
    rev = "v0.26.04.2";
    hash = "sha256-Ijj4NIY76iUUznkk/rOzjhKQphBx2DuRi3mv9iEPTaI=";
  };

  acbWasm = pkgs.rustPlatform.buildRustPackage {
    pname = "acb-wasm";
    inherit version src;
    # regen-hash: packages.x86_64-linux.acb-wasm
    cargoHash = "sha256-b8RyeL71A0mMdiSKBSHcHlECp6LV6BYofbbv+ZlGHCY=";
    cargoBuildFlags = [
      "--package"
      "acb_wasm"
      "--target"
      "wasm32-unknown-unknown"
    ];
    # Cargo.lock resolves wasm-bindgen to 0.2.100. The CLI validates this
    # version exactly, so use the matching nixpkgs package rather than the
    # older Cargo.toml lower bound (0.2.92).
    nativeBuildInputs = [
      pkgs.llvmPackages.lld
      pkgs.wasm-bindgen-cli_0_2_100
    ];
    doCheck = false;
    # buildRustPackage always adds its host `--target`; Cargo takes the first
    # target flag, so override the hook for this intentionally wasm-only
    # package rather than accidentally building the native crate.
    buildPhase = ''
      runHook preBuild
      cargo build --offline --profile release --package acb_wasm --target wasm32-unknown-unknown
      runHook postBuild
    '';
    installPhase = ''
      wasm-bindgen \
        --target web \
        --out-dir "$out" \
        target/wasm32-unknown-unknown/release/acb_wasm.wasm
    '';
  };

  # www/package-lock.json resolves this Git dependency to preview-0.1.2. Npm
  # caches the source but deliberately skips its prepare script, leaving the
  # published dist/ absent; build and provide that exact dependency ourselves.
  canadaAcb = pkgs.buildNpmPackage {
    pname = "canada-acb";
    version = "0.1.2";
    src = pkgs.fetchFromGitHub {
      owner = "tsiemens";
      repo = "canada-acb-js";
      rev = "preview-0.1.2";
      hash = "sha256-9BfpgEfA8cWPTvEgv5ve6cW/mnAVpHvRVkAI9e3RJnw=";
    };
    # regen-hash: packages.x86_64-linux.acb-canada-acb
    npmDepsHash = "sha256-Xa8JCBSYijPOfpcGs7fODR/zj+9eY3V1V4ktqzHqOvw=";
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -r dist package.json "$out"
      runHook postInstall
    '';
  };

  # buildNpmPackage's default fetcher starts at the source root, while this
  # upstream project keeps its lockfile in www/. Point the fixed-output
  # dependency fetch at that directory explicitly.
  npmDeps = pkgs.fetchNpmDeps {
    name = "acb-web-npm-deps";
    inherit src;
    sourceRoot = "source/www";
    # regen-hash: packages.x86_64-linux.acb-web
    hash = "sha256-9ZzAHYm9ufCYWDzN6YfqdnT1PtzdZdDz+KjmoEXtzQU=";
  };
in
{
  acb-canada-acb = canadaAcb;
  acb-wasm = acbWasm;
  acb-web = pkgs.buildNpmPackage {
    pname = "acb-web";
    inherit version src;
    npmRoot = "www";
    inherit npmDeps;
    # npm's Git dependency prepares a nested package during `npm ci`, which
    # writes temporary cache entries after the fixed-output cache is copied.
    makeCacheWritable = true;
    nativeBuildInputs = [
      acbWasm
      canadaAcb
    ];
    buildPhase = ''
      runHook preBuild
      cd www
      ln -s ${acbWasm} src/pkg
      rm -rf node_modules/canada-acb
      cp -r ${canadaAcb} node_modules/canada-acb
      npm run dist-static-links-and-debug
      npm run build
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      cp -rL dist "$out"
      runHook postInstall
    '';
  };
}
