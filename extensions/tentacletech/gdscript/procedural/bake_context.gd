@tool
class_name BakeContext
extends RefCounted
## Mutable mesh-buffer state passed through the TentacleMesh bake pipeline.
##
## `TentacleMesh.bake()` constructs the base shape into this context, then
## walks `features` in order; each feature's `_apply(ctx)` mutates the
## buffers in place. After all features run, the context is flushed to an
## ArrayMesh by `flush_to_array_mesh()`.
##
## §10.2 channel layout (identical to what the shaders read):
##   UV0     — longitudinal U / circumferential V
##   UV1     — per-feature local UVs (sucker disc-space, fin span)
##   COLOR.r — sucker mask
##   COLOR.g — wart / papillae density
##   COLOR.b — fin / photophore mask
##   COLOR.a — tip blend (0 mid-body → 1 at apex)
##   CUSTOM0 — vec4: x = feature ID, y = canal interior flag, zw = reserved

# Channel name constants — passed to mark_mask() and recorded in
# `_get_required_masks()` for ordering validation.
const CH_COLOR_R := "color.r"
const CH_COLOR_G := "color.g"
const CH_COLOR_B := "color.b"
const CH_COLOR_A := "color.a"
const CH_UV0 := "uv0"
const CH_UV1 := "uv1"
const CH_CUSTOM0_X := "custom0.x"
const CH_CUSTOM0_Y := "custom0.y"
const CH_CUSTOM0_Z := "custom0.z"
const CH_CUSTOM0_W := "custom0.w"

# Feature IDs written to CUSTOM0.x (uint cast to float).
const FEATURE_ID_BODY := 0
const FEATURE_ID_SUCKER_CUP := 1
const FEATURE_ID_SUCKER_RIM := 2
# Subsequent feature IDs allocated as their subclasses land.

var vertices := PackedVector3Array()
var normals := PackedVector3Array()
var colors := PackedColorArray()
var uv0 := PackedVector2Array()
var uv1 := PackedVector2Array()
# Godot's ArrayMesh CUSTOM0 takes 4 floats per vertex (Mesh.ARRAY_FORMAT_CUSTOM0
# with the float32x4 flag); we keep them flat here.
var custom0 := PackedFloat32Array()
var indices := PackedInt32Array()

# Set of channel names features have written. Recorded in the bake header
# so the consumer (and validation) knows which CUSTOM* channels matter.
var channels_written := {}

# Diagnostic / error log — features push human-readable strings here, the
# bake driver decides whether to escalate (push_error) or warn.
var errors: PackedStringArray = PackedStringArray()
var warnings: PackedStringArray = PackedStringArray()


func vertex_count() -> int:
	return vertices.size()


# Append a single vertex with all channels. Returns the new index.
func add_vertex(p_pos: Vector3, p_normal: Vector3, p_uv0: Vector2,
		p_uv1: Vector2 = Vector2.ZERO,
		p_color: Color = Color(0, 0, 0, 0),
		p_custom0: Color = Color(0, 0, 0, 0)) -> int:
	var idx: int = vertices.size()
	vertices.push_back(p_pos)
	normals.push_back(p_normal)
	uv0.push_back(p_uv0)
	uv1.push_back(p_uv1)
	colors.push_back(p_color)
	custom0.push_back(p_custom0.r)
	custom0.push_back(p_custom0.g)
	custom0.push_back(p_custom0.b)
	custom0.push_back(p_custom0.a)
	return idx


# Add a ring of `segments` vertices around a center, with normals pointing
# radially in the (axis_a, axis_b) plane. Returns the indices of the new
# vertices in counterclockwise order.
func add_ring(p_center: Vector3, p_radius: float, p_axis_a: Vector3,
		p_axis_b: Vector3, p_segments: int, p_axial_t: float,
		p_seam_offset: float = 0.0,
		p_color: Color = Color(0, 0, 0, 0),
		p_custom0: Color = Color(0, 0, 0, 0)) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(p_segments)
	for i in p_segments:
		var theta: float = TAU * (float(i) / float(p_segments)) + p_seam_offset
		var dir: Vector3 = p_axis_a * cos(theta) + p_axis_b * sin(theta)
		var pos: Vector3 = p_center + dir * p_radius
		# UV: V = axial_t (base→tip), U = angle (-π..π → 0..1) so the seam
		# lands at U=0 / U=1.
		var u: float = float(i) / float(p_segments)
		var uv := Vector2(u, p_axial_t)
		var idx: int = add_vertex(pos, dir, uv, Vector2.ZERO, p_color, p_custom0)
		out[i] = idx
	return out


