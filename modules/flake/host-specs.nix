# Host specification evaluation
# Evaluates hostSpecs from the hostSpecs/ directory and passes them to other modules
{ inputs, ... }:
let
  inherit (inputs.nixpkgs) lib;

  evaluatedHostSpecs = lib.evalModules {
    specialArgs = {
      inherit inputs lib;
    };
    modules = [ ../../hostSpecs ];
  };
in
{
  _module.args.hostSpecs = evaluatedHostSpecs.config.hostSpecs;
}
