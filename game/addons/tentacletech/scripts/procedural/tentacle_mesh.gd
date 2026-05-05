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
const _SilhouetteBakeContextScript := preload("res://addons/tentacletech/scripts/procedural/silhouette_bake_context.gd")

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
# Rounded cap closing the tip: this many intermediate rings sit on an
# ellipsoidal quarter-arc from (z=length, radius=tip_radius) to the apex at
# (z=length + tip_radius * tip_pointiness, radius=0). 0 reverts to the
# original single-vertex triangle-fan apex (sharp point — looks pointy, not
# tentacle-like). The eventual `TipFeature` library (§10.2) supersedes this
# with a discriminated Pointed/Rounded/Bulb/Mouth/Canal/Flare resource;
# until that lands, the implicit default tip is a small rounded dome.
@export_range(0, 16, 1) var tip_cap_rings: int = 3 :
	set(v):
		if tip_cap_rings == v: return
		tip_cap_rings = v
		_invalidate_and_request()
# Cap height as a multiplier on `tip_radius`. The cap profile is an
# ellipsoidal quarter-arc with semi-axes (tip_radius, tip_radius *
# tip_pointiness). 1.0 = hemisphere (cap height = tip_radius — looks flat
# when tip_radius is small relative to body); > 1 = elongated, pointier;
# < 1 = squashed dome. Decoupled from `tip_radius` so a thin-tipped body
# (small tip_radius) can still terminate in a visibly tapered cap. Has no
# effect when `tip_cap_rings = 0`.
@export_range(0.0, 16.0, 0.05, "or_greater") var tip_pointiness: float = 2.0 :
	set(v):
		if tip_pointiness == v: return
		tip_pointiness = v
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
# Slice 5H — feature silhouette: 2D R32F image (axial × angular) of
# outward radial perturbation in metres, summed across all features.
# Default value zero (no perturbation). Re-baked when any feature
# emits `changed` via the existing `_invalidate_and_request` flow.
var _cached_feature_silhouette: ImageTexture = null
var _cached_feature_silhouette_image: Image = null
# Re-entrancy guard: _ensure_baked() mutates state that other accessors
# (called from inside features) may read. Cheap belt-and-braces.
var _baking: bool = false

# Resources whose `changed` signal we forward into `_invalidate_and_request`.
# Walked from `radius_curve`, `twist_curve`, every entry in `features`, and
# recursively into each feature's Resource sub-properties (mainly nested
# Curves like `KnotFieldFeature.spacing_curve`). Without this chain, only
# reassigning a Curve reference triggered a rebake; editing the points
# inside the curve, or any per-feature property, silently no-op'd until
# the resource was reloaded.
var _subscribed_dependencies: Array[Resource] = []

# Leading-edge debounce for `request_update()`. The first invalidation in
# a quiet period bakes immediately (single property edits stay snappy);
# subsequent invalidations during the cooldown are coalesced into one
# trailing bake when the cooldown expires. A 60 Hz slider scrub becomes
# ~2 bakes (first frame + post-scrub) instead of 60. `bake()` (the
# explicit ship path used by tests and savers) bypasses all of this —
# it calls `_ensure_baked()` directly, so deterministic / headless flows
# stay synchronous.
const _COOLDOWN_MSEC: int = 80
var _cooldown_active: bool = false
var _cooldown_pending: bool = false
var _cooldown_start_msec: int = 0


func _invalidate_and_request() -> void:
	_baked = false
	# Re-walk on every invalidation: the feature graph may have been
	# restructured (curve swapped in, feature appended) and the cheapest
	# robust path is to disconnect everything and rebuild the listener set.
	_refresh_subscriptions()
	if _cooldown_active:
		_cooldown_pending = true
		return
	_cooldown_active = true
	_cooldown_pending = false
	_cooldown_start_msec = Time.get_ticks_msec()
	request_update()
	_check_cooldown.call_deferred()


func _check_cooldown() -> void:
	var elapsed: int = Time.get_ticks_msec() - _cooldown_start_msec
	if elapsed < _COOLDOWN_MSEC:
		_check_cooldown.call_deferred()
		return
	_cooldown_active = false
	if _cooldown_pending:
		_cooldown_pending = false
		_invalidate_and_request()


