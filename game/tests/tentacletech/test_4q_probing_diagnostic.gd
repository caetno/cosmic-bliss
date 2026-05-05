extends SceneTree

# Slice 4Q diagnostic — round 4. Active-probing repro under production
# config.
#
# Round 3 (Jolt + convex hull + production HIP_K/HIP_C joints + STATIC chain)
# was barely-moving — coupled-oscillation feedback was killed by the joints'
# heavy passive damping (ζ ≈ 2.67) and there was no sliding motion to drive
# face-crossings. The user's actual failure mode involves an active behaviour
# driver pushing the tip forward against contact: probing.
#
# Round 4 setup (inherits round 3's production-config baseline):
#   - Jolt physics engine (verified at start; same probe as round 3).
#   - 1 StaticBody3D PelvisAnchor, 2 RigidBody3D leg bodies (procedural
#     convex hull, 192 points each, k=2.0/c=3.5 angular springs — production
#     HIP_K/HIP_C from MarionetteSpringDefaults).
#   - Tentacle (8 particles × 5 cm) anchored at y=0.55 above the V apex.
#   - TentacleBehavior child driver, `mood` slot loaded from the bundled
#     probing.tres preset. randomize_phase_on_ready = false for deterministic
#     time-series capture.
#   - Attractor (Node3D below the V apex at y=-0.10) so the tip pulls down
#     past the leg crossing — the chain wedges between the legs and the tip
#     presses into resistance.
#
# Hypothesis: at low lubricity (high friction) the tip-target pull builds
# tangent_lambda against the static cone, eventually breaches the kinetic
# cone, snaps forward, re-locks, repeat — a classic stick-slip cycle visible
# in (xii) the tip trajectory as a sawtooth.
#
# Lubricity sweep this time: 0.0 (full friction), 0.3, 0.7, 1.0 (frictionless).
# Hypothesis says jitter is severe at low lubricity, mild at high — opposite
# of the passive case (round 2).
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_4q_probing_diagnostic.gd
#
# Channels:
#   (i)–(viii) inherited from rounds 1–3.
#   (ix)   Per-tick "target pull" estimate for the tip particle: tip-to-
#          attractor distance × pose_stiffness × attractor_bias. Standin for
#          the actual driver-internal pull (which doesn't expose a metric).
#   (x)    Per-tick tangent_lambda.length() per slot for the deepest-
#          contact particle. Stick phase: monotone growth. Slip event:
#          drop / saturation.
#   (xi)   Contact tangent velocity per tick = (pos − prev_pos) projected
#          onto the contact tangent plane. Stick: ≤ noise. Slip: spike.
#   (xii)  Tip world-position trajectory, last 240 ticks. Saw-tooth
#          analysis: count tangent-axis monotonic-then-reverse cycles.
#
# Cross-correlate (x), (xi), (xii) — should be in phase if stick-slip is real.

const DT := 1.0 / 60.0
const SETTLE_TICKS := 60
const TOTAL_TICKS := 360            # 6 s — enough for several stick-slip cycles
const MEASURE_TICKS := 240          # last 4 s as the analysis window
const CHAIN_PARTICLES := 8
const SEGMENT_LEN := 0.05
const PARTICLE_RADIUS := 0.04

const LEG_LEN := 0.4
const LEG_RADIUS := 0.05
const LEG_MASS := 4.0
# Round-3 inverted-V geometry: hips at ±0.06 (close), legs spread to ±0.26
# (wide). Chain enters from above, gets blocked at the narrow neck (y≈0.40,
# gap = 2×HIP_OFFSET_X − 2×LEG_RADIUS = 0.02 m vs chain particle radius
# 0.04 m → physically blocked). The probing tip pull tries to push the
# chain DOWN through the closed neck — that's the "tip pressing into
# contact" scenario.
const HIP_OFFSET_X := 0.06
const HULL_AXIAL_SLICES := 24
const HULL_RADIAL_POINTS := 8
const JOINT_SPRING_STIFFNESS := 2.0
const JOINT_SPRING_DAMPING := 3.5
const LEG_REST_TILT_DEG := 30.0  # outward — round-3 inverted-V default
const SAME_FACE_COS_THRESHOLD := 0.996

