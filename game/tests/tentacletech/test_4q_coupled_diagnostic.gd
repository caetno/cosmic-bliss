extends SceneTree

# Slice 4Q diagnostic — round 2. Coupled-body geometry.
#
# Round-1 used static box colliders and showed channels (i)–(iii) clean,
# only sub-2-mm position drift. The user clarified: the failure scene
# has MOVING ragdoll bones (PhysicalBone3D in production; here we stand
# in with RigidBody3D + Generic6DOFJoint3D), so the contact surface
# itself moves under the tentacle's reciprocal impulse, the next PBD
# probe sees a moved surface, etc. — coupled oscillation. The static
# repro removed exactly this loop.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_4q_coupled_diagnostic.gd
#
# Topology:
#   - 1 StaticBody3D "pelvis_anchor" (joint root; no shape).
#   - 2 RigidBody3D "leg" boxes hanging at ±30° from vertical, joint-
#     coupled to pelvis_anchor via Generic6DOFJoint3D with angular
#     springs (stiffness 50, damping 5 — see RIGIDBODY_TUNING below for
#     rationale + divergence notes).
#   - Tentacle anchored above the wedge apex, gravity on, frictionless
#     by default (lubricity = 1.0); tip dangles between the legs.
#
# Per tick logs:
#   Channels (i)–(iv): same as round 1.
#   (v) Per-leg world position + linear velocity.
#   (vi) Per-leg angular velocity.
# Cross-correlate by checking whether (ii)/(iii) churn frequency tracks
# the leg's angular oscillation frequency.
#
# No fix code — diagnostic only. Acceptance per slice prompt: this
# script committed (test-only, simple), logs reported, hold for review.

const DT := 1.0 / 60.0
const TOTAL_TICKS := 180          # 3 s — enough to see joint oscillation
const MEASURE_TICKS := 120        # last 2 s as the analysis window
const CHAIN_PARTICLES := 4
const SEGMENT_LEN := 0.05
const PARTICLE_RADIUS := 0.04

# Leg body geometry. Boxes (not capsules) for simplicity — matches the
# round-1 static repro. Note in the report that real Kasumi legs are
# capsules; box-vs-capsule could change contact-point-on-edge behavior.
const LEG_LEN := 0.4              # m
const LEG_THICK := 0.10           # m (cross-section)
const LEG_MASS := 5.0             # kg
const HIP_OFFSET_X := 0.06        # m, half hip-width

# Joint tuning. Spring stiffness 50 / damping 5 per the slice prompt's
# suggestion. Rough natural frequency:
#   I_leg ≈ (1/3) m L² = (1/3)(5)(0.4)² = 0.267 kg·m²
#   ω = √(k/I) = √(50 / 0.267) ≈ 13.7 rad/s ≈ 2.2 Hz
# So ~3 oscillation cycles in our 2-s measurement window — observable.
const JOINT_SPRING_STIFFNESS := 50.0
const JOINT_SPRING_DAMPING := 5.0

# Wedge geometry — leg rotated 30° outward from vertical at rest.
const LEG_REST_TILT_DEG := 30.0


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

	print("\n========== 4Q round-2 diagnostic — coupled-body wedge ==========")
	print("Topology: 1 StaticBody3D anchor + 2 RigidBody3D legs (box, %.2fm × %.2fm × %.2fm, %.1fkg each)"
			% [LEG_LEN, LEG_THICK, LEG_THICK, LEG_MASS])
	print("Joint: Generic6DOFJoint3D, angular spring k=%.1f, damping=%.1f → ω₀≈%.1f rad/s ≈ %.1f Hz"
			% [JOINT_SPRING_STIFFNESS, JOINT_SPRING_DAMPING,
				sqrt(JOINT_SPRING_STIFFNESS / ((1.0 / 3.0) * LEG_MASS * LEG_LEN * LEG_LEN)),
				sqrt(JOINT_SPRING_STIFFNESS / ((1.0 / 3.0) * LEG_MASS * LEG_LEN * LEG_LEN)) / TAU])
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

	# 2. Legs (RigidBody3D × 2). Each leg is a box hanging from the
	# pelvis at LEG_REST_TILT_DEG outward from vertical.
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
	# Anchor far above the legs so the chain falls all the way down
	# between them. With 4 particles × 5 cm = 15 cm chain, anchor at
	# y = 0.55 puts the tip near y = 0.40 — at the pelvis level. Legs
	# tilted ±30° from vertical span y = 0.40 → 0.06; the tip dangles
	# between the upper portions of the legs.
	t.position = Vector3(0.0, 0.55, 0.0)
	t.name = "WedgeTentacle"
	root.add_child(t)

	# History storage. Per-tick: full per-particle slot data + per-leg
	# pose/velocity. We keep only the steady-state window.
	var history: Array = []
	var leg_history: Array = []

	# Let physics settle the legs at rest first (gravity + spring) BEFORE
	# the tentacle starts ticking, so we measure deflection driven by
	# tentacle reciprocals — not the legs' transient settle from spawn.
	for _i in 60:
		await physics_frame

	for tick in TOTAL_TICKS:
		# Step physics first; this gives RigidBody3D the chance to
		# integrate any impulses applied by the previous PBD tick. With
		# `--script` SceneTree mode, the engine still drives physics
		# between awaits, so we get one physics step per loop iteration.
		await physics_frame
		var before: PackedVector3Array = t.get_particle_positions().duplicate()
		t.tick(DT)
		var after: PackedVector3Array = t.get_particle_positions()
		if tick < TOTAL_TICKS - MEASURE_TICKS:
			continue
		# Channels (i)–(iv) — reuse the round-1 capture.
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
		# Channels (v)/(vi) — per-leg pose/velocity.
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
	body.angular_damp = 0.0  # damping comes from the joint spring
	body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.linear_damp = 0.0
	# Position: hip at (±HIP_OFFSET_X, 0.40, 0); leg extends downward
	# tilted LEG_REST_TILT_DEG outward. The body's CoM is at the leg
	# midpoint.
	var tilt_rad: float = deg_to_rad(LEG_REST_TILT_DEG) * p_side
	# From hip, mid-leg is along (sin(tilt), -cos(tilt), 0) × (LEG_LEN/2).
	var hip_world: Vector3 = Vector3(HIP_OFFSET_X * p_side, 0.40, 0.0)
	var mid_offset: Vector3 = Vector3(sin(tilt_rad), -cos(tilt_rad), 0.0) * (LEG_LEN * 0.5)
	body.position = hip_world + mid_offset
	# Rotate so the box's local +Y is along the leg axis (hip → foot
	# direction is local -Y). Tilt around Z.
	body.transform = Transform3D(Basis().rotated(Vector3(0, 0, 1), tilt_rad), body.position)
	root.add_child(body)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(LEG_THICK, LEG_LEN, LEG_THICK)
	shape.shape = box
	body.add_child(shape)
	return body


