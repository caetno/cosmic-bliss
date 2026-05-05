extends SceneTree

# Slice 4Q diagnostic — wedge + sliding contact stability.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_4q_wedge_diagnostic.gd
#
# Goal: characterize the unstable channels at a frictionless V-wedge
# steady state. Per the slice prompt, identify which of:
#   (i)   slot RID/object_id flipping between bodies,
#   (ii)  hit_point shifting within a single body,
#   (iii) hit_normal flipping at a face/edge boundary,
#   (iv)  normal_lambda magnitude oscillating tick-to-tick,
# are unstable for a particle that should be at rest.
#
# Setup: two large StaticBody3D box colliders rotated ±30° around Z to
# form a V opening upward. A 4-particle tentacle anchored above falls
# into the V. With lubricity = 1.0 (frictionless), the only thing
# keeping the particle at the bottom of the V is geometric: both
# inward-pointing normals add up to support gravity. The particle
# SHOULD settle at a stable equilibrium near the apex.
#
# Diagnostic, not pass/fail: dumps a structured report at the end.
# The user / top-level Claude reads the report and decides which fix
# shape from Step 2 of the slice prompt to apply.

const DT := 1.0 / 60.0
# Total ticks: 60 settling + 60 measurement (last 60 are the
# steady-state window the diagnostic analyzes).
const TOTAL_TICKS := 120
const MEASURE_TICKS := 60
# Chain geometry.
const CHAIN_PARTICLES := 4
const SEGMENT_LEN := 0.05
const PARTICLE_RADIUS := 0.04
# Wedge geometry.
const WEDGE_APEX := Vector3(0.0, 0.0, 0.0)
const WEDGE_TILT_DEG := 30.0  # ramp angle from horizontal
const BOX_HALF_LEN := 0.6     # half-length of each ramp
const BOX_HALF_THICK := 0.2   # half-thickness of each ramp


var _ran: bool = false


func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_run_diagnostic()
	return true


func _run_diagnostic() -> void:
	if not ClassDB.class_exists("Tentacle"):
		push_error("[FAIL] tentacletech extension not loaded")
		quit(2)
		return

	# Run the same scenario at multiple lubricity settings to validate the
	# user's "jitter scales with lubricity" claim. The PRIMARY pass is
	# lubricity = 1.0 (frictionless = worst case); the comparison passes
	# (lubricity 0.5 and 0.0) confirm the trend without mutating the
	# primary report.
	print("\n========== 4Q diagnostic (primary run: lubricity 1.0) ==========\n")
	_run_one_configuration(1.0, true)
	print("\n========== 4Q diagnostic (comparison: lubricity 0.5) ==========\n")
	_run_one_configuration(0.5, false)
	print("\n========== 4Q diagnostic (comparison: lubricity 0.0) ==========\n")
	_run_one_configuration(0.0, false)
	quit(0)


func _run_one_configuration(p_lubricity: float, p_full_report: bool) -> void:
	# Each call rebuilds from a clean root.
	for c in root.get_children():
		root.remove_child(c)
		c.free()

	# Build wedge.
	_make_ramp(true)   # right ramp
	_make_ramp(false)  # left ramp

	# Build tentacle anchored above the wedge apex.
	var t: Node3D = ClassDB.instantiate("Tentacle")
	t.particle_count = CHAIN_PARTICLES
	t.segment_length = SEGMENT_LEN
	t.particle_collision_radius = PARTICLE_RADIUS
	t.gravity = Vector3(0, -9.8, 0)
	t.environment_probe_distance = 5.0
	t.tentacle_lubricity = p_lubricity
	t.base_static_friction = 0.4
	# Default iteration_count = 4, substep_count = 1 per the slice prompt.
	t.position = Vector3(0.0, 0.20, 0.0)
	t.name = "WedgeTentacle"
	root.add_child(t)

	# Per-tick rolling state for the analysis window.
	# tick_data[tick] = Array of per-particle Dictionaries.
	# We record only the last MEASURE_TICKS, so total memory ≈
	# MEASURE_TICKS × N × MAX_CONTACTS × ~8 fields = trivial.
	var history: Array = []

	for tick in TOTAL_TICKS:
		# Capture position before the tick to compute |Δpos|.
		var before: PackedVector3Array = t.get_particle_positions().duplicate()
		t.tick(DT)
		var after: PackedVector3Array = t.get_particle_positions()
		# Only record steady-state window.
		if tick < TOTAL_TICKS - MEASURE_TICKS:
			continue
		# Probe-side per-slot data (object_id, hit_point, hit_normal, hit_depth).
		var probe_snap: Array = t.get_environment_contacts_snapshot()
		# Solver-side per-slot normal_lambda (size N × MAX_CONTACTS).
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
					var lam_idx: int = pi * 2 + k  # MAX_CONTACTS_PER_PARTICLE = 2
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

	# Report.
	_report(history, p_full_report)


