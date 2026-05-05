extends SceneTree

# Slice 4Q diagnostic — round 3. Production-config repro.
#
# Round 2 reproduced coupled oscillation (90%+ phase-correlation between
# leg motion and contact churn) but with magnitude well below the user's
# visible-jitter threshold. The user identified two divergences:
#
#   1. Physics engine — round 2 ran on default Bullet; production runs
#      Jolt (game/project.godot 3d/physics_engine="Jolt Physics"). Jolt's
#      hull-vs-sphere contact algorithm picks closest points differently
#      from Bullet on a per-tick basis.
#   2. Collision shape kind — round 2 used boxes; production uses convex
#      hulls (Marionette BoneCollisionProfile default). Convex hulls from
#      imported skinned meshes have many small faces with edges every few
#      mm; tangentially-sliding particles produce discontinuous contact-
#      normal jumps at every face crossing.
#
# Round 3 fixes both. Joint stiffness/damping are the production HIP_K /
# HIP_C from MarionetteSpringDefaults (k=2.0, c=3.5 — "Jolt-direct" units;
# safe envelope 0.5..4.0 per the spring_defaults doc string).
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_4q_hull_diagnostic.gd
#
# Topology (same as round 2 — static pelvis is fine):
#   - 1 StaticBody3D "PelvisAnchor" at y=0.40 (joint root, no shape).
#   - 2 RigidBody3D "leg" bodies hanging at ±30° from vertical.
#     CollisionShape3D on each = ConvexPolygonShape3D fed a 24-axial ×
#     8-radial capsule-surface point cloud (192 points total). Yields a
#     cylinder-with-rounded-ends hull whose face count is high enough to
#     surface the edge-crossing mechanism.
#   - Generic6DOFJoint3D between each leg and pelvis with linear locks +
#     angular springs on all 3 axes (k=2.0, c=3.5, equilibrium=0).
#
# Tentacle: 4 particles × 5 cm, radius 4 cm, lubricity sweep 1.0/0.5/0.0,
# anchored y=0.55 above the V apex.
#
# Channels:
#   (i)–(vi) same as round 2 (slot id flips, point shifts, normal flips,
#           lambda oscillation, leg pos/lin_vel, leg ang_vel).
#   (vii)    Face-crossing events per slot: successive ticks where the
#           contact normal lies in a cone of half-angle ~5° (cosθ > 0.996)
#           are "same face"; jumps outside that cone are "face crossings".
#   (viii)   Cross-correlation between (vii) and (i)/(v)+(vi) — testing
#           the hypothesis "face crossings cause contact-set churn cause
#           impulse direction flip cause joint wobble". If face crossings
#           drop to zero (e.g. friction pins the particle on one face)
#           the cascade should stop.
#
# No fix code — diagnostic only. Acceptance per slice prompt: this script
# committed (test-only, simple), Jolt confirmed at start, logs reported,
# face-crossing analysis included, hold for review.

const DT := 1.0 / 60.0
const TOTAL_TICKS := 180          # 3 s — enough to see joint oscillation
const MEASURE_TICKS := 120        # last 2 s as the analysis window
const CHAIN_PARTICLES := 4
const SEGMENT_LEN := 0.05
const PARTICLE_RADIUS := 0.04

# Leg body geometry. Capsule-like convex hull.
const LEG_LEN := 0.4              # m
const LEG_RADIUS := 0.05          # m (capsule cross-section radius)
const LEG_MASS := 4.0             # kg (Marionette UpperLeg ballpark)
const HIP_OFFSET_X := 0.06        # m, half hip-width

# Hull faceting — production-realistic for a skinned imported mesh. 24
# axial slices × 8 radial points = 192 points; convex hull comes out with
# ~30-50 faces; tangential slip across the face seams every few mm = the
# expected face-crossing churn source.
const HULL_AXIAL_SLICES := 24
const HULL_RADIAL_POINTS := 8