# Connect two rings with quad strips (2 triangles per quad). Both rings
# must have the same length; ring_a is the "lower" ring (smaller axial_t,
# i.e. closer to base for a +Z-extending mesh per §10.1). Winding produces
# outward-facing triangles when the mesh extends along +Z and the rings'
# vertices wind CCW around +Z (theta increases 0 → 2π).
func connect_rings(p_ring_a: PackedInt32Array, p_ring_b: PackedInt32Array) -> void:
	var n: int = p_ring_a.size()
	if n != p_ring_b.size():
		errors.push_back("connect_rings: ring sizes differ (%d vs %d)" % [n, p_ring_b.size()])
		return
	for i in n:
		var i_next: int = (i + 1) % n
		var a0: int = p_ring_a[i]
		var a1: int = p_ring_a[i_next]
		var b0: int = p_ring_b[i]
		var b1: int = p_ring_b[i_next]
		indices.push_back(a0); indices.push_back(a1); indices.push_back(b0)
		indices.push_back(a1); indices.push_back(b1); indices.push_back(b0)


# Triangle-fan a ring to a single apex vertex (used for the pointed tip cap).
# Winding produces outward-facing triangles when the apex sits past the ring
# in the +arc direction and the ring vertices wind CCW around the arc axis.
func fan_ring_to_point(p_ring: PackedInt32Array, p_apex_idx: int) -> void:
	var n: int = p_ring.size()
	for i in n:
		var i_next: int = (i + 1) % n
		indices.push_back(p_ring[i])
		indices.push_back(p_ring[i_next])
		indices.push_back(p_apex_idx)


# Mark a per-vertex channel value on the listed indices. `channel` is one
# of the CH_* constants. This records the channel as written for ordering
# validation. Returns the number of vertices actually updated.
func mark_mask(p_channel: String, p_indices: PackedInt32Array, p_value: float) -> int:
	channels_written[p_channel] = true
	var count: int = 0
	for idx in p_indices:
		if idx < 0 or idx >= vertices.size():
			continue
		match p_channel:
			CH_COLOR_R:
				var c: Color = colors[idx]; c.r = p_value; colors[idx] = c
			CH_COLOR_G:
				var c: Color = colors[idx]; c.g = p_value; colors[idx] = c
			CH_COLOR_B:
				var c: Color = colors[idx]; c.b = p_value; colors[idx] = c
			CH_COLOR_A:
				var c: Color = colors[idx]; c.a = p_value; colors[idx] = c
			CH_CUSTOM0_X:
				custom0[idx * 4 + 0] = p_value
			CH_CUSTOM0_Y:
				custom0[idx * 4 + 1] = p_value
			CH_CUSTOM0_Z:
				custom0[idx * 4 + 2] = p_value
			CH_CUSTOM0_W:
				custom0[idx * 4 + 3] = p_value
			_:
				warnings.push_back("mark_mask: unknown channel '%s'" % p_channel)
				return count
		count += 1
	return count


# Set UV1 on a vertex (for per-feature local UVs like sucker disc-space).
func set_uv1(p_index: int, p_uv1: Vector2) -> void:
	channels_written[CH_UV1] = true
	if p_index >= 0 and p_index < uv1.size():
		uv1[p_index] = p_uv1


func flush_to_array_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if vertices.is_empty() or indices.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uv0
	arrays[Mesh.ARRAY_TEX_UV2] = uv1
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_CUSTOM0] = custom0
	arrays[Mesh.ARRAY_INDEX] = indices
	# CUSTOM0 is a vec4 of floats per vertex — encode the format in the
	# surface flags. (See Mesh.ARRAY_FORMAT_CUSTOM_BASE / CUSTOM_BIT shifts.)
	var flags: int = (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
	return mesh


func channels_used_array() -> PackedStringArray:
	var out := PackedStringArray()
	for k in channels_written.keys():
		out.push_back(k)
	out.sort()
	return out
