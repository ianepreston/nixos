# Pure audit of native systemd `StateDirectory=` coverage (#1024).
#
# Consumed by modules/system/app-state.nix, which owns the
# `myAppStateAudit` contract and turns the result into assertions and
# warnings. Kept free of the module system so the path rules below can be
# read on their own.
#
# Inputs:
#   services      config.systemd.services (only enabled units are audited)
#   preservedDirs absolute directories preservation bind-mounts
#   exemptions    attrValues of config.myAppStateAudit.exemptions
#
# Output: { audited; uncovered; exempted; stale; }, each a list of
# { unit; directory; } (exempted and stale also carry the exemption).
{ lib }:
let
  # systemd's boolean spellings; NixOS renders `true` but a hand-written
  # unit or override may use any of them.
  isTrue =
    v:
    v == true
    || lib.elem v [
      "yes"
      "true"
      "on"
      "1"
    ];

  # `StateDirectory=` is a list or a whitespace-separated string of paths
  # relative to /var/lib. An entry may carry a `:<symlink>` suffix (the
  # symlink is not storage) and redundant `.`/empty components.
  entries =
    v:
    let
      raw = if lib.isList v then lib.concatMap entries v else lib.splitString " " (toString v);
    in
    lib.filter (e: e != "") (map (e: lib.head (lib.splitString ":" e)) raw);

  normalize =
    rel:
    let
      parts = lib.filter (p: p != "" && p != ".") (lib.splitString "/" rel);
    in
    lib.concatStringsSep "/" parts;

  # DynamicUser keeps the real directory under /var/lib/private and
  # leaves only a symlink at /var/lib/<name>; preserving the symlink path
  # preserves nothing.
  stateRoot = dynamic: if dynamic then "/var/lib/private" else "/var/lib";

  # Covered by an exact match or by an ancestor on a path-component
  # boundary: /var/lib/foo covers /var/lib/foo/bar, never /var/lib/foobar.
  covers =
    preserved: dir:
    let
      p = lib.removeSuffix "/" preserved;
    in
    dir == p || lib.hasPrefix "${p}/" dir;
in
{
  inherit normalize;

  audit =
    {
      services,
      preservedDirs,
      exemptions,
    }:
    let
      audited = lib.concatLists (
        lib.mapAttrsToList (
          name: svc:
          let
            sc = svc.serviceConfig or { };
            root = stateRoot (isTrue (sc.DynamicUser or false));
          in
          lib.optionals ((svc.enable or true) && sc ? StateDirectory) (
            map (rel: {
              unit = "${name}.service";
              directory = "${root}/${normalize rel}";
            }) (lib.filter (rel: normalize rel != "") (entries sc.StateDirectory))
          )
        ) services
      );

      isCovered = d: lib.any (p: covers p d.directory) preservedDirs;

      exemptionFor =
        d: lib.findFirst (e: e.unit == d.unit && lib.elem d.directory e.directories) null exemptions;

      notCovered = lib.filter (d: !isCovered d) audited;
    in
    {
      inherit audited;
      uncovered = lib.filter (d: exemptionFor d == null) notCovered;
      exempted = lib.concatMap (
        d:
        let
          e = exemptionFor d;
        in
        lib.optional (e != null) (d // { exemption = e; })
      ) notCovered;
      # An exemption naming a pair that is not audited (renamed unit,
      # changed directory) or that preservation already covers is stale.
      stale = lib.concatMap (
        e:
        map
          (directory: {
            inherit (e) unit;
            inherit directory;
            exemption = e;
          })
          (
            lib.filter (
              directory: !(lib.any (d: d.unit == e.unit && d.directory == directory) notCovered)
            ) e.directories
          )
      ) exemptions;
    };
}