# Joint tuning. Production HIP defaults from MarionetteSpringDefaults:
#   const _HIP_K := Vector3(2.0, 2.0, 2.0)
#   const _HIP_C := Vector3(3.5, 3.5, 3.5)
# Jolt-direct units. Safe envelope per docstring: 0.5..4.0 stiffness,
# 1.5..4.0 damping. Round 2 used 50/5 — over the envelope and underdamped.
const JOINT_SPRING_STIFFNESS := 2.0
const JOINT_SPRING_DAMPING := 3.5

# Wedge geometry — leg rotated 30° outward from vertical at rest.
const LEG_REST_TILT_DEG := 30.0

# Face-crossing threshold. cosθ > 0.996 ≈ 5° same-face cone.
const SAME_FACE_COS_THRESHOLD := 0.996


var _ran: bool = false


func _process(_delta: float) -> bool:
	if not _ran:
		_ran = true
		_run()
	return false  # always return false; _run() awaits and calls quit() when done


func _run() -> void:
	if not ClassDB.class_exists("Tentacle"):
		push_error("[FAIL] tentacletech extension not loaded")
		quit(2)
		return

	# ---- Jolt verification ----
	# Probe Jolt-specific settings exposed only when the Jolt module is
	# actually loaded by the engine. The base PhysicsServer3D class name
	# always returns "PhysicsServer3D" regardless of which server is
	# active, so we infer from the registered settings instead.
	var has_jolt: bool = (
			ProjectSettings.has_setting("physics/jolt_physics_3d/simulation/velocity_steps")
			or ProjectSettings.has_setting("physics/jolt_3d/simulation/velocity_steps")
	)
	var engine_name: String = String(ProjectSettings.get_setting("physics/3d/physics_engine", ""))

	print("\n========== 4Q round-3 diagnostic — Jolt + convex hull ==========")
	print("Physics engine setting: %s" % engine_name)
	print("Jolt module loaded:     %s" % ("yes" if has_jolt else "NO — falling back to default"))
	if not has_jolt or engine_name != "Jolt Physics":
		push_warning("Round 3 expects Jolt; results may not represent production.")
	print("Topology: 1 StaticBody3D anchor + 2 RigidBody3D legs (convex hull, %d-axial × %d-radial = %d points, ~capsule %.2fm × %.2fm radius, %.1fkg each)"
			% [HULL_AXIAL_SLICES, HULL_RADIAL_POINTS,
				HULL_AXIAL_SLICES * HULL_RADIAL_POINTS,
				LEG_LEN, LEG_RADIUS, LEG_MASS])
	print("Joint: Generic6DOFJoint3D, angular spring k=%.1f, damping=%.1f (Jolt-direct units; production HIP_K/HIP_C)"
			% [JOINT_SPRING_STIFFNESS, JOINT_SPRING_DAMPING])
	print("Tentacle: %d particles × %.2fm, radius %.2fm, gravity (0, -9.8, 0)"
			% [CHAIN_PARTICLES, SEGMENT_LEN, PARTICLE_RADIUS])
	print("Per run: %d ticks (%d × DT measurement window)" % [TOTAL_TICKS, MEASURE_TICKS])
	print()

	for lub in [1.0, 0.5, 0.0]:
		print("---------- lubricity = %.1f ----------" % lub)
		await _run_one(lub)
		print()
	quit(0)


