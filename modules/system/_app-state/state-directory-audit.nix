# Pure audit of native systemd `StateDirectory=` coverage (#1024).
#
# Consumed by modules/system/app-state.nix, which owns the
# `myAppStateAudit` contract and turns the result into assertions and
# warnings. Kept free of the module system so the parsing and path rules
# below can be read on their own.
#
# Inputs:
#   services      config.systemd.services (only enabled units are audited)
#   preservedDirs absolute directories preservation actually preserves
#   exemptions    config.myAppStateAudit.exemptions (owner name -> entry)
#
# Output attrs, each a list:
#   audited / uncovered  { unit; directory; }
#   exempted             { unit; directory; owner; exemption; }
#   stale                { unit; directory; owner; }
#   conflicts            { unit; directory; owners; }
#   invalid              { unit; option; value; why; }
#
# Parsing follows systemd where that is unambiguous and fails closed
# (an `invalid` entry, so an eval failure) where guessing could hide
# state: quoting, `%` specifiers, backslash escapes, embedded newlines,
# absolute or `..` paths, and empty or unparsable booleans.
{ lib }:
let
  # NixOS renders a list-valued unit setting as one assignment per
  # element, so a list is a sequence of assignments; anything else is one.
  assignments = v: if lib.isList v then v else [ v ];

  # systemd's parse_boolean(), which is case-insensitive, applied to the
  # value the unit-file parser hands it (surrounding whitespace stripped).
  parseBool =
    v:
    if lib.isBool v then
      v
    else
      let
        s = lib.toLower (lib.trim (toString v));
      in
      if
        lib.elem s [
          "1"
          "yes"
          "y"
          "true"
          "t"
          "on"
        ]
      then
        true
      else if
        lib.elem s [
          "0"
          "no"
          "n"
          "false"
          "f"
          "off"
        ]
      then
        false
      else
        null;

  isEmptyAssignment = a: !(lib.isBool a) && lib.trim (toString a) == "";

  # DynamicUser=: the last assignment wins. Unlike StateDirectory=, an
  # empty assignment is not a reset here: systemd rejects it as a boolean
  # parse error, like any other unparsable value, and we refuse to guess.
  dynamicUser =
    unit: v:
    lib.foldl'
      (
        acc: a:
        let
          b = parseBool a;
        in
        if b == null then
          acc
          // {
            invalid = acc.invalid ++ [
              {
                inherit unit;
                option = "DynamicUser";
                value = toString a;
                why = if isEmptyAssignment a then "empty assignment is not a boolean" else "not a systemd boolean";
              }
            ];
          }
        else
          acc // { value = b; }
      )
      {
        value = false;
        invalid = [ ];
      }
      (assignments v);

  # Spaces and tabs separate entries within one assignment, as in
  # systemd. A newline is not a separator: NixOS writes it into the unit
  # file verbatim, which ends the assignment and starts an unrelated line,
  # so an assignment containing one is reported instead (`invalidLine`).
  words = s: lib.filter (w: lib.isString w && w != "") (builtins.split "[ \t]+" s);
  hasLineBreak = s: lib.hasInfix "\n" s || lib.hasInfix "\r" s;
  # Shown escaped so a diagnostic stays on one line.
  showValue = lib.replaceStrings [ "\n" "\r" "\t" ] [ "\\n" "\\r" "\\t" ];

  components = rel: lib.filter (p: p != "" && p != ".") (lib.splitString "/" rel);

  # One StateDirectory= entry. A `:<symlink>` suffix names a symlink, not
  # storage, and is dropped.
  parseEntry =
    unit: word:
    let
      path = lib.head (lib.splitString ":" word);
      parts = components path;
      bad = why: {
        invalid = [
          {
            inherit unit why;
            option = "StateDirectory";
            value = word;
          }
        ];
        dirs = [ ];
      };
    in
    if lib.hasInfix "\"" word || lib.hasInfix "'" word then
      bad "quoted entries are not parsed by this audit"
    # systemd expands specifiers (%N, %i, ...) and C escapes before using
    # the name, so the literal text is not the directory on disk.
    else if lib.hasInfix "%" word then
      bad "`%` specifiers are not resolved by this audit"
    else if lib.hasInfix "\\" word then
      bad "backslash escapes are not decoded by this audit"
    else if lib.hasPrefix "/" path then
      bad "systemd rejects absolute paths"
    else if lib.elem ".." parts then
      bad "systemd rejects `..` components"
    else if parts == [ ] then
      bad "empty path"
    else
      {
        invalid = [ ];
        dirs = [ (lib.concatStringsSep "/" parts) ];
      };

  # StateDirectory=: entries accumulate across assignments and an empty
  # assignment clears everything before it.
  stateDirectories =
    unit: v:
    lib.foldl'
      (
        acc: a:
        if isEmptyAssignment a then
          acc // { dirs = [ ]; }
        else if hasLineBreak (toString a) then
          acc
          // {
            invalid = acc.invalid ++ [
              {
                inherit unit;
                option = "StateDirectory";
                value = showValue (toString a);
                why = "a newline splits the unit-file line; use a list";
              }
            ];
          }
        else
          let
            parsed = map (parseEntry unit) (words (toString a));
          in
          {
            dirs = acc.dirs ++ lib.concatMap (p: p.dirs) parsed;
            invalid = acc.invalid ++ lib.concatMap (p: p.invalid) parsed;
          }
      )
      {
        dirs = [ ];
        invalid = [ ];
      }
      (assignments v);

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
  audit =
    {
      services,
      preservedDirs,
      exemptions,
    }:
    let
      perUnit = lib.mapAttrsToList (
        name: svc:
        let
          unit = "${name}.service";
          sc = svc.serviceConfig or { };
          du = dynamicUser unit (sc.DynamicUser or [ ]);
          sd = stateDirectories unit sc.StateDirectory;
        in
        if (svc.enable or true) && sc ? StateDirectory then
          {
            invalid = du.invalid ++ sd.invalid;
            dirs = map (rel: {
              inherit unit;
              directory = "${stateRoot du.value}/${rel}";
            }) (lib.unique sd.dirs);
          }
        else
          {
            invalid = [ ];
            dirs = [ ];
          }
      ) services;

      audited = lib.concatMap (u: u.dirs) perUnit;
      invalid = lib.concatMap (u: u.invalid) perUnit;

      claims = lib.concatLists (
        lib.mapAttrsToList (
          owner: e:
          map (directory: {
            inherit owner directory;
            inherit (e) unit;
            exemption = e;
          }) (lib.unique e.directories)
        ) exemptions
      );
      key = c: "${c.unit} ${c.directory}";
      claimsFor = d: lib.filter (c: key c == key d) claims;

      notCovered = lib.filter (d: !(lib.any (p: covers p d.directory) preservedDirs)) audited;
      isNotCovered = c: lib.any (d: key d == key c) notCovered;
    in
    {
      inherit audited invalid;
      uncovered = lib.filter (d: claimsFor d == [ ]) notCovered;
      exempted = lib.concatMap (
        d:
        map (c: {
          inherit (c) unit directory owner;
          inherit (c) exemption;
        }) (claimsFor d)
      ) notCovered;
      # An exemption naming a pair that is not audited (renamed unit,
      # changed or unnormalized directory) or that preservation already
      # covers is stale.
      stale = map (c: { inherit (c) unit directory owner; }) (lib.filter (c: !(isNotCovered c)) claims);
      # Two owners claiming one directory is a conflict for the contract
      # owner to reject, even when they agree.
      conflicts = lib.concatMap (
        group:
        let
          c = lib.head group;
        in
        lib.optional (lib.length group > 1) {
          inherit (c) unit directory;
          owners = map (g: g.owner) group;
        }
      ) (lib.attrValues (lib.groupBy key claims));
    };
}