# Probing-equivalent mood preset (the bundled probing.tres):
#   wave_amplitude_scale = 0.4    pose_stiffness = 0.25
#   thrust_frequency = 1.5 Hz     pose_softness_when_blocked = 0.5
#   thrust_amplitude = 0.15       bending_stiffness = 0.7
#   thrust_bias = 0.2             contact_stiffness = 0.7
#   thrust_strike_sharpness = 1.5 contact_velocity_damping = 0.3
#   coil_amplitude = 0.05         attractor_bias = 0.7
#   rest_extent = 0.95            substep_count = 1 (default)
const MOOD_PRESET_PATH := "res://addons/tentacletech/scripts/presets/moods/probing.tres"


var _ran: bool = false


func _process(_delta: float) -> bool:
	if not _ran:
		_ran = true
		_run()
	return false


func _run() -> void:
	if not ClassDB.class_exists("Tentacle"):
		push_error("[FAIL] tentacletech extension not loaded")
		quit(2)
		return
	if not ClassDB.class_exists("TentacleBehavior") and not FileAccess.file_exists(
			"res://addons/tentacletech/scripts/behavior/behavior_driver.gd"):
		push_error("[FAIL] TentacleBehavior driver script missing")
		quit(2)
		return

	# Jolt verification (same probe as round 3).
	var has_jolt: bool = (
			ProjectSettings.has_setting("physics/jolt_physics_3d/simulation/velocity_steps")
			or ProjectSettings.has_setting("physics/jolt_3d/simulation/velocity_steps")
	)
	var engine_name: String = String(ProjectSettings.get_setting("physics/3d/physics_engine", ""))

	print("\n========== 4Q round-4 diagnostic — active probing under production config ==========")
	print("Physics engine setting: %s" % engine_name)
	print("Jolt module loaded:     %s" % ("yes" if has_jolt else "NO"))
	print("Topology: 1 StaticBody3D anchor + 2 RigidBody3D legs (convex hull, %d-axial × %d-radial)"
			% [HULL_AXIAL_SLICES, HULL_RADIAL_POINTS])
	print("Joint: Generic6DOFJoint3D, angular spring k=%.1f, damping=%.1f (production HIP_K/HIP_C)"
			% [JOINT_SPRING_STIFFNESS, JOINT_SPRING_DAMPING])
	print("Tentacle: %d particles × %.2fm, radius %.2fm, gravity (0, -9.8, 0)"
			% [CHAIN_PARTICLES, SEGMENT_LEN, PARTICLE_RADIUS])
	print("Driver:    TentacleBehavior, mood preset = res://.../moods/probing.tres")
	print("           (probing: thrust 1.5Hz, attractor_bias 0.7, contact_stiffness 0.7,")
	print("            pose_stiffness 0.25, pose_softness_when_blocked 0.5)")
	print("Attractor: world pos (0, -0.10, 0) — below the V apex so tip presses INTO wedge")
	print("Per run:   %d settle + %d ticks (%d × DT measurement window)"
			% [SETTLE_TICKS, TOTAL_TICKS, MEASURE_TICKS])
	print()

	for lub in [0.0, 0.3, 0.7, 1.0]:
		print("---------- lubricity = %.1f ----------" % lub)
		await _run_one(lub)
		print()
	quit(0)