func _run_one(p_lubricity: float) -> void:
	for c in root.get_children():
		root.remove_child(c)
		c.free()

	# 1. Pelvis anchor (StaticBody3D, no shape — joint root only).
	var pelvis := StaticBody3D.new()
	pelvis.name = "PelvisAnchor"
	pelvis.position = Vector3(0.0, 0.40, 0.0)
	root.add_child(pelvis)

	# 2. Legs (RigidBody3D × 2). Each leg is a capsule-surface convex hull
	# hanging from the pelvis at LEG_REST_TILT_DEG outward from vertical.
	var leg_l: RigidBody3D = _make_leg("LegL", -1.0)
	var leg_r: RigidBody3D = _make_leg("LegR", +1.0)

	# 3. Joints. Each leg is connected to the pelvis at its TOP end
	# (Generic6DOFJoint3D pivot at the leg's hip).
	_make_joint(pelvis, leg_l, "JointL")
	_make_joint(pelvis, leg_r, "JointR")

	# 4. Tentacle anchored above the V apex.
	var t: Node3D = ClassDB.instantiate("Tentacle")
	t.particle_count = CHAIN_PARTICLES
	t.segment_length = SEGMENT_LEN
	t.particle_collision_radius = PARTICLE_RADIUS
	t.gravity = Vector3(0, -9.8, 0)
	t.environment_probe_distance = 5.0
	t.tentacle_lubricity = p_lubricity
	t.base_static_friction = 0.4
	t.position = Vector3(0.0, 0.55, 0.0)
	t.name = "WedgeTentacle"
	root.add_child(t)

	# History: per-tick particle/contact + per-leg pose/velocity.
	var history: Array = []
	var leg_history: Array = []

	# Settle physics (legs equilibrate against gravity + spring) before
	# measurement starts.
	for _i in 60:
		await physics_frame

	for tick in TOTAL_TICKS:
		await physics_frame  # one Jolt step per loop iteration
		var before: PackedVector3Array = t.get_particle_positions().duplicate()
		t.tick(DT)
		var after: PackedVector3Array = t.get_particle_positions()
		if tick < TOTAL_TICKS - MEASURE_TICKS:
			continue
		var probe_snap: Array = t.get_environment_contacts_snapshot()
		var solver: Object = t.get_solver()
		var lambdas: PackedFloat32Array = solver.get_environment_normal_lambdas_snapshot()
		var per_particle: Array = []
		for pi in CHAIN_PARTICLES:
			var rec: Dictionary = {
				"particle": pi,
				"position": after[pi],
				"dpos": (after[pi] - before[pi]).length(),
				"slots": [],
			}
			if pi < probe_snap.size():
				var ps: Dictionary = probe_snap[pi]
				var contacts: Array = ps.get("contacts", [])
				for k in contacts.size():
					var slot: Dictionary = contacts[k]
					var lam: float = 0.0
					var lam_idx: int = pi * 2 + k
					if lam_idx < lambdas.size():
						lam = lambdas[lam_idx]
					rec.slots.append({
						"k": k,
						"object_id": slot.get("hit_object_id", 0),
						"point": slot.get("hit_point", Vector3.ZERO),
						"normal": slot.get("hit_normal", Vector3.ZERO),
						"depth": slot.get("hit_depth", 0.0),
						"normal_lambda": lam,
					})
			per_particle.append(rec)
		history.append(per_particle)
		leg_history.append({
			"L_pos": leg_l.global_position,
			"L_lin_vel": leg_l.linear_velocity,
			"L_ang_vel": leg_l.angular_velocity,
			"R_pos": leg_r.global_position,
			"R_lin_vel": leg_r.linear_velocity,
			"R_ang_vel": leg_r.angular_velocity,
		})

	_report(history, leg_history, p_lubricity)


func _make_leg(p_name: String, p_side: float) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = p_name
	body.mass = LEG_MASS
	body.gravity_scale = 1.0
	body.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.angular_damp = 0.0
	body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.linear_damp = 0.0
	# Position: hip at (±HIP_OFFSET_X, 0.40, 0); leg extends downward at
	# tilt outward.
	var tilt_rad: float = deg_to_rad(LEG_REST_TILT_DEG) * p_side
	var hip_world: Vector3 = Vector3(HIP_OFFSET_X * p_side, 0.40, 0.0)
	var mid_offset: Vector3 = Vector3(sin(tilt_rad), -cos(tilt_rad), 0.0) * (LEG_LEN * 0.5)
	body.position = hip_world + mid_offset
	body.transform = Transform3D(Basis().rotated(Vector3(0, 0, 1), tilt_rad), body.position)
	root.add_child(body)
	var shape := CollisionShape3D.new()
	var hull := ConvexPolygonShape3D.new()
	hull.points = _capsule_hull_points(LEG_RADIUS, LEG_LEN, HULL_AXIAL_SLICES, HULL_RADIAL_POINTS)
	shape.shape = hull
	body.add_child(shape)
	return body


