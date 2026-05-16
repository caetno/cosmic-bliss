class_name FleshData
extends Resource

## Holds parsed data from a Version-3 .bin file produced by the Blender addon.
## Coordinates are already in Godot Y-up world space — no axis conversion needed.
##
## Format (little-endian):
##   [Magic 'FLSH' u8×4] [version u32 = 3]
##   [name_len u32] [mesh_name utf8]
##   [n_tet_verts u32 Nv] [n_tet_cells u32 Nt] [n_render_verts u32 Nr]
##   [tet_verts         f32 Nv×3]   — rest-pose positions (Godot space)
##   [tet_cells         i32 Nt×4]   — 4 vertex indices per tet
##   [bary_tet_idx      i32 Nr]     — which tet contains each render vert
##   [bary_uvw          f32 Nr×3]   — (u, v, w) barycentric coords
##   [render_influence  f32 Nr]     — reserved; consumer is v1.5+ surface_transfer.glsl
##   [tet_skin_indices  i32 4×Nv]   — 4 bone indices per tet vert, padded
##   [tet_skin_weights  f32 4×Nv]   — 4 normalized weights per tet vert (sum ≈ 1.0)
##
## Per-vert layout for skin arrays: slot `s` of vert `i` lives at index `i*4 + s`.
## Padded slots use bone index 0 with weight 0.0.
##
## Version 2 files are rejected at load and must be re-baked (B4 authoring).
## B4 may add per-face region material via a future format bump (likely v4 or
## a v3 trailer); the v3 reader does NOT read those fields.
##
## See `docs/Cosmic_Bliss_Update_2026-05-14_body_field_optionality_and_dispatch.md` §6.

var mesh_name:        String
var n_tet_verts:      int
var n_tet_cells:      int
var n_render_verts:   int

var tet_verts:         PackedFloat32Array   # Nv × 3
var tet_cells:         PackedInt32Array     # Nt × 4
var bary_tet_idx:      PackedInt32Array     # Nr
var bary_uvw:          PackedFloat32Array   # Nr × 3
var render_influence:  PackedFloat32Array   # Nr  (reserved; consumed by v1.5+ surface_transfer)
var tet_skin_indices:  PackedInt32Array     # 4 × Nv (bone indices, padded slots use 0)
var tet_skin_weights:  PackedFloat32Array   # 4 × Nv (normalized; per-vert sum ≈ 1.0)

# --- Derived at load() time, not in the .bin -----------------------------
# Outer faces: triples (i0, i1, i2) where the face appears in exactly one
# tet. Outward-oriented (face normal points away from the opposing
# fourth tet vertex). Length = 3 × n_outer_faces.
# Consumer: B3's AnimatableBody3D shape population (ConcavePolygonShape3D
# wants a flat Vector3 buffer per `set_faces`).
var outer_faces:       PackedInt32Array     = PackedInt32Array()
var n_outer_faces:     int                  = 0

# --- Optional v3 trailer (per 05-14 §6, scheme finalized at B3) ----------
# Not yet emitted by the v3 reader above — B4 authoring chain will extend
# the format. BodyField accessors tolerate empty arrays and return
# defaults; that's the per-region material fallback.
#
# Schema (B3 freeze; see PHASE_LOG):
#   tet_face_region_id    : length n_outer_faces, 0 = "no tag → default"
#   region_material_table : length 3 × n_regions, packed [μ, comp, stiff]
var tet_face_region_id:    PackedInt32Array   = PackedInt32Array()
var region_material_table: PackedFloat32Array = PackedFloat32Array()


static func load_bin(path: String) -> FleshData:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("FleshData: cannot open %s" % path)
		return null

	var magic := f.get_buffer(4)
	if magic != PackedByteArray([0x46, 0x4C, 0x53, 0x48]):
		push_error("FleshData: bad magic in %s" % path)
		return null

	var version := f.get_32()
	if version != 3:
		push_error("FleshData: unsupported version %d (expected v3; v2 files require re-bake at B4)" % version)
		return null

	var d := FleshData.new()
	var name_len := f.get_32()
	d.mesh_name = f.get_buffer(name_len).get_string_from_utf8()
	d.n_tet_verts = f.get_32()
	d.n_tet_cells = f.get_32()
	d.n_render_verts = f.get_32()

	d.tet_verts         = _read_f32(f, d.n_tet_verts * 3)
	d.tet_cells         = _read_i32(f, d.n_tet_cells * 4)
	d.bary_tet_idx      = _read_i32(f, d.n_render_verts)
	d.bary_uvw          = _read_f32(f, d.n_render_verts * 3)
	d.render_influence  = _read_f32(f, d.n_render_verts)
	d.tet_skin_indices  = _read_i32(f, d.n_tet_verts * 4)
	d.tet_skin_weights  = _read_f32(f, d.n_tet_verts * 4)

	f.close()
	d._extract_outer_faces()
	return d