func _run_one(p_lubricity: float) -> void:
	for c in root.get_children():
		root.remove_child(c)
		c.free()

	# 1. Pelvis anchor.
	var pelvis := StaticBody3D.new()
	pelvis.name = "PelvisAnchor"
	pelvis.position = Vector3(0.0, 0.40, 0.0)
	root.add_child(pelvis)

	# 2. Legs.
	var leg_l: RigidBody3D = _make_leg("LegL", -1.0)
	var leg_r: RigidBody3D = _make_leg("LegR", +1.0)

	# 3. Joints.
	_make_joint(pelvis, leg_l, "JointL")
	_make_joint(pelvis, leg_r, "JointR")

	# 4. Attractor — the target the probing driver pulls the tip toward.
	#    Below the wedge so the tip has to push INTO the legs to reach.
	var attractor := Node3D.new()
	attractor.name = "Attractor"
	attractor.position = Vector3(0.0, -0.10, 0.0)
	root.add_child(attractor)

	# 5. Tentacle.
	var t: Node3D = ClassDB.instantiate("Tentacle")
	t.particle_count = CHAIN_PARTICLES
	t.segment_length = SEGMENT_LEN
	t.particle_collision_radius = PARTICLE_RADIUS
	t.gravity = Vector3(0, -9.8, 0)
	t.environment_probe_distance = 5.0
	t.tentacle_lubricity = p_lubricity
	t.base_static_friction = 0.4
	t.position = Vector3(0.0, 0.55, 0.0)
	t.name = "ProbeTentacle"
	root.add_child(t)

	# 6. Behavior driver — child of tentacle (per process-order requirement).
	var DriverScript := load(
			"res://addons/tentacletech/scripts/behavior/behavior_driver.gd")
	var driver: Node3D = DriverScript.new()
	driver.name = "Driver"
	driver.tentacle_path = NodePath("..")
	driver.attractor_path = NodePath("../../Attractor")
	driver.randomize_phase_on_ready = false
	# Load the bundled probing mood preset; mood setter copies its 17 fields
	# onto the driver's @exports + connects the changed signal for hot
	# reload. All probing knobs (thrust 1.5Hz, attractor_bias 0.7,
	# contact_stiffness 0.7, pose_stiffness 0.25, etc.) come from this.
	var mood_res: Resource = load(MOOD_PRESET_PATH)
	if mood_res == null:
		push_error("[FAIL] could not load probing mood preset at %s" % MOOD_PRESET_PATH)
		return
	driver.mood = mood_res
	# rest_direction is NOT in TentacleMood — driver default is -Z, but we
	# want the chain to descend STRAIGHT DOWN into the wedge so it actually
	# enters the leg-narrowed neck. Override after mood assignment.
	driver.rest_direction = Vector3(0.0, -1.0, 0.0)
	t.add_child(driver)

	# History buffers.
	var history: Array = []
	var leg_history: Array = []
	var prev_positions: PackedVector3Array = PackedVector3Array()
	prev_positions.resize(CHAIN_PARTICLES)
	var tip_traj: PackedVector3Array = PackedVector3Array()  # channel (xii)

	# Settle physics (legs equilibrate, driver phases settle into a few
	# thrust cycles before measurement starts).
	for _i in SETTLE_TICKS:
		await physics_frame
	# Initialize prev_positions snapshot from settled state.
	var settled_positions: PackedVector3Array = t.get_particle_positions()
	for pi in CHAIN_PARTICLES:
		prev_positions[pi] = settled_positions[pi]

	for tick in TOTAL_TICKS:
		await physics_frame  # one Jolt step per loop iteration; legs integrate
		var before_positions: PackedVector3Array = t.get_particle_positions().duplicate()
		t.tick(DT)
		var after_positions: PackedVector3Array = t.get_particle_positions()
		if tick < TOTAL_TICKS - MEASURE_TICKS:
			# Update prev_positions even during settle window so the first
			# measurement tick has a valid prev sample.
			for pi in CHAIN_PARTICLES:
				prev_positions[pi] = after_positions[pi]
			continue
		var probe_snap: Array = t.get_environment_contacts_snapshot()
		var solver: Object = t.get_solver()
		var nlambdas: PackedFloat32Array = solver.get_environment_normal_lambdas_snapshot()
		var tlambdas: PackedVector3Array = solver.get_environment_tangent_lambdas_snapshot()
		var tip_idx: int = CHAIN_PARTICLES - 1
		var tip_pos: Vector3 = after_positions[tip_idx]
		tip_traj.append(tip_pos)
		# Find the deepest-contact particle this tick (max normal_lambda).
		var deepest_pi: int = -1
		var deepest_k: int = 0
		var deepest_lambda: float = 0.0
		for pi in CHAIN_PARTICLES:
			for k in 2:
				var idx: int = pi * 2 + k
				if idx < nlambdas.size():
					var lam: float = nlambdas[idx]
					if lam > deepest_lambda:
						deepest_lambda = lam
						deepest_pi = pi
						deepest_k = k
		# Channel (ix) — tip target pull standin: distance from tip to
		# attractor × stiffness × bias × s_norm_at_tip(=1).
		# probing's pose_stiffness=0.25, attractor_bias=0.7.
		var pull_distance: float = (attractor.global_position - tip_pos).length()
		var pull_metric: float = pull_distance * 0.25 * 0.7
		# Channel (xi) — tangent velocity of the deepest-contact particle.
		# (pos − prev_pos) − ((pos − prev_pos) · n) n.
		var tangent_vel: Vector3 = Vector3.ZERO
		var tangent_vel_mag: float = 0.0
		var tangent_lambda_vec: Vector3 = Vector3.ZERO
		var contact_normal: Vector3 = Vector3.ZERO
		if deepest_pi >= 0 and deepest_pi < probe_snap.size():
			var ps: Dictionary = probe_snap[deepest_pi]
			var contacts: Array = ps.get("contacts", [])
			if deepest_k < contacts.size():
				var slot: Dictionary = contacts[deepest_k]
				contact_normal = Vector3(slot.get("hit_normal", Vector3.ZERO))
				if contact_normal.length() > 0.5:
					var dx: Vector3 = after_positions[deepest_pi] - prev_positions[deepest_pi]
					tangent_vel = dx - dx.dot(contact_normal) * contact_normal
					tangent_vel_mag = tangent_vel.length()
				var tl_idx: int = deepest_pi * 2 + deepest_k
				if tl_idx < tlambdas.size():
					tangent_lambda_vec = tlambdas[tl_idx]
		# Per-particle slot dump for channels (i)–(iv), (vii).
		var per_particle: Array = []
		for pi in CHAIN_PARTICLES:
			var rec: Dictionary = {
				"particle": pi,
				"position": after_positions[pi],
				"dpos": (after_positions[pi] - before_positions[pi]).length(),
				"slots": [],
			}
			if pi < probe_snap.size():
				var ps2: Dictionary = probe_snap[pi]
				var contacts2: Array = ps2.get("contacts", [])
				for k in contacts2.size():
					var slot2: Dictionary = contacts2[k]
					var nl: float = 0.0
					var tl: Vector3 = Vector3.ZERO
					var lam_idx: int = pi * 2 + k
					if lam_idx < nlambdas.size():
						nl = nlambdas[lam_idx]
					if lam_idx < tlambdas.size():
						tl = tlambdas[lam_idx]
					rec.slots.append({
						"k": k,
						"object_id": slot2.get("hit_object_id", 0),
						"point": slot2.get("hit_point", Vector3.ZERO),
						"normal": slot2.get("hit_normal", Vector3.ZERO),
						"depth": slot2.get("hit_depth", 0.0),
						"normal_lambda": nl,
						"tangent_lambda": tl,
					})
			per_particle.append(rec)
		history.append({
			"per_particle": per_particle,
			"deepest_pi": deepest_pi,
			"deepest_k": deepest_k,
			"deepest_lambda": deepest_lambda,
			"pull_distance": pull_distance,
			"pull_metric": pull_metric,
			"tangent_vel_mag": tangent_vel_mag,
			"tangent_lambda_mag": tangent_lambda_vec.length(),
			"tip_pos": tip_pos,
			"contact_normal": contact_normal,
		})
		leg_history.append({
			"L_pos": leg_l.global_position,
			"L_lin_vel": leg_l.linear_velocity,
			"L_ang_vel": leg_l.angular_velocity,
			"R_pos": leg_r.global_position,
			"R_lin_vel": leg_r.linear_velocity,
			"R_ang_vel": leg_r.angular_velocity,
		})
		# Update prev for next tick.
		for pi in CHAIN_PARTICLES:
			prev_positions[pi] = after_positions[pi]

	_report(history, leg_history, tip_traj, p_lubricity)