# Sample points on a capsule surface (cylinder body + hemispherical caps),
# suitable for ConvexPolygonShape3D::set_points. Local frame: capsule axis
# = local +Y. Returns ~axial × radial points (with the cap rings folded in).
func _capsule_hull_points(p_radius: float, p_total_length: float,
		p_axial_slices: int, p_radial_points: int) -> PackedVector3Array:
	var pts: PackedVector3Array = PackedVector3Array()
	var cyl_len: float = p_total_length - 2.0 * p_radius
	if cyl_len < 0.0:
		cyl_len = 0.0
	var half_cyl: float = cyl_len * 0.5
	# Body cylinder: axial slices distributed along the cylinder length.
	for s in p_axial_slices:
		var t: float = float(s) / float(p_axial_slices - 1) if p_axial_slices > 1 else 0.5
		var y: float = lerp(-half_cyl, half_cyl, t)
		for r in p_radial_points:
			var phi: float = TAU * float(r) / float(p_radial_points)
			pts.append(Vector3(p_radius * cos(phi), y, p_radius * sin(phi)))
	# End caps: a few rings on each hemisphere for hull face count.
	for cap_sign in [-1.0, 1.0]:
		var cap_origin_y: float = cap_sign * half_cyl
		for ring in 3:
			var ring_t: float = float(ring + 1) / 4.0  # 0.25, 0.5, 0.75 of cap
			var ring_y: float = cap_origin_y + cap_sign * p_radius * sin(ring_t * 0.5 * PI)
			var ring_r: float = p_radius * cos(ring_t * 0.5 * PI)
			for r in p_radial_points:
				var phi: float = TAU * float(r) / float(p_radial_points)
				pts.append(Vector3(ring_r * cos(phi), ring_y, ring_r * sin(phi)))
		# Cap apex.
		pts.append(Vector3(0.0, cap_origin_y + cap_sign * p_radius, 0.0))
	return pts


func _make_joint(p_pelvis: StaticBody3D, p_leg: RigidBody3D, p_name: String) -> void:
	var joint := Generic6DOFJoint3D.new()
	joint.name = p_name
	root.add_child(joint)
	var side: float = 1.0 if p_leg.name == &"LegR" else -1.0
	joint.position = Vector3(HIP_OFFSET_X * side, 0.40, 0.0)
	joint.node_a = p_pelvis.get_path()
	joint.node_b = p_leg.get_path()

	# Lock all 3 linear axes. Param ID layout uses per-axis setters.
	joint.set_param_x(Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT, 0.0)
	joint.set_param_x(Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT, 0.0)
	joint.set_param_y(Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT, 0.0)
	joint.set_param_y(Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT, 0.0)
	joint.set_param_z(Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT, 0.0)
	joint.set_param_z(Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT, 0.0)
	joint.set_flag_x(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT, true)
	joint.set_flag_y(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT, true)
	joint.set_flag_z(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT, true)

	# Disable angular limits, enable angular springs on all 3 axes.
	joint.set_flag_x(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, false)
	joint.set_flag_y(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, false)
	joint.set_flag_z(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, false)
	joint.set_flag_x(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_SPRING, true)
	joint.set_flag_y(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_SPRING, true)
	joint.set_flag_z(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_SPRING, true)
	for ax_param in [
		Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_STIFFNESS,
		Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_DAMPING,
		Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_EQUILIBRIUM_POINT,
	]:
		var v: float = 0.0
		match ax_param:
			Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_STIFFNESS:
				v = JOINT_SPRING_STIFFNESS
			Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_DAMPING:
				v = JOINT_SPRING_DAMPING
			Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_EQUILIBRIUM_POINT:
				v = 0.0
		joint.set_param_x(ax_param, v)
		joint.set_param_y(ax_param, v)
		joint.set_param_z(ax_param, v)


