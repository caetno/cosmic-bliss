@tool
class_name TentacleMesh
extends PrimitiveMesh
## §10.2a TentacleMesh authoring resource — `PrimitiveMesh` subclass.
##
## Live preview via `_create_mesh_array()`. Inspector edits call
## `request_update()`; the engine regenerates surface arrays lazily on the
## next draw. Avoids the per-set `ArrayMesh` allocation and inspector-focus
## drop that came with the previous `ArrayMesh` shape.
##
## §5.0 partition: this resource lives in the **mesh** layer — it authors
## silhouette-defining geometry (suckers, knots, ribs once those features
## land) and the masks the fragment shader interprets.
##
## §10.1 convention: cylindrical mesh aligned along **+Z**, base ring at
## z=0, vertex.z = arc-length from base. The intrinsic-axis-sign override
## remains for back-compat / Blender pipelines that authored along -Z, but
## defaults to +1 so the shader's spline mapping is orientation-preserving
## (mesh_arc_sign=+1) and triangle winding stays correct.
##
## **Bake-to-ship.** `bake()` returns a frozen `ArrayMesh` plus the auxiliary
## outputs (girth_texture, rest_length, mask channels) — same Dictionary the
## previous Resource shape produced. `_create_mesh_array()` omits CUSTOM0
## (PrimitiveMesh's auto-format path doesn't expose RGBA-float surface
## flags); features that depend on CUSTOM0 disambiguation get the full
## channel set via `bake()`'s frozen ArrayMesh.

const _BakeContextScript := preload("res://addons/tentacletech/scripts/procedural/bake_context.gd")
const _GirthBaker := preload("res://addons/tentacletech/scripts/procedural/girth_baker.gd")

enum CrossSection {
	CIRCULAR = 0,
	# NGon, Ellipse, Lobed deferred — landing alongside the features that
	# actually need them (Phase 9 polish).
}

@export var length: float = 0.4 :
	set(v):
		if length == v: return
		length = v
		_invalidate_and_request()
@export_range(0.001, 1.0, 0.001, "or_greater") var base_radius: float = 0.04 :
	set(v):
		if base_radius == v: return
		base_radius = v
		_invalidate_and_request()
@export_range(0.0, 1.0, 0.001, "or_greater") var tip_radius: float = 0.005 :
	set(v):
		if tip_radius == v: return
		tip_radius = v
		_invalidate_and_request()
@export var radius_curve: Curve = null :
	set(v):
		radius_curve = v
		_invalidate_and_request()
@export_range(3, 64, 1) var radial_segments: int = 16 :
	set(v):
		if radial_segments == v: return
		radial_segments = v
		_invalidate_and_request()
@export_range(2, 128, 1) var length_segments: int = 24 :
	set(v):
		if length_segments == v: return
		length_segments = v
		_invalidate_and_request()
@export var cross_section: CrossSection = CrossSection.CIRCULAR :
	set(v):
		if cross_section == v: return
		cross_section = v
		_invalidate_and_request()
@export var twist_total: float = 0.0 :
	set(v):
		if twist_total == v: return
		twist_total = v
		_invalidate_and_request()
@export var twist_curve: Curve = null :
	set(v):
		twist_curve = v
		_invalidate_and_request()
@export_range(-3.14159, 3.14159, 0.001) var seam_offset: float = 0.0 :
	set(v):
		if seam_offset == v: return
		seam_offset = v
		_invalidate_and_request()
# §10.1 default is +1 (mesh extends along +Z). Sign=-1 is supported for
# Blender-imported meshes authored along -Z, but procedural bakes default to
# +1 so the shader mapping is orientation-preserving and triangle winding
# stays correct without per-shader compensation.
@export var intrinsic_axis_sign: int = 1 :
	set(v):
		var clamped: int = -1 if v < 0 else 1
		if intrinsic_axis_sign == clamped: return
		intrinsic_axis_sign = clamped
		_invalidate_and_request()
@export var features: Array[TentacleFeature] = [] :
	set(v):
		features = v
		_invalidate_and_request()


# Cached side outputs of the most recent bake. Surface arrays + the
# auxiliary girth/rest_length/mask data are produced together so the
# physics consumers (Tentacle.set_rest_girth_texture) and the renderer
# (PrimitiveMesh._create_mesh_array) stay in lockstep.
var _baked: bool = false
var _cached_arrays: Array = []
var _cached_custom0: PackedFloat32Array = PackedFloat32Array()
var _cached_girth_texture: ImageTexture = null
var _cached_girth_samples: PackedFloat32Array = PackedFloat32Array()
var _cached_rest_length: float = 0.0
var _cached_peak_radius: float = 0.0
var _cached_channels_used: PackedStringArray = PackedStringArray()
var _cached_errors: PackedStringArray = PackedStringArray()
var _cached_warnings: PackedStringArray = PackedStringArray()
# Re-entrancy guard: _ensure_baked() mutates state that other accessors
# (called from inside features) may read. Cheap belt-and-braces.
var _baking: bool = false