func _make_leg(p_name: String, p_side: float) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = p_name
	body.mass = LEG_MASS
	body.gravity_scale = 1.0
	body.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.angular_damp = 0.0
	body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.linear_damp = 0.0
	# Outward tilt (round-3 inverted-V): left leg (-X hip) tilts toward
	# -X, right leg (+X hip) tilts toward +X. Legs spread.
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


func _capsule_hull_points(p_radius: float, p_total_length: float,
		p_axial_slices: int, p_radial_points: int) -> PackedVector3Array:
	var pts: PackedVector3Array = PackedVector3Array()
	var cyl_len: float = p_total_length - 2.0 * p_radius
	if cyl_len < 0.0:
		cyl_len = 0.0
	var half_cyl: float = cyl_len * 0.5
	for s in p_axial_slices:
		var t: float = float(s) / float(p_axial_slices - 1) if p_axial_slices > 1 else 0.5
		var y: float = lerp(-half_cyl, half_cyl, t)
		for r in p_radial_points:
			var phi: float = TAU * float(r) / float(p_radial_points)
			pts.append(Vector3(p_radius * cos(phi), y, p_radius * sin(phi)))
	for cap_sign in [-1.0, 1.0]:
		var cap_origin_y: float = cap_sign * half_cyl
		for ring in 3:
			var ring_t: float = float(ring + 1) / 4.0
			var ring_y: float = cap_origin_y + cap_sign * p_radius * sin(ring_t * 0.5 * PI)
			var ring_r: float = p_radius * cos(ring_t * 0.5 * PI)
			for r in p_radial_points:
				var phi: float = TAU * float(r) / float(p_radial_points)
				pts.append(Vector3(ring_r * cos(phi), ring_y, ring_r * sin(phi)))
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
	for axis_setter in [
		Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT,
		Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT,
	]:
		joint.set_param_x(axis_setter, 0.0)
		joint.set_param_y(axis_setter, 0.0)
		joint.set_param_z(axis_setter, 0.0)
	joint.set_flag_x(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT, true)
	joint.set_flag_y(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT, true)
	joint.set_flag_z(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT, true)
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


