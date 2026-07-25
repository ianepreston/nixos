# Mesh Tools - HM Simple Aspect
# CLI tooling for preparing 3D-print meshes. Currently ships one command:
#
#   fix-mesh <file.stl> [more files ...]
#
# which makes STL/OBJ/PLY models 2-manifold / watertight for slicing by
# driving a headless Blender repair pass (see fix-mesh.py for the pipeline).
# For each INPUT it writes INPUT_fixed.stl next to the original, leaves the
# original untouched, verifies the result by counting non-manifold edges
# before/after, and exits non-zero if any file could not be fully repaired.
#
# Blender is baked in as a runtime input, so this pulls a large closure — it
# is scoped to hosts that actually do 3D printing (see terra.nix), not the
# shared workstation profile.
_: {
  flake.modules.homeManager.mesh-tools =
    { pkgs, ... }:
    let
      fix-mesh = pkgs.writeShellApplication {
        name = "fix-mesh";
        runtimeInputs = [ pkgs.blender ];
        # writeShellApplication prepends the shebang and `set -euo pipefail`,
        # and runs shellcheck at build time.
        text = ''
          merge_dist="''${MERGE_DIST:-0.0001}"
          min_shell_faces="''${MIN_SHELL_FACES:-20}"

          if [ "$#" -eq 0 ]; then
            echo "usage: fix-mesh <file> [more files ...]" >&2
            echo "  writes INPUT_fixed.stl next to each input (STL/OBJ/PLY)." >&2
            echo "  env: MERGE_DIST (default 0.0001), MIN_SHELL_FACES (default 20)" >&2
            exit 2
          fi

          errlog="$(mktemp)"
          trap 'rm -f "$errlog"' EXIT

          status=0
          echo
          printf '%-40s %14s %8s   %s\n' "FILE" "NON-MANIF IN" "OUT" "RESULT"
          printf '%s\n' "--------------------------------------------------------------------------------"

          for f in "$@"; do
            if [ ! -f "$f" ]; then
              printf '%-40s %14s %8s   %s\n' "$(basename "$f")" "-" "-" "SKIP (not a file)"
              status=1
              continue
            fi

            out="''${f%.*}_fixed.stl"

            if line="$(blender --background --factory-startup \
                         --python ${./fix-mesh.py} -- \
                         "$f" "$out" "$merge_dist" "$min_shell_faces" \
                         2>"$errlog" | grep '^FIXMESH_RESULT')"; then
              # FIXMESH_RESULT <before> <after> <outpath>
              read -r _ before after _ <<<"$line"
              if [ "$after" = "0" ]; then
                verdict="OK -> $(basename "$out")"
              else
                verdict="STILL $after NON-MANIFOLD"
                status=1
              fi
              printf '%-40s %14s %8s   %s\n' \
                "$(basename "$f")" "$before" "$after" "$verdict"
            else
              printf '%-40s %14s %8s   %s\n' \
                "$(basename "$f")" "?" "?" "ERROR (see below)"
              sed 's/^/    /' "$errlog" >&2
              status=1
            fi
          done
          echo

          exit "$status"
        '';
      };
    in
    {
      home.packages = [ fix-mesh ];
    };
}
