extends SceneTree

# Slice-2 verification: drives Marionette.build_convex_colliders end-to-end
# on the kasumi rig and confirms each MarionetteBone's collision shape
# matches the profile (ConvexPolygonShape3D when the profile has a hull
# for that bone, CapsuleShape3D otherwise). Also exercises the revert
# path so we know switching back is wired up.
#
# Run:
#   godot --headless --path /home/caetano/desktop/cosmic-bliss/game \
#     --script /home/caetano/desktop/cosmic-bliss/extensions/marionette/tests/build_marionette_colliders_test.gd

const KASUMI_SCENE: String = "res://tests/marionette/kasumi/kasumi.tscn"


func _init() -> void:
	print("==== Marionette slice-2 collider wiring test ====")
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
		push_error("No Marionette node in kasumi")
		quit(1)
		return

	# 1. Build ragdoll with no collision profile — expect all capsules.
	marionette.build_ragdoll()
	var sim: PhysicalBoneSimulator3D = _find_simulator(marionette)
	var pre: Dictionary = _shape_summary(sim)
	print("After build_ragdoll (no profile): capsules=%d  hulls=%d  none=%d"
			% [pre["capsule"], pre["hull"], pre["none"]])
	assert(pre["hull"] == 0, "expected no hulls before build_convex_colliders")
	assert(pre["capsule"] > 0, "expected capsules to be present")

	# 2. Build convex colliders — expect most bones to swap to hulls.
	marionette.build_convex_colliders()
	await process_frame
	var post: Dictionary = _shape_summary(sim)
	print("After build_convex_colliders: capsules=%d  hulls=%d  none=%d  profile.hulls=%d  auto_exclusions=%d"
			% [post["capsule"], post["hull"], post["none"],
				marionette.bone_collision_profile.hulls.size(),
				marionette.bone_collision_profile.auto_exclusions.size()])
	assert(post["hull"] > 0, "expected hulls after build_convex_colliders")
	assert(post["none"] == 0, "every dynamic bone should have a shape")

	# 3. Spot-check: every bone whose profile-name has a hull should have a
	#    ConvexPolygonShape3D, not a capsule. Dump any mismatch.
	var mismatches: PackedStringArray = _verify_shape_assignment(marionette, sim)
	print("Shape-assignment mismatches: %d" % mismatches.size())
	for m: String in mismatches:
		print("  - %s" % m)
	assert(mismatches.is_empty(), "shape assignment didn't match profile state")

	# 4. start_simulation() exercises _ensure_runtime_colliders + the
	#    auto_exclusions merge — confirms the runtime path doesn't fight
	#    the editor build path.
	marionette.start_simulation()
	await process_frame
	var run: Dictionary = _shape_summary(sim)
	print("After start_simulation: capsules=%d  hulls=%d  none=%d"
			% [run["capsule"], run["hull"], run["none"]])
	assert(run["hull"] == post["hull"], "self-heal swapped hull shapes unexpectedly")
	assert(run["capsule"] == post["capsule"], "self-heal swapped capsule shapes unexpectedly")

	# 5. Revert — every shape becomes a capsule again.
	marionette.stop_simulation()
	marionette.revert_to_capsules()
	await process_frame
	var reverted: Dictionary = _shape_summary(sim)
	print("After revert_to_capsules: capsules=%d  hulls=%d  none=%d"
			% [reverted["capsule"], reverted["hull"], reverted["none"]])
	assert(reverted["hull"] == 0, "expected all hulls cleared on revert")
	assert(reverted["capsule"] == post["capsule"] + post["hull"],
			"expected revert to populate capsules where hulls were")

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


# Counts the shape kinds attached to each MarionetteBone under `sim`.
# `none` flags bones with zero CollisionShape3D children — they'd be
# physics-inert at runtime.
func _shape_summary(sim: PhysicalBoneSimulator3D) -> Dictionary:
	var out: Dictionary = {"capsule": 0, "hull": 0, "none": 0, "other": 0}
	if sim == null:
		return out
	for child: Node in sim.get_children():
		if not (child is MarionetteBone):
			continue
		var bone: MarionetteBone = child
		var found: bool = false
		for c: Node in bone.get_children():
			if c is CollisionShape3D:
				found = true
				var cs: CollisionShape3D = c
				if cs.shape is ConvexPolygonShape3D:
					out["hull"] += 1
				elif cs.shape is CapsuleShape3D:
					out["capsule"] += 1
				else:
					out["other"] += 1
				break
		if not found:
			out["none"] += 1
	return out


# Compares each MarionetteBone's shape against what the active profile
# claims it should be. Returns descriptive lines for any bone whose
# shape disagrees with the profile.
func _verify_shape_assignment(marionette: Marionette, sim: PhysicalBoneSimulator3D) -> PackedStringArray:
	var bad: PackedStringArray = PackedStringArray()
	if sim == null:
		return bad
	for child: Node in sim.get_children():
		if not (child is MarionetteBone):
			continue
		var bone: MarionetteBone = child
		var has_hull_in_profile: bool = marionette._profile_has_hull_for_bone(bone)
		var shape_kind: String = "(none)"
		for c: Node in bone.get_children():
			if c is CollisionShape3D:
				var s: Shape3D = (c as CollisionShape3D).shape
				if s is ConvexPolygonShape3D:
					shape_kind = "hull"
				elif s is CapsuleShape3D:
					shape_kind = "capsule"
				else:
					shape_kind = String(s.get_class()) if s != null else "(null shape)"
				break
		if has_hull_in_profile and shape_kind != "hull":
			bad.append("%s: profile has hull but shape=%s" % [bone.bone_name, shape_kind])
		elif not has_hull_in_profile and shape_kind == "hull":
			bad.append("%s: profile has no hull but shape=hull" % bone.bone_name)
	return bad