func _report(p_history: Array, p_leg_history: Array, p_lubricity: float) -> void:
	var n_ticks: int = p_history.size()
	if n_ticks == 0:
		print("  no measurement window captured")
		return

	# Channel summary across all particles × slots × ticks.
	var ch_object_flips: int = 0
	var ch_normal_flips: int = 0
	var ch_point_shifts: int = 0
	var ch_lambda_osc: int = 0
	var ch_face_crossings: int = 0  # channel (vii)
	var max_dpos: float = 0.0
	var sum_dpos: float = 0.0
	var n_dpos_samples: int = 0
	# Per-tick per-particle: did slot 0 cross a face this tick?
	var face_cross_per_tick: PackedByteArray = PackedByteArray()
	face_cross_per_tick.resize(n_ticks)
	# Per-tick: did any slot's hit_point shift this tick?
	var point_shift_per_tick: PackedByteArray = PackedByteArray()
	point_shift_per_tick.resize(n_ticks)

	for pi in CHAIN_PARTICLES:
		var prev_slots_by_k: Array = [null, null]
		for tick_i in n_ticks:
			var rec: Dictionary = p_history[tick_i][pi]
			max_dpos = maxf(max_dpos, float(rec.dpos))
			sum_dpos += float(rec.dpos)
			n_dpos_samples += 1
			for k in rec.slots.size():
				var s: Dictionary = rec.slots[k]
				if prev_slots_by_k[k] != null:
					var prev: Dictionary = prev_slots_by_k[k]
					if int(prev.object_id) != int(s.object_id):
						ch_object_flips += 1
					if (Vector3(s.normal) - Vector3(prev.normal)).length() > 1e-3:
						ch_normal_flips += 1
					if (Vector3(s.point) - Vector3(prev.point)).length() > 1e-3:
						ch_point_shifts += 1
						point_shift_per_tick[tick_i] = 1
					var prev_lam: float = float(prev.normal_lambda)
					var lam: float = float(s.normal_lambda)
					var mean_lam: float = (absf(lam) + absf(prev_lam)) * 0.5
					if mean_lam > 1e-7:
						if absf(lam - prev_lam) / mean_lam > 0.01:
							ch_lambda_osc += 1
					# Channel (vii) — face-crossing detection. Use the
					# normal direction continuity test: cosθ between this
					# tick's and previous tick's normal. If both normals
					# are near-zero (slot inactive), skip.
					var n_now: Vector3 = Vector3(s.normal)
					var n_prev: Vector3 = Vector3(prev.normal)
					if n_now.length() > 0.5 and n_prev.length() > 0.5:
						var cos_th: float = n_now.dot(n_prev)
						if cos_th < SAME_FACE_COS_THRESHOLD:
							ch_face_crossings += 1
							# Mark this tick as a face-cross tick (slot 0
							# only; channel (viii) cross-correlation is
							# coarse — any slot's face-cross flags the tick).
							if k == 0:
								face_cross_per_tick[tick_i] = 1
				prev_slots_by_k[k] = s

	# Channels (v) / (vi) — leg motion summary.
	var L_pos_amp: float = _xyz_amplitude(p_leg_history, "L_pos")
	var R_pos_amp: float = _xyz_amplitude(p_leg_history, "R_pos")
	var L_ang_amp: float = _xyz_amplitude(p_leg_history, "L_ang_vel")
	var R_ang_amp: float = _xyz_amplitude(p_leg_history, "R_ang_vel")
	var L_lin_max: float = _max_magnitude(p_leg_history, "L_lin_vel")
	var R_lin_max: float = _max_magnitude(p_leg_history, "R_lin_vel")
	var L_ang_max: float = _max_magnitude(p_leg_history, "L_ang_vel")
	var R_ang_max: float = _max_magnitude(p_leg_history, "R_ang_vel")
	var zc_L: int = _count_zero_crossings(p_leg_history, "L_ang_vel", 2)
	var zc_R: int = _count_zero_crossings(p_leg_history, "R_ang_vel", 2)
	var window_sec: float = float(n_ticks) * DT
	var freq_L: float = float(zc_L) / 2.0 / window_sec
	var freq_R: float = float(zc_R) / 2.0 / window_sec

	# Channel (viii) — cross-correlation. Two correlations:
	#   A. Face crossings vs contact-point shifts.
	#   B. Face crossings vs leg-fast ticks (closer leg's |ang_vel| above
	#      its own median).
	var leg_ang_mags_L: PackedFloat32Array = PackedFloat32Array()
	var leg_ang_mags_R: PackedFloat32Array = PackedFloat32Array()
	leg_ang_mags_L.resize(n_ticks)
	leg_ang_mags_R.resize(n_ticks)
	for tick_i in n_ticks:
		leg_ang_mags_L[tick_i] = (Vector3)(p_leg_history[tick_i]["L_ang_vel"]).length()
		leg_ang_mags_R[tick_i] = (Vector3)(p_leg_history[tick_i]["R_ang_vel"]).length()
	var sorted_L: Array = leg_ang_mags_L.duplicate()
	var sorted_R: Array = leg_ang_mags_R.duplicate()
	sorted_L.sort()
	sorted_R.sort()
	var med_L: float = sorted_L[n_ticks / 2]
	var med_R: float = sorted_R[n_ticks / 2]
	var fc_with_point_shift: int = 0
	var fc_with_leg_fast: int = 0
	var fc_total: int = 0
	for tick_i in n_ticks:
		if face_cross_per_tick[tick_i] == 1:
			fc_total += 1
			if point_shift_per_tick[tick_i] == 1:
				fc_with_point_shift += 1
			var leg_mag: float = max(leg_ang_mags_L[tick_i], leg_ang_mags_R[tick_i])
			var leg_med: float = max(med_L, med_R)
			if leg_mag > leg_med:
				fc_with_leg_fast += 1

	# Phase-correlation (round-2 metric) — point shifts vs leg-fast ticks.
	var phase_match: int = 0
	var phase_total: int = 0
	for pi in CHAIN_PARTICLES:
		var prev_slots_by_k: Array = [null, null]
		for tick_i in n_ticks:
			var rec: Dictionary = p_history[tick_i][pi]
			for k in rec.slots.size():
				var s: Dictionary = rec.slots[k]
				if prev_slots_by_k[k] != null:
					var prev: Dictionary = prev_slots_by_k[k]
					if (Vector3(s.point) - Vector3(prev.point)).length() > 1e-3:
						var leg_mag: float = max(leg_ang_mags_L[tick_i], leg_ang_mags_R[tick_i])
						var leg_med: float = max(med_L, med_R)
						if leg_mag > leg_med:
							phase_match += 1
						phase_total += 1
				prev_slots_by_k[k] = s

	print("  Channels (i)–(iv):")
	print("    (i)   slot object_id flips:                                    %d" % ch_object_flips)
	print("    (ii)  hit_point shifts > 1 mm:                                  %d" % ch_point_shifts)
	print("    (iii) hit_normal flips > 1e-3:                                  %d" % ch_normal_flips)
	print("    (iv)  normal_lambda oscillation > 1%% of running mean:          %d" % ch_lambda_osc)
	print("    Worst per-tick |Δpos|:                                         %.6f m" % max_dpos)
	print("    Mean per-tick |Δpos|:                                          %.6f m"
			% (sum_dpos / float(n_dpos_samples) if n_dpos_samples > 0 else 0.0))
	print("  Channel (v)/(vi) — leg motion:")
	print("    LegL pos peak-to-peak (XYZ): %.4f m  ang_vel peak-to-peak: %.4f rad/s  ang_max: %.4f"
			% [L_pos_amp, L_ang_amp, L_ang_max])
	print("    LegR pos peak-to-peak (XYZ): %.4f m  ang_vel peak-to-peak: %.4f rad/s  ang_max: %.4f"
			% [R_pos_amp, R_ang_amp, R_ang_max])
	print("    Linear vel max: L=%.4f R=%.4f m/s" % [L_lin_max, R_lin_max])
	print("    Estimated leg oscillation freq (Z-axis zero-crossings): L=%.2f Hz R=%.2f Hz"
			% [freq_L, freq_R])
	print("  Channel (vii) — face crossings (cosθ < %.3f between successive normals):" % SAME_FACE_COS_THRESHOLD)
	print("    Face-crossing events (all slots, %d ticks):                    %d (%.1f / sec)"
			% [n_ticks, ch_face_crossings, float(ch_face_crossings) / window_sec])
	print("    Slot-0 face-cross ticks (deduplicated):                       %d / %d (%.1f%%)"
			% [fc_total, n_ticks, 100.0 * float(fc_total) / float(n_ticks)])
	print("  Channel (viii) — cross-correlation:")
	if phase_total > 0:
		var pct: float = 100.0 * float(phase_match) / float(phase_total)
		print("    Point-shift × leg-fast (round-2 metric):                     %d / %d (%.1f%%)"
				% [phase_match, phase_total, pct])
	else:
		print("    Point-shift × leg-fast (round-2 metric):                     n/a (no point shifts)")
	if fc_total > 0:
		print("    Face-cross × point-shift (same tick):                        %d / %d (%.1f%%)"
				% [fc_with_point_shift, fc_total,
					100.0 * float(fc_with_point_shift) / float(fc_total)])
		print("    Face-cross × leg-fast (above-median ang_vel):                %d / %d (%.1f%%)"
				% [fc_with_leg_fast, fc_total,
					100.0 * float(fc_with_leg_fast) / float(fc_total)])
	else:
		print("    Face-cross × point-shift / leg-fast:                         n/a (no face crossings)")