func _make_ramp(p_right: bool) -> void:
	# Right ramp tilts down-right (rotation -tilt around Z, so its top
	# surface slopes down toward +X). Left ramp mirrors.
	var sign: float = 1.0 if p_right else -1.0
	var body := StaticBody3D.new()
	root.add_child(body)
	# Rotate first.
	var rot: float = -deg_to_rad(WEDGE_TILT_DEG) * sign
	body.transform = Transform3D(Basis().rotated(Vector3(0, 0, 1), rot), Vector3.ZERO)
	# Position so the box's INNER edge (the edge closest to apex) sits
	# at the wedge apex point. The "inner edge" sits at local x = -box_half_len
	# for the right ramp (which is rotated -tilt; its rotated +X axis
	# points down-right, so its rotated -X axis points up-left toward
	# the apex). Center is offset by +half_len along the rotated +X.
	# After rotation by -tilt around Z:
	#   rotated_x = cos(-tilt)·X + sin(-tilt)·Y = (cos, -sin, 0)  (right ramp, sign=+1)
	#   rotated_x = (cos,  sin, 0)                              (left ramp, sign=-1)
	# Use the ABSOLUTE rotation `rot` for the center offset.
	var rotated_x: Vector3 = Vector3(cos(rot), sin(rot), 0.0)
	body.position = WEDGE_APEX + rotated_x * BOX_HALF_LEN
	# Also slide the box DOWN by its thickness so its top surface (which
	# has local +Y normal, after rotation = up-and-toward-apex) is what
	# the falling chain hits. The inward (toward-apex) direction at the
	# top surface is -rotated_x. The "inward" normal at the top face is
	# rotated +Y = (-sin(rot), cos(rot), 0). For the right ramp (rot < 0)
	# this is roughly (+sin|rot|, +cos|rot|, 0) — points up-and-right.
	# We DON'T want to slide it down; the top face needs to start at the
	# apex y-level. Slide along its OWN -Y axis (local) by box_half_thick:
	var rotated_y: Vector3 = Vector3(-sin(rot), cos(rot), 0.0)
	body.position -= rotated_y * BOX_HALF_THICK
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(BOX_HALF_LEN * 2.0, BOX_HALF_THICK * 2.0, 2.0)
	shape.shape = box
	body.add_child(shape)


