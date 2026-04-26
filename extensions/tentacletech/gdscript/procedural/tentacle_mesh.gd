@tool
class_name TentacleMesh
extends Resource
## §10.2 TentacleMesh authoring resource.
##
## Carries the base-shape parameters (length, radii, segments, taper, twist,
## seam offset, intrinsic axis) and an Array[TentacleFeature] catalog. The
## resource is `@tool`; assigning it into a Tentacle (or invoking bake()
## directly) produces an ArrayMesh + auto-baked girth profile via §5.4.
##
## §5.0 partition: this resource lives in the **mesh** layer — it authors
## silhouette-defining geometry (suckers, knots, ribs once those features
## land) and the masks the fragment shader interprets. The vertex shader
## (§5.3) deforms what the mesh produces; the fragment shader reads the
## masks; this resource never customizes shading directly.
##
## Runtime regen policy (§5.4): bake() runs at edit time when properties
## change; the result is normally saved as a static `.tres` ArrayMesh that
## ships with the game. Runtime rebake is *supported* (cheap on this
## resource — single-digit ms at typical density) but not the path to
## physics motion.

const _BakeContextScript := preload("res://addons/tentacletech/scripts/procedural/bake_context.gd")
const _GirthBaker := preload("res://addons/tentacletech/scripts/procedural/girth_baker.gd")

enum CrossSection {
	CIRCULAR = 0,
	# NGon, Ellipse, Lobed deferred — landing alongside the features that
	# actually need them (Phase 9 polish).
}

@export var length: float = 0.4
@export_range(0.001, 1.0, 0.001, "or_greater") var base_radius: float = 0.04
@export_range(0.0, 1.0, 0.001, "or_greater") var tip_radius: float = 0.005
@export var radius_curve: Curve = null   # if set, overrides linear taper
@export_range(3, 64, 1) var radial_segments: int = 16
@export_range(2, 128, 1) var length_segments: int = 24
@export var cross_section: CrossSection = CrossSection.CIRCULAR
@export var twist_total: float = 0.0     # rad along the full length
@export var twist_curve: Curve = null    # if set, overrides linear twist
@export_range(-3.14159, 3.14159, 0.001) var seam_offset: float = 0.0
# §10.2: intrinsic_axis must be -Z to match Tentacle::initialize_chain. We
# enforce this by exposing the *sign* only — flipping is for testing.
@export var intrinsic_axis_sign: int = -1
@export var features: Array[TentacleFeature] = []


# Bake the full mesh + girth profile.
# Returns:
#   "mesh"           — ArrayMesh
#   "girth_texture"  — ImageTexture (FORMAT_RF, 256×1, [0,1])
#   "rest_length"    — float (= length unless features extend the envelope)
#   "channels_used"  — PackedStringArray of mask channels written
#   "errors"         — PackedStringArray (non-empty == bake had problems)
#   "warnings"       — PackedStringArray
func bake() -> Dictionary:
	var ctx: BakeContext = _BakeContextScript.new()

	# Stash base-shape parameters so features can read them without needing
	# a back-reference to TentacleMesh.
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

	var mesh: ArrayMesh = ctx.flush_to_array_mesh()

	var girth_data: Dictionary = _GirthBaker.bake_from_mesh_data(ctx.vertices, 2)
	var rest_length: float = girth_data.get("rest_length", length)

	for err in ctx.errors:
		push_error("TentacleMesh.bake(): %s" % err)

	return {
		"mesh": mesh,
		"girth_texture": girth_data.get("girth_texture"),
		"rest_length": rest_length,
		"peak_radius": girth_data.get("peak_radius", base_radius),
		"channels_used": ctx.channels_used_array(),
		"errors": ctx.errors,
		"warnings": ctx.warnings,
	}


# Convenience for callers that only want the geometry — equivalent to
# `bake().mesh`. Provided so users can wire `tentacle.tentacle_mesh =
# tentacle_mesh.get_baked_mesh()` and let the GirthBaker output be wired
# separately via `Tentacle.set_rest_girth_texture(...)`.
func get_baked_mesh() -> ArrayMesh:
	return bake().get("mesh")


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

		# Tip blend: smooth gradient 0 mid-body → 1 at apex per the §10.2
		# COLOR.a contract. Use a soft curve so it ramps over the last ~25%.
		var tip_blend: float = clampf((axial_t - 0.75) / 0.25, 0.0, 1.0)
		var color := Color(0.0, 0.0, 0.0, tip_blend)

		var ring: PackedInt32Array = _add_circular_ring(p_ctx, center, radius,
				axial_t, twist, color)
		ring_indices[ring_i] = ring

	# Connect adjacent rings with quad strips.
	for i in range(ring_count - 1):
		var a: PackedInt32Array = ring_indices[i]
		var b: PackedInt32Array = ring_indices[i + 1]
		p_ctx.connect_rings(a, b)

	# Close the tip: a single apex vertex past the last ring, fan-connected.
	var last_ring: PackedInt32Array = ring_indices[ring_count - 1]
	var apex_pos := Vector3(0, 0, float(intrinsic_axis_sign) * length * (1.0 + 1.0 / float(length_segments) * 0.5))
	var apex_normal := Vector3(0, 0, float(intrinsic_axis_sign))
	var apex_idx: int = p_ctx.add_vertex(
			apex_pos,
			apex_normal,
			Vector2(0.5, 1.0), # UV0: U=0.5 (mid-seam), V=1 (tip)
			Vector2.ZERO,
			Color(0, 0, 0, 1.0), # COLOR.a = 1 at apex
			Color(BakeContext.FEATURE_ID_BODY, 0, 0, 0))
	p_ctx.fan_ring_to_point(last_ring, apex_idx)


func _add_circular_ring(p_ctx: BakeContext, p_center: Vector3, p_radius: float,
		p_axial_t: float, p_twist: float, p_color: Color) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(radial_segments)
	for i in radial_segments:
		# Theta progresses CCW around +Z. seam_offset shifts the U origin
		# so the seam lands at U=0; twist rotates per axial position.
		var u: float = float(i) / float(radial_segments)
		var theta: float = TAU * u + seam_offset + p_twist
		var dir := Vector3(cos(theta), sin(theta), 0)
		var pos: Vector3 = p_center + dir * p_radius
		# UV0: U = ring index (with seam at 0), V = axial_t.
		var uv0 := Vector2(u, p_axial_t)
		var idx: int = p_ctx.add_vertex(pos, dir, uv0, Vector2.ZERO,
				p_color, Color(BakeContext.FEATURE_ID_BODY, 0, 0, 0))
		out[i] = idx
	return out


func _run_features(p_ctx: BakeContext) -> void:
	# Validate ordering: a feature's _get_required_masks() lists the channels
	# it *writes*. If a later feature reads (depends on) a channel an earlier
	# feature also writes, last-writer-wins is fine. We log a warning when a
	# channel is overwritten by a later feature, since that's almost always
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
