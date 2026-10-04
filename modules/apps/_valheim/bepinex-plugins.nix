# Pinned BepInEx plugin packages for `myValheim.bepinexPlugins`, published
# read-only as `myValheim.availablePlugins` (#772).
#
# Every package here has the one layout the materializer
# (bepinex-materialize.sh) understands:
#
#   $out/BepInEx/plugins/<dir>/…    plugin DLLs and their dependent DLLs
#   $out/BepInEx/patchers/<dir>/…   preloader patchers, only when needed
#   $out/BepInEx/config/<guid>.cfg  only when `settings` is nonempty
#
# `settings` is { "<section>" = { "<key>" = value; }; } and renders to the
# plugin's own BepInEx config file. Only the declared keys are written: on
# load BepInEx binds every other key at its default and saves the file back,
# so the declaration stays the reviewable diff against upstream defaults.
# Override per host with `.override { settings = …; }`.
#
# Sources are fixed versions with fixed hashes — never "latest" at container
# start. Renovate does not track these; bump `version` by hand and run
# `task hashes`, which rebuilds each `src` named by its `regen-hash` marker.
# Record the result in the plugin table in README.md.
{ lib, pkgs }:
let
  mkPlugin = lib.makeOverridable (
    {
      pname,
      version,
      src,
      # BepInPlugin GUID — names the config file BepInEx reads.
      guid,
      # Directory under BepInEx/plugins/, matching upstream's install docs.
      dir,
      # Shell that copies the plugin's DLLs into "$plugin" (that directory).
      install,
      settings ? { },
    }:
    pkgs.runCommandLocal "valheim-bepinex-${pname}-${version}"
      {
        passthru = {
          inherit
            src
            guid
            settings
            version
            ;
        };
      }
      (
        ''
          plugin="$out/BepInEx/plugins/${dir}"
          mkdir -p "$plugin"
          ${install}
        ''
        + lib.optionalString (settings != { }) ''
          mkdir -p "$out/BepInEx/config"
          cp ${pkgs.writeText "${guid}.cfg" (lib.generators.toINI { } settings)} \
            "$out/BepInEx/config/${guid}.cfg"
        ''
      )
  );
in
{
  # https://github.com/LabodiDavid/BetterNetworking10 — MIT. The maintained
  # Valheim 1.0 fork of CW-Jesse's Better Networking; the #671 alternative to
  # FiresGhettoNetworking (README "Packaged plugins" says why it lost).
  # A single DLL with no dependency beyond the image's BepInExPack.
  betterNetworking10 = mkPlugin rec {
    pname = "better-networking10";
    version = "1.2.0";
    guid = "DIT.BetterNetworking10";
    dir = "BetterNetworking_Valheim";
    src = pkgs.fetchurl {
      name = "DIT.BetterNetworking10.dll";
      url = "https://github.com/LabodiDavid/BetterNetworking10/releases/download/v${version}/DIT.BetterNetworking10.dll";
      # regen-hash: nixosConfigurations.hpp-1.config.myValheim.availablePlugins.betterNetworking10.src
      hash = "sha256-J2XEowMF84v48KwAz4LgvmF6Zv70jrA7my2fHl5mJ0U=";
    };
    install = ''cp ${src} "$plugin/DIT.BetterNetworking10.dll"'';
  };

  # https://github.com/fire-VA/FiresGhettoNetworking — MIT. Published only on
  # Thunderstore (no GitHub release assets); a versioned Thunderstore download
  # is immutable once published. The optional FiresSteamworksPatcher it
  # mentions unlocks Steam-socket receive buffers only, which a crossplay
  # server never uses, so it is deliberately not packaged.
  firesGhettoNetworking = mkPlugin rec {
    pname = "fires-ghetto-networking";
    version = "1.5.17";
    guid = "com.Fire.FiresGhettoNetworkMod";
    dir = "FiresGhettoNetworking";
    src = pkgs.fetchzip {
      url = "https://thunderstore.io/package/download/VerdantsAscent/FiresGhettoNetworking/${version}/";
      extension = "zip";
      stripRoot = false;
      # regen-hash: nixosConfigurations.hpp-1.config.myValheim.availablePlugins.firesGhettoNetworking.src
      hash = "sha256-J+xtZaardXT25Le6Yw5RzVGHF3RwnN6lJ0NHs3yVQRE=";
    };
    install = ''cp ${src}/VAGhettoNetworking.dll "$plugin/"'';
  };
}
