# Defines the flake.modules.* option types for module registration
# This is a prerequisite for the dendritic pattern - modules register themselves
# under these namespaces and can then be referenced as inputs.self.modules.nixos.*
{ lib, ... }:
{
  options.flake.modules = {
    nixos = lib.mkOption {
      type = lib.types.attrsOf lib.types.deferredModule;
      default = { };
      description = "NixOS modules, accessible as inputs.self.modules.nixos.*";
    };
    darwin = lib.mkOption {
      type = lib.types.attrsOf lib.types.deferredModule;
      default = { };
      description = "Darwin modules, accessible as inputs.self.modules.darwin.*";
    };
    homeManager = lib.mkOption {
      type = lib.types.attrsOf lib.types.deferredModule;
      default = { };
      description = "Home-manager modules, accessible as inputs.self.modules.homeManager.*";
    };
    generic = lib.mkOption {
      type = lib.types.attrsOf lib.types.deferredModule;
      default = { };
      description = "Generic modules usable across platforms";
    };
  };
}
