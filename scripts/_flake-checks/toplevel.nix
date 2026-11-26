# flake-checks:toplevel
# Shape checks over a flake's whole `outputs` attrset (#1021), passed by
# scripts/flake-checks.sh as the function of
# `nix eval --expr "(<this file>) (builtins.getFlake <locked path>).outputs"`
# and imported by modules/flake/checks-flake-checks.nix for its unit tests.
#
# Restores the structural parts of `nix flake check` that the per-output
# derivation check (derivations.nix) does not cover:
#   - every top-level output is forced (to weak head normal form), so an
#     output that throws fails even when nothing else reads it;
#   - per-system outputs (checks, packages, devShells, formatter, apps,
#     legacyPackages) are keyed by valid "<cpu>-<os>" system names, and by
#     systems `checks` also declares (legacyPackages included, which is how
#     the coding-sandbox outputs are published);
#   - each overlay is a two-argument function `final: prev: ...` (Nix cannot
#     see argument names, so `self: super:` passes as upstream did not care);
#   - each nixosModules entry is a function, attribute set or path;
#   - each apps.<system>.<name> has type "app" and a program.
# Returns the sorted output names; every failure is a `throw`.
outputs:
let
  fail = msg: throw "flake-checks: ${msg}";
  names = builtins.attrNames outputs;
  forced = map (n: builtins.seq outputs.${n} n) names;

  validSystem = s: builtins.match "[a-z0-9_]+-[a-z0-9_]+" s != null;
  declaredSystems = builtins.attrNames (outputs.checks or { });
  perSystemOutputs = [
    "checks"
    "packages"
    "devShells"
    "formatter"
    "apps"
    "legacyPackages"
  ];
  checkSystems =
    output:
    let
      value = outputs.${output};
    in
    if !(builtins.isAttrs value) then
      fail "${output} must be an attribute set keyed by system"
    else
      map (
        s:
        if !(validSystem s) then
          fail "${output}: ${builtins.toJSON s} is not a valid system name"
        else if output != "checks" && !(builtins.elem s declaredSystems) then
          fail "${output}.${s}: system is not declared by checks (${builtins.toJSON declaredSystems})"
        else
          s
      ) (builtins.attrNames value);
  systems = builtins.concatMap checkSystems (
    builtins.filter (o: builtins.hasAttr o outputs) perSystemOutputs
  );

  checkOverlay =
    name: o:
    let
      inner = o { };
    in
    if !(builtins.isFunction o) || builtins.functionArgs o != { } then
      fail "overlays.${name} must be a function `final: prev: ...`"
    else if !(builtins.isFunction inner) || builtins.functionArgs inner != { } then
      fail "overlays.${name} must take a second argument `prev`"
    else
      name;
  overlays = builtins.attrValues (builtins.mapAttrs checkOverlay (outputs.overlays or { }));

  checkModule =
    name: m:
    if builtins.isFunction m || builtins.isAttrs m || builtins.isPath m then
      name
    else
      fail "nixosModules.${name} must be a function, attribute set or path";
  modules = builtins.attrValues (builtins.mapAttrs checkModule (outputs.nixosModules or { }));

  checkApp =
    label: a:
    if !(builtins.isAttrs a) || (a.type or null) != "app" then
      fail "${label} must be an attribute set with type = \"app\""
    else if !(builtins.isString (a.program or null) || builtins.isPath (a.program or null)) then
      fail "${label} must have a program"
    else
      label;
  apps = builtins.concatLists (
    builtins.attrValues (
      builtins.mapAttrs (
        s: byName: builtins.attrValues (builtins.mapAttrs (n: checkApp "apps.${s}.${n}") byName)
      ) (outputs.apps or { })
    )
  );
in
builtins.deepSeq [
  forced
  systems
  overlays
  modules
  apps
] names