# Find tet outer faces and orient them outward.
#
# A tet face is a 3-tuple of its 4 verts. Interior faces are shared by
# exactly two tets; boundary (outer) faces appear in exactly one. We hash
# by the SORTED triple to recognize the two orientations of an interior
# face as the same key, and store the original outward-oriented triple
# in `outer_faces`. Outward = face normal points away from the fourth
# (opposing) tet vertex.
#
# Cost: O(4 * Nt) hash ops at load. Nt is one-shot at hero load, not in
# the hot path.
func _extract_outer_faces() -> void:
	outer_faces = PackedInt32Array()
	n_outer_faces = 0
	if n_tet_cells <= 0:
		return

	# Per-tet face vertex indices: each row picks the 3 verts NOT in
	# position i. e.g. row 0 = verts 1,2,3 (face opposite vert 0).
	# Order matters for orientation — these are arranged so that with
	# the standard "fourth vert is positive side" convention, the
	# outward-pointing normal is computed below.
	var face_index_table := [
		[1, 2, 3],   # opposite vert 0
		[0, 3, 2],   # opposite vert 1
		[0, 1, 3],   # opposite vert 2
		[0, 2, 1],   # opposite vert 3
	]

	# key = sorted triple as String "a_b_c", value = [tet_idx, local_face]
	# Single-entry list signals outer; second insertion removes it.
	var seen: Dictionary = {}

	for ti in range(n_tet_cells):
		var v0: int = tet_cells[ti * 4 + 0]
		var v1: int = tet_cells[ti * 4 + 1]
		var v2: int = tet_cells[ti * 4 + 2]
		var v3: int = tet_cells[ti * 4 + 3]
		var verts := [v0, v1, v2, v3]
		for fi in range(4):
			var row: Array = face_index_table[fi]
			var a: int = verts[row[0]]
			var b: int = verts[row[1]]
			var c: int = verts[row[2]]
			var key := _sorted_face_key(a, b, c)
			if seen.has(key):
				# Interior face — remove pairing.
				seen.erase(key)
			else:
				seen[key] = [ti, fi]

	# Build outer_faces, orienting each outward.
	var n: int = seen.size()
	outer_faces.resize(n * 3)
	var w: int = 0
	for key in seen:
		var pair: Array = seen[key]
		var ti: int = pair[0]
		var fi: int = pair[1]
		var v0i: int = tet_cells[ti * 4 + 0]
		var v1i: int = tet_cells[ti * 4 + 1]
		var v2i: int = tet_cells[ti * 4 + 2]
		var v3i: int = tet_cells[ti * 4 + 3]
		var verts := [v0i, v1i, v2i, v3i]
		var row: Array = face_index_table[fi]
		var a: int = verts[row[0]]
		var b: int = verts[row[1]]
		var c: int = verts[row[2]]
		# Opposing fourth vert (the one not in this face): `fi` selects it.
		var d_idx: int = verts[fi]
		# Outward orientation check: (b - a) × (c - a) should point AWAY
		# from `d`. If it points toward `d`, swap b and c to flip.
		var pa := _vert(a)
		var pb := _vert(b)
		var pc := _vert(c)
		var pd := _vert(d_idx)
		var nrm: Vector3 = (pb - pa).cross(pc - pa)
		if nrm.dot(pd - pa) > 0.0:
			# Normal currently points toward d → swap b and c to flip.
			var tmp: int = b
			b = c
			c = tmp
		# else: orientation is already outward; keep as-is.
		outer_faces[w + 0] = a
		outer_faces[w + 1] = b
		outer_faces[w + 2] = c
		w += 3
	n_outer_faces = n


func _vert(i: int) -> Vector3:
	return Vector3(tet_verts[i * 3 + 0], tet_verts[i * 3 + 1], tet_verts[i * 3 + 2])


static func _sorted_face_key(a: int, b: int, c: int) -> String:
	# Cheap canonical sort of three ints. Used as a dictionary key only;
	# String is fine for the Nt scales we see (10²–10⁵).
	var lo: int = a
	var mid: int = b
	var hi: int = c
	var t: int
	if mid < lo:
		t = lo
		lo = mid
		mid = t
	if hi < mid:
		t = mid
		mid = hi
		hi = t
	if mid < lo:
		t = lo
		lo = mid
		mid = t
	return "%d_%d_%d" % [lo, mid, hi]


# Bulk-decode helpers. PackedByteArray.to_float32_array() / .to_int32_array()
# reinterpret the underlying bytes as little-endian f32/i32 — same result as
# the prototype's per-element decode_float/decode_s32 loops, ~10× faster on
# real data (Nv/Nt/Nr can be 10⁴–10⁵).
static func _read_f32(f: FileAccess, count: int) -> PackedFloat32Array:
	if count <= 0:
		return PackedFloat32Array()
	var bytes := f.get_buffer(count * 4)
	return bytes.to_float32_array()


static func _read_i32(f: FileAccess, count: int) -> PackedInt32Array:
	if count <= 0:
		return PackedInt32Array()
	var bytes := f.get_buffer(count * 4)
	return bytes.to_int32_array()