func _refresh_subscriptions() -> void:
	for r in _subscribed_dependencies:
		if is_instance_valid(r) and r.changed.is_connected(_on_dependency_changed):
			r.changed.disconnect(_on_dependency_changed)
	_subscribed_dependencies.clear()
	_subscribe_dependency(radius_curve)
	_subscribe_dependency(twist_curve)
	for f in features:
		if f == null:
			continue
		_subscribe_dependency(f)
		_subscribe_feature_subresources(f)


func _subscribe_dependency(p_res: Resource) -> void:
	if p_res == null or _subscribed_dependencies.has(p_res):
		return
	_subscribed_dependencies.append(p_res)
	if not p_res.changed.is_connected(_on_dependency_changed):
		p_res.changed.connect(_on_dependency_changed)


# Walk a feature's storage properties and subscribe to any nested Resources
# (Curves on KnotField/Ribs/Spines/etc.). Inspector point-drags on a nested
# curve emit `changed` on the curve, not on the parent feature, so we have
# to listen on the leaves directly.
func _subscribe_feature_subresources(p_feature: Resource) -> void:
	var props: Array = p_feature.get_property_list()
	for p in props:
		if (p.usage & PROPERTY_USAGE_STORAGE) == 0:
			continue
		match p.name:
			"resource_local_to_scene", "resource_path", "resource_name", \
			"resource_scene_unique_id", "script", "metadata/_custom_type_script":
				continue
		var v: Variant = p_feature.get(p.name)
		if v is Resource:
			_subscribe_dependency(v)


func _on_dependency_changed() -> void:
	_invalidate_and_request()


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
	# Vertex-kernel features (KnotField, Ribs, WartCluster, Fin) displace
	# body vertices but cannot maintain correct normals analytically — the
	# perturbed surface gradient depends on neighbours. Recompute them once
	# at the end via face-normal accumulation. Topology-adding features
	# (sucker rim, spine cone, ribbon strip) author their own normals and
	# are skipped via the FEATURE_ID_BODY filter.
	ctx.recompute_body_normals()

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

	# Slice 5H — bake the 2D feature silhouette image. Each feature
	# deposits its radial-perturbation contribution; result is a
	# 256×16 R32F image of metres-of-outward-perturbation. Cached
	# for type-1/2/4 contact threshold sampling and for the gizmo.
	_bake_feature_silhouette()

	# AABB for spline-deformed culling. The vertex shader (§5.3) places each
	# ring along the bent spline, so the bent silhouette can reach laterally
	# in any direction (±X, ±Y) by up to the chain length. Along the chain
	# axis the mesh is one-sided: the anchor is at local origin and the
	# mesh extends in -Z by `length` (plus tip cap overrun). The chain only
	# crosses into +Z if it swings past the anchor — uncommon, and we accept
	# the (rare) cull miss in exchange for a tight rest-pose AABB that hugs
	# the actual visible mesh instead of mirroring above the anchor.
	#
	# Padded by peak_radius for the §3.1 layered girth deformation envelope.
	var cap_overrun: float = (tip_radius * tip_pointiness
			if tip_cap_rings > 0
			else length * 0.5 / float(length_segments))
	var pad: float = maxf(_cached_peak_radius,
			maxf(base_radius, maxf(tip_radius, cap_overrun)))
	var reach: float = length + pad
	# Local Z range: [-(length + pad), +pad]. Lateral X/Y: ±reach so a fully
	# bent chain (90° off-axis) is still inside the AABB.
	custom_aabb = AABB(
			Vector3(-reach, -reach, -length - pad),
			Vector3(2.0 * reach, 2.0 * reach, length + 2.0 * pad))

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


# Slice 5H — feature silhouette accessors. The image is the source of
# truth; the texture is a cache for GPU upload paths. Tentacle reads
# the texture at `set_tentacle_mesh` time and pushes it into the C++
# Tentacle node via `set_feature_silhouette`.
func get_baked_feature_silhouette() -> ImageTexture:
	_ensure_baked()
	return _cached_feature_silhouette


func get_baked_feature_silhouette_image() -> Image:
	_ensure_baked()
	return _cached_feature_silhouette_image