func _report(p_history: Array, p_leg_history: Array,
		p_tip_traj: PackedVector3Array, p_lubricity: float) -> void:
	var n_ticks: int = p_history.size()
	if n_ticks == 0:
		print("  no measurement window captured")
		return

	# Channels (i)–(iv) — same metric as round 3.
	var ch_object_flips: int = 0
	var ch_normal_flips: int = 0
	var ch_point_shifts: int = 0
	var ch_lambda_osc: int = 0
	var ch_face_crossings: int = 0
	var max_dpos: float = 0.0
	var sum_dpos: float = 0.0
	var n_dpos_samples: int = 0
	for pi in CHAIN_PARTICLES:
		var prev_slots_by_k: Array = [null, null]
		for tick_i in n_ticks:
			var rec: Dictionary = p_history[tick_i]["per_particle"][pi]
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
					var prev_lam: float = float(prev.normal_lambda)
					var lam: float = float(s.normal_lambda)
					var mean_lam: float = (absf(lam) + absf(prev_lam)) * 0.5
					if mean_lam > 1e-7 and absf(lam - prev_lam) / mean_lam > 0.01:
						ch_lambda_osc += 1
					var n_now: Vector3 = Vector3(s.normal)
					var n_prev: Vector3 = Vector3(prev.normal)
					if n_now.length() > 0.5 and n_prev.length() > 0.5:
						var cos_th: float = n_now.dot(n_prev)
						if cos_th < SAME_FACE_COS_THRESHOLD:
							ch_face_crossings += 1
				prev_slots_by_k[k] = s

	# Channels (v)/(vi) — leg motion summary.
	var L_ang_max: float = _max_magnitude(p_leg_history, "L_ang_vel")
	var R_ang_max: float = _max_magnitude(p_leg_history, "R_ang_vel")
	var L_pos_amp: float = _xyz_amplitude(p_leg_history, "L_pos")
	var R_pos_amp: float = _xyz_amplitude(p_leg_history, "R_pos")

	# Channel (ix) — tip pull.
	var pull_min: float = INF
	var pull_max: float = -INF
	var pull_sum: float = 0.0
	for tick_i in n_ticks:
		var pm: float = float(p_history[tick_i]["pull_metric"])
		pull_min = minf(pull_min, pm)
		pull_max = maxf(pull_max, pm)
		pull_sum += pm
	var pull_mean: float = pull_sum / float(n_ticks)

	# Channel (x) — tangent_lambda magnitude time-series; detect saturation
	# events (drops > 50% of running max).
	var tlam_max: float = 0.0
	var tlam_mean: float = 0.0
	var saturation_events: int = 0
	var prev_tlam: float = 0.0
	for tick_i in n_ticks:
		var tlm: float = float(p_history[tick_i]["tangent_lambda_mag"])
		tlam_max = maxf(tlam_max, tlm)
		tlam_mean += tlm
		# Saturation event: large drop after monotone growth.
		if prev_tlam > 1e-5 and tlm < 0.5 * prev_tlam and prev_tlam > 0.5 * tlam_max:
			saturation_events += 1
		prev_tlam = tlm
	tlam_mean /= float(n_ticks)

	# Channel (xi) — contact tangent velocity. Stick-slip signature: low
	# magnitude many ticks, then spike.
	var tvel_max: float = 0.0
	var tvel_mean: float = 0.0
	var tvel_spike_events: int = 0
	var tvel_history: PackedFloat32Array = PackedFloat32Array()
	tvel_history.resize(n_ticks)
	for tick_i in n_ticks:
		var tv: float = float(p_history[tick_i]["tangent_vel_mag"])
		tvel_history[tick_i] = tv
		tvel_max = maxf(tvel_max, tv)
		tvel_mean += tv
	tvel_mean /= float(n_ticks)
	# A spike is a tick whose tangent velocity is > 5× the running mean
	# AND > 3× the previous tick.
	for tick_i in range(1, n_ticks):
		var tv: float = tvel_history[tick_i]
		var tv_prev: float = tvel_history[tick_i - 1]
		if tvel_mean > 1e-7 and tv > 5.0 * tvel_mean and tv > 3.0 * tv_prev:
			tvel_spike_events += 1

	# Channel (xii) — tip trajectory sawtooth analysis.
	# Project tip motion onto the dominant tangent direction (PCA-lite:
	# axis with largest variance among XYZ on the trajectory). Then count
	# direction reversals — a sawtooth has many.
	var sawtooth_metrics: Dictionary = _sawtooth_analysis(p_tip_traj)

	# Cross-correlation: are tangent_lambda saturation events, tangent
	# velocity spikes, and tip-trajectory direction reversals coincident?
	var sat_tick_set: PackedByteArray = PackedByteArray()
	sat_tick_set.resize(n_ticks)
	var spike_tick_set: PackedByteArray = PackedByteArray()
	spike_tick_set.resize(n_ticks)
	var prev_tlam2: float = 0.0
	for tick_i in n_ticks:
		var tlm: float = float(p_history[tick_i]["tangent_lambda_mag"])
		if prev_tlam2 > 1e-5 and tlm < 0.5 * prev_tlam2 and prev_tlam2 > 0.5 * tlam_max:
			sat_tick_set[tick_i] = 1
		prev_tlam2 = tlm
		var tv: float = tvel_history[tick_i]
		if tick_i > 0 and tvel_mean > 1e-7 and tv > 5.0 * tvel_mean \
				and tv > 3.0 * tvel_history[tick_i - 1]:
			spike_tick_set[tick_i] = 1
	var coincident_sat_spike: int = 0
	for tick_i in n_ticks:
		if sat_tick_set[tick_i] == 1 and spike_tick_set[tick_i] == 1:
			coincident_sat_spike += 1

	# Print.
	print("  Channels (i)–(iv):")
	print("    (i)   slot object_id flips:                  %d" % ch_object_flips)
	print("    (ii)  hit_point shifts > 1 mm:                %d" % ch_point_shifts)
	print("    (iii) hit_normal flips > 1e-3:                %d" % ch_normal_flips)
	print("    (iv)  normal_lambda osc > 1%% of running mean:%d" % ch_lambda_osc)
	print("    Worst per-tick |Δpos|:                       %.6f m" % max_dpos)
	print("    Mean per-tick |Δpos|:                        %.6f m"
			% (sum_dpos / float(n_dpos_samples) if n_dpos_samples > 0 else 0.0))
	print("  Channel (v)/(vi) — leg motion:")
	print("    LegL pos peak-to-peak: %.4f m  ang_max: %.4f rad/s" % [L_pos_amp, L_ang_max])
	print("    LegR pos peak-to-peak: %.4f m  ang_max: %.4f rad/s" % [R_pos_amp, R_ang_max])
	print("  Channel (vii) — face crossings: %d events (%.1f / sec)"
			% [ch_face_crossings, float(ch_face_crossings) / (float(n_ticks) * DT)])
	print("  Channel (ix) — tip pull (tip-to-attractor distance × 0.25 × 0.7 standin):")
	print("    min %.4f, mean %.4f, max %.4f m·×stiff·×bias" % [pull_min, pull_mean, pull_max])
	print("  Channel (x) — tangent_lambda magnitude (deepest-contact slot, per tick):")
	print("    max %.6f, mean %.6f" % [tlam_max, tlam_mean])
	print("    saturation events (>50%% drop after near-max): %d (%.2f / sec)"
			% [saturation_events, float(saturation_events) / (float(n_ticks) * DT)])
	print("  Channel (xi) — contact tangent velocity (deepest-contact particle):")
	print("    max %.6f, mean %.6f m/tick" % [tvel_max, tvel_mean])
	print("    spike events (>5× mean AND >3× prev tick): %d (%.2f / sec)"
			% [tvel_spike_events, float(tvel_spike_events) / (float(n_ticks) * DT)])
	print("  Channel (xii) — tip trajectory sawtooth (last %d ticks):" % p_tip_traj.size())
	print("    dominant axis: %s, variance: %.6f" % [
			sawtooth_metrics["dominant_axis"], sawtooth_metrics["dominant_variance"]])
	print("    direction reversals along dominant axis: %d (%.2f Hz est)" % [
			sawtooth_metrics["reversals"],
			float(sawtooth_metrics["reversals"]) / 2.0
					/ (float(p_tip_traj.size()) * DT)])
	print("    range (peak-to-peak) along dominant axis:  %.6f m" %
			sawtooth_metrics["dominant_range"])
	print("    asymmetry (mean dwell ÷ mean travel) — >1 = stick-slip:  %.2f" %
			sawtooth_metrics["asymmetry"])
	print("  Channel (viii) — cross-correlation:")
	print("    saturation × spike (same tick):   %d / %d / %d sat / spike / coincident"
			% [saturation_events, tvel_spike_events, coincident_sat_spike])
	if saturation_events > 0:
		var pct: float = 100.0 * float(coincident_sat_spike) / float(saturation_events)
		print("    of saturation events, %.1f%% had a same-tick tangent-vel spike"
				% pct)


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


