extends SceneTree

# Slice-4a verification: confirms Marionette.build_ragdoll spawns a
# JiggleBone for every entry in bone_collision_profile.non_cascade_bones
# that has a hull, attaches the convex collider, and leaves the bone out
# of the dynamic-bone list (KINEMATIC tracking the skeleton pose).
#
# The kasumi profile.tres ships empty, so the test calibrates it from the
# skeleton first (the same path the inspector's "Calibrate" button uses).
#
# Run:
#   godot --headless --path /home/caetano/desktop/cosmic-bliss/game \
#     --script /home/caetano/desktop/cosmic-bliss/extensions/marionette/tests/build_jiggle_bones_test.gd

const KASUMI_SCENE: String = "res://tests/marionette/kasumi/kasumi.tscn"

const EXPECTED_JIGGLE_BONES: Array[StringName] = [
	&"c_breast_01.l", &"c_breast_01.r",
	&"c_breast_02.l", &"c_breast_02.r",
]


func _init() -> void:
	print("==== Marionette slice-4a jiggle-bone wiring test ====")
	var packed: PackedScene = load(KASUMI_SCENE)
	if packed == null:
		push_error("Failed to load kasumi scene")
		quit(1)
		return
	var inst: Node = packed.instantiate()
	root.add_child(inst)
	await process_frame

	var marionette: Marionette = _find_marionette(inst)
	if marionette == null:
		push_error("No Marionette node in kasumi scene")
		quit(1)
		return

	# 1. Calibrate the bone_profile so build_ragdoll has entries to consume.
	#    The shipped .tres has bones = {} and would early-return otherwise.
	if marionette.bone_profile.bones.is_empty():
		print("Calibrating bone_profile from skeleton ...")
		marionette.calibrate_bone_profile_from_skeleton()

	# 2. Author the non-cascade list onto a fresh BoneCollisionProfile so
	#    the build_convex_colliders pass produces breast hulls. Inherit the
	#    existing profile's tuned knobs (the kasumi.tscn ships some).
	var src_profile: BoneCollisionProfile = marionette.bone_collision_profile
	if src_profile == null:
		src_profile = BoneCollisionProfile.new()
	src_profile.non_cascade_bones = EXPECTED_JIGGLE_BONES
	marionette.bone_collision_profile = src_profile

	# 2b. Author a JiggleProfile with mixed entries: one bone uses a
	#     custom reach (snappy), one bone uses the profile-level default
	#     (which we set to a non-default value), the remaining two get
	#     the profile defaults too. This validates all three resolution
	#     tiers (per-entry, profile default, code default unreachable
	#     when a profile is assigned).
	var jp := JiggleProfile.new()
	jp.default_reach_seconds = 0.5    # not the code default 0.3
	jp.default_damping_ratio = 0.4    # not the code default 0.7
	var snappy := JiggleEntry.new()
	snappy.reach_seconds = 0.15
	snappy.damping_ratio = 0.9
	jp.entries[&"c_breast_01.l"] = snappy
	marionette.jiggle_profile = jp

	print("Building convex colliders ...")
	marionette.build_convex_colliders()
	await process_frame

	print("Building ragdoll ...")
	marionette.build_ragdoll()

	# 3. Inspect the simulator's children. Expect the regular MarionetteBones
	#    PLUS one JiggleBone per expected entry, each carrying a convex hull
	#    collider and an empty bone_entry.
	var sim: PhysicalBoneSimulator3D = _find_simulator(marionette)
	if sim == null:
		push_error("Marionette didn't build a simulator")
		quit(1)
		return

	var jiggle_bones: Array[JiggleBone] = []
	var marionette_bones: Array[MarionetteBone] = []
	for child: Node in sim.get_children():
		if child is JiggleBone:
			jiggle_bones.append(child)
		elif child is MarionetteBone:
			marionette_bones.append(child)

	print("Simulator children: %d MarionetteBones, %d JiggleBones"
			% [marionette_bones.size(), jiggle_bones.size()])

	var failures: int = 0
	if jiggle_bones.size() != EXPECTED_JIGGLE_BONES.size():
		push_error("Expected %d JiggleBones, got %d" % [
				EXPECTED_JIGGLE_BONES.size(), jiggle_bones.size()])
		failures += 1

	for jb: JiggleBone in jiggle_bones:
		var bn: StringName = StringName(jb.bone_name)
		print("  - %s   host=%s   mass=%.3f kg" % [bn, jb.host_bone_name, jb.mass])
		if not EXPECTED_JIGGLE_BONES.has(bn):
			push_error("Unexpected JiggleBone: %s" % bn)
			failures += 1
		# Each jiggle bone should host a ConvexPolygonShape3D collider.
		var collider: CollisionShape3D = null
		for c: Node in jb.get_children():
			if c is CollisionShape3D:
				collider = c
				break
		if collider == null:
			push_error("JiggleBone %s has no CollisionShape3D" % bn)
			failures += 1
		elif not (collider.shape is ConvexPolygonShape3D):
			push_error("JiggleBone %s has wrong shape (%s)"
					% [bn, collider.shape.get_class() if collider.shape != null else "null"])
			failures += 1
		# JiggleBone is its own class — no inherited bone_entry to verify.

	# 4. Jiggle bones MUST be in the dynamic list — without it the simulator
	#    leaves them kinematic and _integrate_forces never fires (so no
	#    spring). They also need custom_integrator + a configured spring.
	for jb: JiggleBone in jiggle_bones:
		if not marionette._dynamic_bone_names.has(StringName(jb.bone_name)):
			push_error("JiggleBone %s missing from dynamic_bone_names" % jb.bone_name)
			failures += 1
		if not jb.custom_integrator:
			push_error("JiggleBone %s should have custom_integrator=true" % jb.bone_name)
			failures += 1
		if jb.stiffness <= 0.0 or jb.damping <= 0.0:
			push_error("JiggleBone %s has un-tuned spring (k=%f c=%f)"
					% [jb.bone_name, jb.stiffness, jb.damping])
			failures += 1

	# 5. JiggleProfile resolution: confirm the per-entry override won and
	#    the profile-default tier landed on entries that have no explicit
	#    JiggleEntry. Spring values are derived as
	#       k = m · (TAU / reach)²
	#       c = 2 · ζ · (TAU / reach) · m
	#    so we recompute the expected k/c and compare against the bone's
	#    actual values.
	for jb: JiggleBone in jiggle_bones:
		var bn: StringName = StringName(jb.bone_name)
		var expected_reach: float
		var expected_zeta: float
		if bn == &"c_breast_01.l":
			# Per-entry override.
			expected_reach = 0.15
			expected_zeta = 0.9
		else:
			# Profile-level default (we set 0.5 / 0.4 above).
			expected_reach = 0.5
			expected_zeta = 0.4
		var omega: float = TAU / expected_reach
		var expected_k: float = jb.mass * omega * omega
		var expected_c: float = 2.0 * expected_zeta * omega * jb.mass
		if not is_equal_approx(jb.stiffness, expected_k):
			push_error("%s expected k=%.2f from JiggleProfile, got %.2f"
					% [bn, expected_k, jb.stiffness])
			failures += 1
		if not is_equal_approx(jb.damping, expected_c):
			push_error("%s expected c=%.2f from JiggleProfile, got %.2f"
					% [bn, expected_c, jb.damping])
			failures += 1
		print("    %s spring resolved from profile: k=%.2f c=%.2f (reach %.2fs ζ %.2f)"
				% [bn, jb.stiffness, jb.damping, expected_reach, expected_zeta])

	if failures > 0:
		push_error("%d failure(s)" % failures)
		quit(1)
	else:
		print()
		print("PASS")
		quit(0)


func _find_marionette(node: Node) -> Marionette:
	if node is Marionette:
		return node
	for c: Node in node.get_children():
		var m: Marionette = _find_marionette(c)
		if m != null:
			return m
	return null


func _find_simulator(marionette: Marionette) -> PhysicalBoneSimulator3D:
	var skel: Skeleton3D = marionette.resolve_skeleton()
	if skel == null:
		return null
	for c: Node in skel.get_children():
		if c is PhysicalBoneSimulator3D:
			return c
	return null