func _xyz_amplitude(p_history: Array, p_key: String) -> float:
	var min_v := Vector3(INF, INF, INF)
	var max_v := Vector3(-INF, -INF, -INF)
	for rec in p_history:
		var v: Vector3 = rec[p_key]
		min_v.x = minf(min_v.x, v.x)
		min_v.y = minf(min_v.y, v.y)
		min_v.z = minf(min_v.z, v.z)
		max_v.x = maxf(max_v.x, v.x)
		max_v.y = maxf(max_v.y, v.y)
		max_v.z = maxf(max_v.z, v.z)
	return maxf(maxf(max_v.x - min_v.x, max_v.y - min_v.y), max_v.z - min_v.z)


func _max_magnitude(p_history: Array, p_key: String) -> float:
	var m := 0.0
	for rec in p_history:
		var v: Vector3 = rec[p_key]
		m = maxf(m, v.length())
	return m


func _count_zero_crossings(p_history: Array, p_key: String, p_axis: int) -> int:
	var count := 0
	if p_history.size() < 2:
		return 0
	var prev: float = (Vector3)(p_history[0][p_key])[p_axis]
	for i in range(1, p_history.size()):
		var cur: float = (Vector3)(p_history[i][p_key])[p_axis]
		if (prev >= 0.0 and cur < 0.0) or (prev < 0.0 and cur >= 0.0):
			count += 1
		prev = cur
	return count
