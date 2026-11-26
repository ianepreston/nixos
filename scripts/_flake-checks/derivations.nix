# flake-checks:derivations
# Derivation identity check for one flake output (#1021), passed by
# scripts/flake-checks.sh as `nix eval --apply "(<this file>) { ... }"` and
# imported by modules/flake/checks-flake-checks.nix for its unit tests.
#
# Restores what `nix flake check` asserted per derivation: the value has
# `type = "derivation"`, its drvPath is a real store derivation path (a string
# under the store dir, ending in .drv, carrying derivation context, so a
# literal `drvPath = "bogus"` fails), and its `system` equals the per-system
# key it is published under (null skips that, for configuration toplevels).
# Returns { <name> = <drvPath>; }; every failure is a `throw` naming the
# attribute, so the caller sees a nonzero nix exit and the message.
{
  # per-system key the derivations must be built for, or null
  system,
  # true: the value is one derivation (formatter.<system>, a toplevel);
  # false: an attribute set of derivations (checks.<system>, ...)
  single,
  # attribute path shown in messages
  label,
}:
value:
let
  storePrefix = builtins.storeDir + "/";
  fail = name: msg: throw "flake-checks: ${label}${name}: ${msg}";
  isStoreDrvPath =
    p:
    builtins.isString p
    && builtins.substring 0 (builtins.stringLength storePrefix) p == storePrefix
    && builtins.match ".*\\.drv" p != null
    && builtins.hasContext p;
  check =
    name: d:
    if !(builtins.isAttrs d) || (d.type or null) != "derivation" then
      fail name "is not a derivation"
    else if system != null && (d.system or null) != system then
      fail name "is built for ${builtins.toJSON (d.system or null)}, but published under ${system}"
    else if !(isStoreDrvPath (d.drvPath or null)) then
      fail name "drvPath is not a store derivation path"
    else
      d.drvPath;
in
if single then
  { "" = check "" value; }
else if !(builtins.isAttrs value) || (value.type or null) == "derivation" then
  fail "" "must be an attribute set of derivations"
else
  builtins.mapAttrs (name: check ".${name}") value
