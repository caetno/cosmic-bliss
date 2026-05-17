@tool
class_name SurfaceOrificeRimAttachment
extends SurfaceAttachment

## §10.4-bf — body_field side of TT's orifice-rim authoring migration.
##
## Replaces the pre-§17 "rim anchor bones in Blender + skin weights
## painted in Blender to anchor names" authoring path (the "rebind
## trick" where the skinning shader swapped anchor-bone transforms for
## live rim-particle positions). Per `Marionette_plan.md §17 migration
## table, rim row.
##
## Multi-seed: every rim PBD particle is a separate seed. Each vertex
## gets one weight per particle, indicating how much the vertex follows
## that particle's motion. Across particles, weights normalize so a
## vertex inside the rim's influence sums to 1.0 (so the rim skins
## smoothly between particles, not double-weighted). Vertices outside
## the rim's geodesic radius get all-zero weights, and `baked_weights`
## (inherited from the base, kept as the per-vertex SUM) gives consumers
## a single mask scalar telling them which verts are rim-touched.
##
## Authoring contract:
##   1. User places a `SurfaceOrificeRimAttachment` resource on a
##      `BodySurfaceField.attachments` slot.
##   2. `rim_particle_positions` is the list of rim PBD particles' REST
##      positions in BodySurfaceField LOCAL space. v1 contract: user
##      snapshots them from TT's orifice rim once (TT-side helper);
##      thereafter the bake is one-shot at hero load. v1.5+ may
##      auto-snapshot from a NodePath to the TT rim node.
##   3. `falloff_radius_m` is the per-particle geodesic radius. Tight
##      by default (0.02 m = 2 cm) — rim influence is thin.
##   4. `falloff_curve` shapes per-particle contribution over normalized
##      geodesic distance `t = clamp(d / radius, 0, 1)`.
##   5. `weight_mode = REPLACE` is the correct base value here (and
##      defaults to it via this class's _init). Consumers (TT) use the
##      baked weights to FULLY drive rim vertex positions, replacing
##      any skeleton-LBS contribution on those verts.
##
## Consumer-side runtime (TT, separate slice TT §10.4):
##   - Per substep: rim_vert_pos[v] = Σ_p baked_per_particle_weights[v*n_p + p] × particle_world_pos[p]
##     for verts where baked_weights[v] > 0 (mask).
##   - Where baked_weights[v] == 0, the vertex falls back to standard
##     skeleton-LBS — that's the hard-optional fallback (body_field-
##     absent or attachments-empty heroes use the rebind-trick path).

enum FalloffCurve {
	LINEAR,
	SMOOTHSTEP,
	GAUSSIAN,
}

## Rim particle REST positions in BodySurfaceField LOCAL space.
@export var rim_particle_positions: PackedVector3Array = PackedVector3Array()

## Per-particle geodesic falloff radius (metres along the body
## surface). Default 0.02 m — rim is thin; broaden if the rim is
## a wide-mouth orifice.
@export var falloff_radius_m: float = 0.02

@export var falloff_curve: FalloffCurve = FalloffCurve.SMOOTHSTEP

## Output: length `n_verts * n_particles_baked`, indexed
## `[v * n_particles_baked + p]`. Each row sums to 1.0 within the
## rim's geodesic-radius mask; 0.0 outside.
@export var baked_per_particle_weights: PackedFloat32Array = PackedFloat32Array()

## Number of rim particles at bake time. Consumers MUST verify their
## current rim particle count matches before consuming — if the rim's
## particle topology changes, the bake is stale.
@export var n_particles_baked: int = 0


func _init() -> void:
	# Rim REPLACEs skeleton-LBS on touched verts (the "rebind trick"
	# semantic). Jiggle is additive; rim is replace.
	weight_mode = WeightMode.REPLACE


