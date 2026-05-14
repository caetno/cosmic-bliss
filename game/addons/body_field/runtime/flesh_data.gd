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
	return d


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