# Trajectory sawtooth analysis. Returns:
#   dominant_axis (String): "x" / "y" / "z" — axis with largest variance.
#   dominant_variance (float)
#   dominant_range (float): peak-to-peak along dominant axis
#   reversals (int): direction changes along dominant axis (N-1 of)
#   asymmetry (float): ratio of mean dwell-time vs mean travel-step. A
#       sinusoid asymmetry ≈ 1.0; clean stick-slip has asymmetry > 2 (long
#       stick + short slip). Smoothed motion approaches 1.0.
func _sawtooth_analysis(p_traj: PackedVector3Array) -> Dictionary:
	var n: int = p_traj.size()
	if n < 4:
		return {"dominant_axis": "n/a", "dominant_variance": 0.0,
				"dominant_range": 0.0, "reversals": 0, "asymmetry": 1.0}
	var sum := Vector3.ZERO
	for v in p_traj:
		sum += v
	var mean: Vector3 = sum / float(n)
	var var_v := Vector3.ZERO
	var min_v := Vector3(INF, INF, INF)
	var max_v := Vector3(-INF, -INF, -INF)
	for v in p_traj:
		var d: Vector3 = v - mean
		var_v += Vector3(d.x * d.x, d.y * d.y, d.z * d.z)
		min_v.x = minf(min_v.x, v.x)
		min_v.y = minf(min_v.y, v.y)
		min_v.z = minf(min_v.z, v.z)
		max_v.x = maxf(max_v.x, v.x)
		max_v.y = maxf(max_v.y, v.y)
		max_v.z = maxf(max_v.z, v.z)
	var_v /= float(n)
	# Pick dominant axis.
	var dom_axis: String = "x"
	var dom_var: float = var_v.x
	var dom_range: float = max_v.x - min_v.x
	if var_v.y > dom_var:
		dom_axis = "y"
		dom_var = var_v.y
		dom_range = max_v.y - min_v.y
	if var_v.z > dom_var:
		dom_axis = "z"
		dom_var = var_v.z
		dom_range = max_v.z - min_v.z
	# Reversals + asymmetry along dominant axis.
	var samples: PackedFloat32Array = PackedFloat32Array()
	samples.resize(n)
	for i in n:
		match dom_axis:
			"x": samples[i] = p_traj[i].x
			"y": samples[i] = p_traj[i].y
			"z": samples[i] = p_traj[i].z
	# First derivative sign.
	var reversals: int = 0
	var prev_sign: int = 0
	var run_lengths: PackedInt32Array = PackedInt32Array()
	var run: int = 0
	var run_steps: PackedFloat32Array = PackedFloat32Array()
	var step_sum: float = 0.0
	for i in range(1, n):
		var dx: float = samples[i] - samples[i - 1]
		# Treat sub-noise diffs as zero (don't count microscopic reversals).
		if absf(dx) < 1e-6:
			# accumulate as a "dwell".
			run += 1
			continue
		var sgn: int = 1 if dx > 0.0 else -1
		if prev_sign != 0 and sgn != prev_sign:
			reversals += 1
			run_lengths.append(run)
			run = 0
		prev_sign = sgn
		run += 1
		step_sum += absf(dx)
	# Asymmetry: average run length × DT vs average step magnitude. Long
	# runs at low step rate = stick. Many small runs at high rate = slip.
	# We use mean-run-length / total-runs as a proxy for stickiness.
	var mean_run: float = 0.0
	if run_lengths.size() > 0:
		var sum_runs: int = 0
		for rl in run_lengths:
			sum_runs += rl
		mean_run = float(sum_runs) / float(run_lengths.size())
	# Rough asymmetry: longer dwell runs vs more-steps-per-second sawtooth
	# baseline of n/(reversals+1).
	var asymmetry: float = 1.0
	if reversals > 0:
		var baseline_run: float = float(n) / float(reversals + 1)
		asymmetry = mean_run / baseline_run if baseline_run > 1e-3 else 1.0
	return {
		"dominant_axis": dom_axis,
		"dominant_variance": dom_var,
		"dominant_range": dom_range,
		"reversals": reversals,
		"asymmetry": asymmetry,
	}
