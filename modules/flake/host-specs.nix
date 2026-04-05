# Host specification evaluation
# Evaluates hostSpecs from the hostSpecs/ directory and passes them to other modules
{ inputs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  customLib = import ../../lib { inherit lib; };

  evaluatedHostSpecs = lib.evalModules {
    specialArgs = {
      inherit inputs lib customLib;
    };
    modules = [ ../../hostSpecs ];
  };
in
{
  # Pass to other flake-parts modules via _module.args (not exposed as flake outputs)
  _module.args.hostSpecs = evaluatedHostSpecs.config.hostSpecs;
  _module.args.customLib = customLib;
}