func _report(p_history: Array, p_full: bool) -> void:
	# p_history[tick][particle_idx] = { position, dpos, slots: [{k, object_id, point, normal, depth, normal_lambda}] }
	var n_ticks: int = p_history.size()
	if n_ticks == 0:
		print("[DIAG] no measurement ticks captured")
		return
	print("Steady-state window: %d ticks (last %d of %d)" % [n_ticks, MEASURE_TICKS, TOTAL_TICKS])
	print("Particles: %d, MAX_CONTACTS: 2" % CHAIN_PARTICLES)
	print()

	if not p_full:
		# Comparison run: only emit the channel summary block. Skip the
		# per-particle dump.
		_print_channel_summary(p_history)
		return

	# Per-particle channel-instability counters.
	for pi in CHAIN_PARTICLES:
		# Aggregate across the steady-state window.
		var slot_count_distribution: Dictionary = {}  # contact_count -> # ticks
		# Track per-slot stability separately. Use slot index k (0 / 1).
		var slot_object_id_changes: Array = [0, 0]
		var slot_normal_changes: Array = [0, 0]  # |Δnormal| > 1e-3
		var slot_point_changes: Array = [0, 0]   # |Δpoint| > 1 mm
		var slot_lambda_changes: Array = [0, 0]  # |Δlambda| > 1% of mean
		var prev_slots_by_k: Array = [null, null]  # last seen Dictionary for each k
		var lambda_sum_per_k: Array = [0.0, 0.0]
		var lambda_n_per_k: Array = [0, 0]
		var dpos_max: float = 0.0
		var dpos_sum: float = 0.0
		var pos_first: Vector3 = Vector3.ZERO
		var pos_last: Vector3 = Vector3.ZERO

		for tick_i in n_ticks:
			var rec: Dictionary = p_history[tick_i][pi]
			var slots: Array = rec.slots
			var c: int = slots.size()
			slot_count_distribution[c] = int(slot_count_distribution.get(c, 0)) + 1
			dpos_max = maxf(dpos_max, float(rec.dpos))
			dpos_sum += float(rec.dpos)
			if tick_i == 0:
				pos_first = rec.position
			pos_last = rec.position
			for k in slots.size():
				var s: Dictionary = slots[k]
				var lam: float = float(s.normal_lambda)
				lambda_sum_per_k[k] += lam
				lambda_n_per_k[k] += 1
				if prev_slots_by_k[k] != null:
					var prev: Dictionary = prev_slots_by_k[k]
					if int(prev.object_id) != int(s.object_id):
						slot_object_id_changes[k] += 1
					if (Vector3(s.normal) - Vector3(prev.normal)).length() > 1e-3:
						slot_normal_changes[k] += 1
					if (Vector3(s.point) - Vector3(prev.point)).length() > 1e-3:
						slot_point_changes[k] += 1
					var prev_lam: float = float(prev.normal_lambda)
					var mean_lam: float = (absf(lam) + absf(prev_lam)) * 0.5
					if mean_lam > 1e-7:
						var rel: float = absf(lam - prev_lam) / mean_lam
						if rel > 0.01:
							slot_lambda_changes[k] += 1
				prev_slots_by_k[k] = s

		var has_any_contact: bool = false
		for c_count in slot_count_distribution:
			if int(c_count) > 0:
				has_any_contact = true
				break
		if not has_any_contact:
			# Free-falling (or settled in air) — uninteresting.
			continue

		print("--- Particle %d ---" % pi)
		print("  position drift over %d ticks: |last-first| = %.6f m"
				% [n_ticks, (pos_last - pos_first).length()])
		print("  per-tick |Δpos|: max=%.6f mean=%.6f"
				% [dpos_max, dpos_sum / float(n_ticks)])
		var dist_str: String = ""
		var keys: Array = slot_count_distribution.keys()
		keys.sort()
		for k in keys:
			dist_str += "  %d slots: %d ticks |" % [int(k), int(slot_count_distribution[k])]
		print("  contact_count distribution:%s" % dist_str)

		for k in 2:
			if lambda_n_per_k[k] == 0:
				continue
			var mean_lam: float = lambda_sum_per_k[k] / float(lambda_n_per_k[k])
			print("  slot[%d]: object_id flips=%d  normal flips=%d  point shifts=%d (>1mm)  lambda osc=%d (>1%% mean)  mean_lambda=%.6f"
					% [k, slot_object_id_changes[k], slot_normal_changes[k],
						slot_point_changes[k], slot_lambda_changes[k], mean_lam])
		print()

	_print_channel_summary(p_history)


func _print_channel_summary(p_history: Array) -> void:
	var n_ticks: int = p_history.size()
	if n_ticks == 0:
		return
	var max_object_flips: int = 0
	var max_normal_flips: int = 0
	var max_point_shifts: int = 0
	var max_lambda_osc: int = 0
	var max_dpos: float = 0.0
	for pi in CHAIN_PARTICLES:
		var prev_slots_by_k: Array = [null, null]
		for tick_i in n_ticks:
			var rec: Dictionary = p_history[tick_i][pi]
			max_dpos = maxf(max_dpos, float(rec.dpos))
			for k in rec.slots.size():
				var s: Dictionary = rec.slots[k]
				if prev_slots_by_k[k] != null:
					var prev: Dictionary = prev_slots_by_k[k]
					if int(prev.object_id) != int(s.object_id):
						max_object_flips += 1
					if (Vector3(s.normal) - Vector3(prev.normal)).length() > 1e-3:
						max_normal_flips += 1
					if (Vector3(s.point) - Vector3(prev.point)).length() > 1e-3:
						max_point_shifts += 1
					var prev_lam: float = float(prev.normal_lambda)
					var lam: float = float(s.normal_lambda)
					var mean_lam: float = (absf(lam) + absf(prev_lam)) * 0.5
					if mean_lam > 1e-7:
						var rel: float = absf(lam - prev_lam) / mean_lam
						if rel > 0.01:
							max_lambda_osc += 1
				prev_slots_by_k[k] = s
	print("========== Channel summary ==========")
	print("(i)   slot object_id flips (across all particles × slots × ticks): %d" % max_object_flips)
	print("(ii)  hit_point shifts > 1 mm:                                      %d" % max_point_shifts)
	print("(iii) hit_normal flips > 1e-3:                                       %d" % max_normal_flips)
	print("(iv)  normal_lambda oscillation > 1%% of running mean:              %d" % max_lambda_osc)
	print("Worst per-tick |Δpos| in window: %.6f m" % max_dpos)
	print("======================================")
