@tool
class_name SurfaceJiggleAttachment
extends SurfaceAttachment

## §17.5 — Marionette jiggle attachment authored in Godot.
##
## Replaces the pre-§17 "child bones in the skeleton hierarchy at
## modeling time + skin weights painted in Blender" authoring path
## (Marionette `Marionette_plan.md` §15 amendment 2026-05-07-02).
##
## Authoring contract:
##   1. User places a `SurfaceJiggleAttachment` resource on a
##      `BodySurfaceField.attachments` slot.
##   2. `seed_position` is the jiggle's rest position in BodySurfaceField
##      LOCAL space (i.e. the body mesh's coordinate frame). v1 contract:
##      a Vector3 typed into the inspector. The user reads it off the
##      body-mesh viewport via a temporary marker or scripted helper.
##   3. `host_bone` names the bone the jiggle's virtual SPD particle
##      hangs off — Marionette's §15 consumer reads it.
##   4. `falloff_radius_m` controls how far the jiggle's influence
##      reaches along the body surface (geodesic distance, not 3D).
##   5. `falloff_curve` shapes the per-vertex weight as a function of
##      normalized geodesic distance `t = clamp(d / radius, 0, 1)`.
##   6. `weight_mode = ADDITIVE` (inherited default) is correct for
##      jiggle: the baked weights add to the host bone's existing skin
##      weights, not replace them. Marionette's render-mesh additive-
##      offset path consumes the weight × particle-displacement.
##
## Consumer-side runtime (Marionette, separate slice):
##   - One translation-only SPD particle per jiggle attachment.
##   - Particle anchored to `host_bone`'s pose; integrated each substep.
##   - Per-vertex render-mesh additive offset = baked_weights × particle_displacement.
##   - The render-mesh-additive-offset path is the no-body_field fallback
##     too (Marionette §15 amendment retires the Blender-bone path on
##     body_field-present heroes; body_field-absent heroes keep their
##     pre-§17 Blender jiggle bones).

enum FalloffCurve {
	LINEAR,       # w = 1 - t
	SMOOTHSTEP,   # w = smoothstep(1, 0, t) — Hermite, C¹ at both ends
	GAUSSIAN,     # w = exp(-t² · 4)   (k=4 gives w(t=1) ≈ 0.018, near zero at radius)
}

## Jiggle rest position in BodySurfaceField LOCAL space.
@export var seed_position: Vector3 = Vector3.ZERO

## Geodesic distance (in metres, along the body surface) past which
## the baked weight is zero. Default 0.10 m ≈ 10 cm = breast-region
## scale on a kasumi-class hero. Tune per attachment.
@export var falloff_radius_m: float = 0.10

@export var falloff_curve: FalloffCurve = FalloffCurve.SMOOTHSTEP


func bake(field) -> PackedFloat32Array:
	if field == null:
		push_error("SurfaceJiggleAttachment.bake: field is null")
		return PackedFloat32Array()
	if falloff_radius_m <= 0.0:
		push_error("SurfaceJiggleAttachment.bake: falloff_radius_m must be > 0")
		return PackedFloat32Array()

	var verts: PackedVector3Array = field.get_source_vertices()
	var n: int = verts.size()
	if n == 0:
		push_error("SurfaceJiggleAttachment.bake: field has no source vertices — call _ensure_factor() first")
		return PackedFloat32Array()

	# Find the surface vertex nearest the authored seed position.
	var seed_idx: int = 0
	var d_min: float = INF
	for vi in range(n):
		var d: float = verts[vi].distance_squared_to(seed_position)
		if d < d_min:
			d_min = d
			seed_idx = vi

	# Geodesic distance from the seed to every other vertex.
	var seeds: PackedInt32Array = PackedInt32Array([seed_idx])
	var phi: PackedFloat32Array = field.diffuse_geodesic(seeds)
	if phi.size() != n:
		push_error("SurfaceJiggleAttachment.bake: diffuse_geodesic returned %d, expected %d" % [phi.size(), n])
		return PackedFloat32Array()

	# Shape the per-vertex weight by the falloff curve over normalized
	# geodesic distance `t = clamp(d / radius, 0, 1)`.
	var weights: PackedFloat32Array = PackedFloat32Array()
	weights.resize(n)
	for i in range(n):
		var t: float = clampf(phi[i] / falloff_radius_m, 0.0, 1.0)
		weights[i] = _falloff(t)
	return weights


func _falloff(t: float) -> float:
	# t ∈ [0, 1]; w(0) = 1 (peak at seed), w(1) ≈ 0 (at the radius).
	match falloff_curve:
		FalloffCurve.LINEAR:
			return 1.0 - t
		FalloffCurve.SMOOTHSTEP:
			# Standard Hermite: smoothstep(0, 1, 1 - t) =
			#   (1 - t)² · (1 + 2·t) when 1 - t ∈ [0, 1].
			var s: float = 1.0 - t
			return s * s * (3.0 - 2.0 * s)
		FalloffCurve.GAUSSIAN:
			# k = 4 → w(1) = exp(-4) ≈ 0.0183 (essentially zero).
			return exp(-4.0 * t * t)
	return 1.0 - t