func bake(field) -> PackedFloat32Array:
	if field == null:
		push_error("SurfaceOrificeRimAttachment.bake: field is null")
		return PackedFloat32Array()
	if falloff_radius_m <= 0.0:
		push_error("SurfaceOrificeRimAttachment.bake: falloff_radius_m must be > 0")
		return PackedFloat32Array()

	var n_p: int = rim_particle_positions.size()
	if n_p == 0:
		push_error("SurfaceOrificeRimAttachment.bake: rim_particle_positions is empty — author them before baking")
		return PackedFloat32Array()

	var verts: PackedVector3Array = field.get_source_vertices()
	var n: int = verts.size()
	if n == 0:
		push_error("SurfaceOrificeRimAttachment.bake: field has no source vertices")
		return PackedFloat32Array()

	# --- Step 1: nearest welded vertex per particle.
	var seed_indices: PackedInt32Array = PackedInt32Array()
	seed_indices.resize(n_p)
	for p in range(n_p):
		var seed_idx: int = 0
		var d_min: float = INF
		for vi in range(n):
			var d2: float = verts[vi].distance_squared_to(rim_particle_positions[p])
			if d2 < d_min:
				d_min = d2
				seed_idx = vi
		seed_indices[p] = seed_idx

	# --- Step 2: per-particle geodesic distance (one solve each — the
	# Cholesky factor is shared, so each solve is just back-sub).
	# Pack raw weights into a flat row-major n × n_p buffer.
	var raw_per_particle: PackedFloat32Array = PackedFloat32Array()
	raw_per_particle.resize(n * n_p)
	for p in range(n_p):
		var phi: PackedFloat32Array = field.diffuse_geodesic(PackedInt32Array([seed_indices[p]]))
		if phi.size() != n:
			push_error("SurfaceOrificeRimAttachment.bake: diffuse_geodesic returned %d for particle %d" % [phi.size(), p])
			return PackedFloat32Array()
		for vi in range(n):
			var t: float = clampf(phi[vi] / falloff_radius_m, 0.0, 1.0)
			raw_per_particle[vi * n_p + p] = _falloff(t)

	# --- Step 3: per-vertex normalize across particles + build the
	# per-vertex mask sum.
	#
	# Convention: a vertex is "rim-influenced" iff Σ_p raw[v, p] > 0,
	# i.e. it's within at least one particle's geodesic radius. For such
	# vertices, normalize so Σ_p w[v, p] = 1. Outside the rim,
	# w[v, *] = 0 and mask = 0.
	var weights: PackedFloat32Array = PackedFloat32Array()
	weights.resize(n * n_p)
	var mask: PackedFloat32Array = PackedFloat32Array()
	mask.resize(n)
	for vi in range(n):
		var sum: float = 0.0
		for p in range(n_p):
			sum += raw_per_particle[vi * n_p + p]
		if sum > 1.0e-6:
			var inv: float = 1.0 / sum
			for p in range(n_p):
				weights[vi * n_p + p] = raw_per_particle[vi * n_p + p] * inv
			# Mask = un-normalized peak influence (saturates at 1.0
			# even for verts under many overlapping particles). This
			# gives consumers a smooth "rim influence falloff" scalar
			# for blending REPLACE-mode rim verts with LBS-mode body
			# verts at the boundary.
			var peak: float = 0.0
			for p in range(n_p):
				if raw_per_particle[vi * n_p + p] > peak:
					peak = raw_per_particle[vi * n_p + p]
			mask[vi] = clampf(peak, 0.0, 1.0)
		else:
			# Outside the rim; weights are already 0 from resize().
			mask[vi] = 0.0

	# --- Step 4: stash multi-particle output + return mask as
	# baked_weights (the base-class single-array slot).
	baked_per_particle_weights = weights
	n_particles_baked = n_p
	return mask


func _falloff(t: float) -> float:
	match falloff_curve:
		FalloffCurve.LINEAR:
			return 1.0 - t
		FalloffCurve.SMOOTHSTEP:
			var s: float = 1.0 - t
			return s * s * (3.0 - 2.0 * s)
		FalloffCurve.GAUSSIAN:
			return exp(-4.0 * t * t)
	return 1.0 - t