# Internal — runs every feature's `bake_silhouette_contribution` into a
# fresh 2D R32F image. Called by `_ensure_baked`.
func _bake_feature_silhouette() -> void:
	var silhouette_ctx: SilhouetteBakeContext = _SilhouetteBakeContextScript.new()
	silhouette_ctx.total_arc_length = _cached_rest_length if _cached_rest_length > 0.0 else length
	silhouette_ctx.image = SilhouetteBakeContext.make_image()
	for f in features:
		if f == null or not f.enabled:
			continue
		f.bake_silhouette_contribution(silhouette_ctx)
	_cached_feature_silhouette_image = silhouette_ctx.image
	# Convert image → ImageTexture (cached for GPU paths; the C++
	# Tentacle samples the underlying Image directly).
	_cached_feature_silhouette = ImageTexture.create_from_image(silhouette_ctx.image)


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

	# Rounded cap: insert `tip_cap_rings` intermediate rings on an
	# ellipsoidal quarter-arc with radial semi-axis `tip_radius` and axial
	# semi-axis `tip_radius * tip_pointiness`, closing at an apex at
	# z = length + tip_radius * tip_pointiness. With tip_cap_rings = 0 the
	# apex sits one half-segment past the last ring (legacy single-fan
	# behavior). Per-ring axial_t extends past 1.0 in proportion to z-overrun
	# so spline mapping (§5.3) and tip_blend stay continuous.
	var sign_f: float = float(intrinsic_axis_sign)
	var cap_axial: float = tip_radius * tip_pointiness
	var last_body_ring: PackedInt32Array = ring_indices[ring_count - 1]
	var prev_ring: PackedInt32Array = last_body_ring
	for cap_i in range(1, tip_cap_rings + 1):
		var theta: float = (float(cap_i) / float(tip_cap_rings + 1)) * (PI * 0.5)
		var ring_radius: float = tip_radius * cos(theta)
		var z_offset: float = cap_axial * sin(theta)
		var z: float = sign_f * (length + z_offset)
		var axial_t: float = 1.0 + (z_offset / length if length > 0.0 else 0.0)
		var twist: float = (twist_curve.sample(axial_t) * twist_total
				if twist_curve != null
				else twist_total * axial_t)
		# Ellipsoid surface normal: gradient of (r/a)² + (z/b)² = 1, i.e.
		# (cos θ / a, sin θ / b) before normalization. With a = tip_radius
		# and b = cap_axial; reduces to (cos θ, sin θ) for a hemisphere.
		var n_radial: float = cos(theta) / maxf(tip_radius, 1e-6)
		var n_axial: float = sin(theta) / maxf(cap_axial, 1e-6)
		var n_len: float = sqrt(n_radial * n_radial + n_axial * n_axial)
		n_radial /= n_len
		n_axial /= n_len
		var cap_ring := PackedInt32Array()
		cap_ring.resize(radial_segments)
		for i in radial_segments:
			var u: float = float(i) / float(radial_segments)
			var phi: float = TAU * u + seam_offset + twist
			var radial := Vector3(cos(phi), sin(phi), 0.0)
			var pos := Vector3(radial.x * ring_radius, radial.y * ring_radius, z)
			var normal := Vector3(radial.x * n_radial, radial.y * n_radial, sign_f * n_axial)
			var uv0 := Vector2(u, axial_t)
			var idx: int = p_ctx.add_vertex(pos, normal, uv0, Vector2.ZERO,
					Color(0, 0, 0, 1.0),
					Color(BakeContext.FEATURE_ID_BODY, 0, 0, 0))
			cap_ring[i] = idx
		p_ctx.connect_rings(prev_ring, cap_ring)
		prev_ring = cap_ring

	var apex_z: float
	if tip_cap_rings > 0:
		apex_z = sign_f * (length + cap_axial)
	else:
		apex_z = sign_f * length * (1.0 + 0.5 / float(length_segments))
	var apex_pos := Vector3(0, 0, apex_z)
	var apex_normal := Vector3(0, 0, sign_f)
	var apex_idx: int = p_ctx.add_vertex(
			apex_pos,
			apex_normal,
			Vector2(0.5, 1.0),
			Vector2.ZERO,
			Color(0, 0, 0, 1.0),
			Color(BakeContext.FEATURE_ID_BODY, 0, 0, 0))
	p_ctx.fan_ring_to_point(prev_ring, apex_idx)


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