# Setter helper: invalidate cache and ask the engine to redraw. PrimitiveMesh
# emits `changed` after its deferred update completes, which Tentacle's
# `_on_tentacle_mesh_changed` listens to for the rest-girth re-pull.
func _invalidate_and_request() -> void:
	_baked = false
	request_update()


# Idempotent: rebakes if dirty, no-op otherwise. All public accessors funnel
# through this so the cache and the surface arrays are always derived from
# the same in-memory snapshot of the parameters.
func _ensure_baked() -> void:
	if _baked or _baking:
		return
	_baking = true

	var ctx: BakeContext = _BakeContextScript.new()
	ctx.set_meta(&"tentacle_mesh_meta", {
		"length": length,
		"base_radius": base_radius,
		"tip_radius": tip_radius,
		"radius_curve": radius_curve,
		"radial_segments": radial_segments,
		"length_segments": length_segments,
		"twist_total": twist_total,
		"twist_curve": twist_curve,
		"seam_offset": seam_offset,
		"intrinsic_axis_sign": float(intrinsic_axis_sign),
	})
	_build_base_shape(ctx)
	_run_features(ctx)

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	if not ctx.vertices.is_empty() and not ctx.indices.is_empty():
		arrays[Mesh.ARRAY_VERTEX] = ctx.vertices
		arrays[Mesh.ARRAY_NORMAL] = ctx.normals
		arrays[Mesh.ARRAY_TEX_UV] = ctx.uv0
		arrays[Mesh.ARRAY_TEX_UV2] = ctx.uv1
		arrays[Mesh.ARRAY_COLOR] = ctx.colors
		arrays[Mesh.ARRAY_INDEX] = ctx.indices
	_cached_arrays = arrays
	_cached_custom0 = ctx.custom0

	var girth_data: Dictionary = _GirthBaker.bake_from_mesh_data(ctx.vertices, 2)
	_cached_girth_texture = girth_data.get("girth_texture")
	_cached_girth_samples = girth_data.get("girth_samples", PackedFloat32Array())
	_cached_rest_length = girth_data.get("rest_length", length)
	_cached_peak_radius = girth_data.get("peak_radius", base_radius)
	_cached_channels_used = ctx.channels_used_array()
	_cached_errors = ctx.errors
	_cached_warnings = ctx.warnings

	# Worst-case AABB for spline-deformed culling. The vertex shader
	# (§5.3) places each ring along the bent spline, so the deformed mesh
	# can reach anywhere within a sphere of radius `length` from the
	# Tentacle node origin. Without an override, Godot frustum-culls using
	# the rest-pose AABB (a cylinder along +Z from z=0 to z=length) and
	# drops the whole tentacle whenever the *rest pose* is off-screen even
	# if the bent silhouette is fully on-screen. Padded by peak_radius for
	# the §3.1 layered girth deformation envelope.
	var pad: float = maxf(_cached_peak_radius, maxf(base_radius, tip_radius))
	var reach: float = length + pad
	custom_aabb = AABB(Vector3(-reach, -reach, -reach), Vector3(2.0 * reach, 2.0 * reach, 2.0 * reach))

	_baked = true
	_baking = false

	for err in _cached_errors:
		push_error("TentacleMesh.bake(): %s" % err)


# PrimitiveMesh override. Returns the surface arrays for the live preview;
# CUSTOM0 is omitted because PrimitiveMesh's auto-format path doesn't expose
# the RGBA-float surface flag the bake-to-ship contract needs (§10.2 channel
# layout). Use bake() to get a fully-channelled frozen ArrayMesh.
func _create_mesh_array() -> Array:
	_ensure_baked()
	return _cached_arrays


# Bake-to-ship: returns a frozen `ArrayMesh` with the full channel layout
# (CUSTOM0 included via add_surface_from_arrays' explicit format flag) plus
# the auxiliary side outputs. The static `.tres` saved from this Dictionary
# is what ships; the live PrimitiveMesh path is for inspector preview only.
func bake() -> Dictionary:
	_baked = false
	_ensure_baked()
	var mesh := ArrayMesh.new()
	if not _cached_arrays.is_empty() and _cached_arrays[Mesh.ARRAY_VERTEX] != null:
		var arrays_with_custom: Array = _cached_arrays.duplicate()
		if arrays_with_custom.size() < Mesh.ARRAY_MAX:
			arrays_with_custom.resize(Mesh.ARRAY_MAX)
		arrays_with_custom[Mesh.ARRAY_CUSTOM0] = _cached_custom0
		var flags: int = (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays_with_custom, [], {}, flags)
		# Mirror the custom AABB onto the frozen ArrayMesh — the shipping
		# path needs the same spline-deformed envelope for frustum culling.
		mesh.custom_aabb = custom_aabb
	return {
		"mesh": mesh,
		"girth_texture": _cached_girth_texture,
		"rest_length": _cached_rest_length,
		"peak_radius": _cached_peak_radius,
		"channels_used": _cached_channels_used,
		"errors": _cached_errors,
		"warnings": _cached_warnings,
	}