func _make_joint(p_pelvis: StaticBody3D, p_leg: RigidBody3D, p_name: String) -> void:
	# The joint sits at the leg's hip (top end of the leg in its local
	# frame — local +Y direction by half_len from CoM).
	var joint := Generic6DOFJoint3D.new()
	joint.name = p_name
	root.add_child(joint)
	# Position joint at leg's hip-end world position. Easier: use
	# pelvis_position + side offset (since the leg's hip IS at the
	# pelvis level already).
	var side: float = 1.0 if p_leg.name == &"LegR" else -1.0
	joint.position = Vector3(HIP_OFFSET_X * side, 0.40, 0.0)
	joint.node_a = p_pelvis.get_path()
	joint.node_b = p_leg.get_path()

	# Lock all 3 linear axes (joint as a hip pivot, not a sliding rail).
	for axis in 3:
		# Tight linear limits ≈ rigid linear lock.
		joint.set_param_x(Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT, 0.0) if axis == 0 else null
		joint.set_param_y(Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT, 0.0) if axis == 1 else null
		joint.set_param_z(Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT, 0.0) if axis == 2 else null
		joint.set_param_x(Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT, 0.0) if axis == 0 else null
		joint.set_param_y(Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT, 0.0) if axis == 1 else null
		joint.set_param_z(Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT, 0.0) if axis == 2 else null
	joint.set_flag_x(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT, true)
	joint.set_flag_y(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT, true)
	joint.set_flag_z(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT, true)

	# Disable angular limits (free swing). Enable angular springs on
	# all 3 axes — equilibrium = 0 (rest pose), stiffness/damping per
	# the constants.
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

	# Channel summary (worst across all particles × slots × ticks).
	var ch_object_flips: int = 0
	var ch_normal_flips: int = 0
	var ch_point_shifts: int = 0
	var ch_lambda_osc: int = 0
	var max_dpos: float = 0.0
	var sum_dpos: float = 0.0
	var n_dpos_samples: int = 0
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
					var prev_lam: float = float(prev.normal_lambda)
					var lam: float = float(s.normal_lambda)
					var mean_lam: float = (absf(lam) + absf(prev_lam)) * 0.5
					if mean_lam > 1e-7:
						if absf(lam - prev_lam) / mean_lam > 0.01:
							ch_lambda_osc += 1
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

	# Frequency estimate: count zero-crossings of leg's Z-axis angular
	# velocity (the wedge axis), divide by 2 / window-time = Hz.
	var zc_L: int = _count_zero_crossings(p_leg_history, "L_ang_vel", 2)
	var zc_R: int = _count_zero_crossings(p_leg_history, "R_ang_vel", 2)
	var window_sec: float = float(n_ticks) * DT
	var freq_L: float = float(zc_L) / 2.0 / window_sec
	var freq_R: float = float(zc_R) / 2.0 / window_sec

	# Phase correlation: do contact-point/normal shifts cluster around
	# leg-velocity peaks? Crude metric: count ticks where (a) any slot's
	# point shifted >1mm AND (b) the closer leg's |angular_velocity| is
	# above its own median. If the coupled-oscillation hypothesis is
	# right, the count is high (>50% of point-shift events). If random,
	# closer to 50% by chance.
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
						# Point shifted; is the closer leg moving fast?
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
	if phase_total > 0:
		var pct: float = 100.0 * float(phase_match) / float(phase_total)
		print("  Phase-correlation: %d / %d (%.1f%%) point-shift events occurred during leg-fast (above-median) ticks"
				% [phase_match, phase_total, pct])
	else:
		print("  Phase-correlation: no point-shift events to correlate")


func _xyz_amplitude(p_history: Array, p_key: String) -> float:
	# Peak-to-peak across XYZ, taking max axis-amplitude.
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
