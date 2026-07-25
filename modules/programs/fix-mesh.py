# Headless Blender mesh-repair pipeline used by the `fix-mesh` tool
# (see mesh-tools.nix). Makes an STL/OBJ/PLY 2-manifold / watertight for
# slicing. Run as:
#
#   blender --background --factory-startup --python fix-mesh.py \
#           -- <input> <output.stl> <merge_dist> <min_shell_faces>
#
# On success it prints one machine-readable line to stdout:
#
#   FIXMESH_RESULT <nonmanifold_before> <nonmanifold_after> <output_path>
#
# The repair proceeds in two stages. An operator pass welds coincident
# vertices, strips loose/degenerate geometry, deletes interior walls and
# fills boundary holes. A bmesh pass then removes tiny disconnected junk
# shells and splits apart the >2-face "pinch" edges that the operator pass
# cannot resolve, after which the exposed holes are re-filled.
import bpy
import bmesh
import sys
import os

argv = sys.argv[sys.argv.index("--") + 1:]
inp, outp = argv[0], argv[1]
merge_dist = float(argv[2])
min_shell_faces = int(argv[3])


def nm_count(obj):
    """Count non-manifold edges (edges not bordered by exactly two faces)."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    n = sum(1 for e in bm.edges if len(e.link_faces) != 2)
    bm.free()
    return n


def do_import(path):
    ext = os.path.splitext(path)[1].lower()
    if ext == ".stl":
        (bpy.ops.wm.stl_import if hasattr(bpy.ops.wm, "stl_import")
         else bpy.ops.import_mesh.stl)(filepath=path)
    elif ext == ".obj":
        (bpy.ops.wm.obj_import if hasattr(bpy.ops.wm, "obj_import")
         else bpy.ops.import_scene.obj)(filepath=path)
    elif ext == ".ply":
        (bpy.ops.wm.ply_import if hasattr(bpy.ops.wm, "ply_import")
         else bpy.ops.import_mesh.ply)(filepath=path)
    else:
        raise SystemExit(f"unsupported input extension: {ext}")


def do_export_stl(path):
    if hasattr(bpy.ops.wm, "stl_export"):        # Blender >= 4.0
        bpy.ops.wm.stl_export(filepath=path, export_selected_objects=False,
                              ascii_format=False)
    else:                                        # Blender 3.x
        bpy.ops.export_mesh.stl(filepath=path, ascii=False)


bpy.ops.wm.read_factory_settings(use_empty=True)
do_import(inp)

# Join everything into one object so repairs cross object boundaries.
meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
if not meshes:
    raise SystemExit("no mesh found in input")
for o in bpy.context.scene.objects:
    o.select_set(o in meshes)
bpy.context.view_layer.objects.active = meshes[0]
if len(meshes) > 1:
    bpy.ops.object.join()
obj = bpy.context.view_layer.objects.active

before = nm_count(obj)
me = bpy.ops.mesh

# --- operator pass -------------------------------------------------------
bpy.ops.object.mode_set(mode="EDIT")
me.select_all(action="SELECT")
me.remove_doubles(threshold=merge_dist)     # weld coincident verts
me.delete_loose()                           # strip stray verts/edges
me.dissolve_degenerate()                    # kill zero-area/length geometry
me.select_all(action="DESELECT")
me.select_interior_faces()                  # internal walls -> >2-face edges
me.delete(type="FACE")
for _ in range(3):
    me.select_all(action="DESELECT")
    me.select_non_manifold()
    me.fill_holes(sides=0)                   # 0 = all hole sizes
bpy.ops.object.mode_set(mode="OBJECT")

# --- bmesh pass: junk shells + pinch edges -------------------------------
bm = bmesh.new()
bm.from_mesh(obj.data)
bm.faces.ensure_lookup_table()
bm.edges.ensure_lookup_table()

# Delete tiny disconnected shells, always keeping the largest shell. Flood
# fill across shared edges to group faces into connected components.
seen = set()
groups = []
for f in bm.faces:
    if f.index in seen:
        continue
    stack = [f]
    comp = []
    while stack:
        g = stack.pop()
        if g.index in seen:
            continue
        seen.add(g.index)
        comp.append(g)
        for e in g.edges:
            for nf in e.link_faces:
                if nf.index not in seen:
                    stack.append(nf)
    groups.append(comp)
groups.sort(key=len)
small = [c for c in groups[:-1] if len(c) < min_shell_faces]
delf = [f for c in small for f in c]
if delf:
    bmesh.ops.delete(bm, geom=delf, context="FACES")

# Split remaining >2-face pinch edges into clean boundary edges.
bm.edges.ensure_lookup_table()
pinch = [e for e in bm.edges if len(e.link_faces) > 2]
if pinch:
    bmesh.ops.split_edges(bm, edges=pinch)

bm.to_mesh(obj.data)
bm.free()

# --- refill + normals ----------------------------------------------------
bpy.ops.object.mode_set(mode="EDIT")
for _ in range(3):
    me.select_all(action="DESELECT")
    me.select_non_manifold()
    me.fill_holes(sides=0)
me.select_all(action="SELECT")
me.normals_make_consistent(inside=False)
bpy.ops.object.mode_set(mode="OBJECT")

after = nm_count(obj)
do_export_stl(outp)
print(f"FIXMESH_RESULT {before} {after} {outp}")