func get_baked_girth_texture() -> ImageTexture:
	_ensure_baked()
	return _cached_girth_texture


# Raw 256-bin normalized girth samples (values in [0,1] against peak
# radius) — same data uploaded to the texture. Exposed because
# headless consumers cannot read pixels back from the GPU-side texture.
func get_baked_girth_samples() -> PackedFloat32Array:
	_ensure_baked()
	return _cached_girth_samples


func get_baked_rest_length() -> float:
	_ensure_baked()
	return _cached_rest_length


func get_baked_peak_radius() -> float:
	_ensure_baked()
	return _cached_peak_radius


func get_baked_channels_used() -> PackedStringArray:
	_ensure_baked()
	return _cached_channels_used


# Reports the mesh-axis convention the shader needs to interpret this
# resource. Tentacle.set_tentacle_mesh() duck-types this method and pipes
# the result into mesh_arc_axis / mesh_arc_sign / mesh_arc_offset.
func get_baked_arc_convention() -> Dictionary:
	return {
		"axis": 2,
		"sign": intrinsic_axis_sign,
		"offset": 0.0,
	}


# Build the cylindrical base shape into ctx: rings of radial_segments along
# axial_t ∈ [0,1], plus a single apex vertex that closes the tip with a
# triangle fan from the final ring (Pointed default — non-Pointed tip
# variants are deferred per the §10.2 batch scope).
func _build_base_shape(p_ctx: BakeContext) -> void:
	var ring_count: int = length_segments + 1
	var ring_indices: Array = []
	ring_indices.resize(ring_count)

	for ring_i in ring_count:
		var axial_t: float = float(ring_i) / float(length_segments)
		var radius: float = (radius_curve.sample(axial_t)
				if radius_curve != null
				else lerpf(base_radius, tip_radius, axial_t))
		var twist: float = (twist_curve.sample(axial_t) * twist_total
				if twist_curve != null
				else twist_total * axial_t)

		var z: float = float(intrinsic_axis_sign) * length * axial_t
		var center := Vector3(0, 0, z)

		var tip_blend: float = clampf((axial_t - 0.75) / 0.25, 0.0, 1.0)
		var color := Color(0.0, 0.0, 0.0, tip_blend)

		var ring: PackedInt32Array = _add_circular_ring(p_ctx, center, radius,
				axial_t, twist, color)
		ring_indices[ring_i] = ring

	for i in range(ring_count - 1):
		var a: PackedInt32Array = ring_indices[i]
		var b: PackedInt32Array = ring_indices[i + 1]
		p_ctx.connect_rings(a, b)

	# Pointed tip: apex sits one half-segment past the last ring along the
	# arc axis. Apex normal points along the arc axis (outward at the tip).
	var last_ring: PackedInt32Array = ring_indices[ring_count - 1]
	var apex_z: float = float(intrinsic_axis_sign) * length * (1.0 + 0.5 / float(length_segments))
	var apex_pos := Vector3(0, 0, apex_z)
	var apex_normal := Vector3(0, 0, float(intrinsic_axis_sign))
	var apex_idx: int = p_ctx.add_vertex(
			apex_pos,
			apex_normal,
			Vector2(0.5, 1.0),
			Vector2.ZERO,
			Color(0, 0, 0, 1.0),
			Color(BakeContext.FEATURE_ID_BODY, 0, 0, 0))
	p_ctx.fan_ring_to_point(last_ring, apex_idx)


func _add_circular_ring(p_ctx: BakeContext, p_center: Vector3, p_radius: float,
		p_axial_t: float, p_twist: float, p_color: Color) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(radial_segments)
	for i in radial_segments:
		var u: float = float(i) / float(radial_segments)
		var theta: float = TAU * u + seam_offset + p_twist
		var dir := Vector3(cos(theta), sin(theta), 0)
		var pos: Vector3 = p_center + dir * p_radius
		var uv0 := Vector2(u, p_axial_t)
		var idx: int = p_ctx.add_vertex(pos, dir, uv0, Vector2.ZERO,
				p_color, Color(BakeContext.FEATURE_ID_BODY, 0, 0, 0))
		out[i] = idx
	return out


func _run_features(p_ctx: BakeContext) -> void:
	# Validate ordering: a feature's _get_required_masks() lists the channels
	# it *writes*. Last-writer-wins is fine; we log a warning when a channel
	# is overwritten by a later feature, since that's almost always
	# unintended.
	var written_so_far := {}
	for f in features:
		if f == null:
			continue
		if not f.enabled:
			continue
		var declared: PackedStringArray = f._get_required_masks()
		for ch in declared:
			if written_so_far.has(ch):
				p_ctx.warnings.push_back(
					"feature %s overwrites channel '%s' previously written by %s"
						% [f.resource_path if f.resource_path != "" else f.get_class(),
							ch, written_so_far[ch]])
			written_so_far[ch] = (f.resource_path
					if f.resource_path != ""
					else f.get_class())
		f._apply(p_ctx)
