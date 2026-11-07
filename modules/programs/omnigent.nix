# Omnigent desktop + host tools - HM Simple Aspect
# Electron client for an Omnigent server, from the omnigent-nix flake, plus the
# flake's host module. Importing this aspect installs the desktop only:
# `programs.omnigent.host` stays at the upstream defaults (off, no daemon). A
# machine becomes a host only where its host file sets `programs.omnigent.host`
# explicitly (terra; see modules/hosts/terra.nix). A host runs agent work with
# that user's files, network and credentials, and an Omnigent server must never
# be one; modules/apps/omnigent.nix asserts that. Linux only (the flake builds
# no macOS desktop bundle).
{ inputs, ... }:
{
  flake.modules.homeManager.omnigent = {
    imports = [ inputs.omnigent.homeManagerModules.omnigent ];

    programs.omnigent.desktop.enable = true;
  };
}
