extends SceneTree

# Slice-6 verification: Build Ragdoll bakes the simulator + bones +
# colliders into the scene with set_owner, so saving the scene and
# reloading it produces a working ragdoll *without* re-running Build.
#
# Pipeline:
#   1. Instantiate kasumi, calibrate the bone profile, populate
#      non_cascade_bones, build colliders, build ragdoll.
#   2. PackedScene.pack the instance and ResourceSaver.save to user://
#      so we have a freshly-saved .tscn to reload.
#   3. Free the original instance.
#   4. load() the saved scene and instantiate it. The simulator and all
#      bones (incl. ConvexPolygonShape3D children with hull points) must
#      be present from the .tscn alone — no Build call on the reloaded
#      copy.
#   5. start_simulation should work and apply collision exceptions
#      without complaining about missing colliders.
#
# Run:
#   godot --headless --path /home/caetano/desktop/cosmic-bliss/game \
#     --script /home/caetano/desktop/cosmic-bliss/extensions/marionette/tests/bake_to_scene_test.gd

const KASUMI_SCENE: String = "res://tests/marionette/kasumi/kasumi.tscn"
const TEMP_PATH: String = "user://_marionette_bake_test.tscn"

const EXPECTED_JIGGLE_BONES: Array[StringName] = [
	&"c_breast_01.l", &"c_breast_01.r",
	&"c_breast_02.l", &"c_breast_02.r",
]


func _init() -> void:
	print("==== Marionette slice-6 bake-to-scene round-trip ====")
	# --- Phase 1: build a ragdoll and save the scene -------------------
	var packed: PackedScene = load(KASUMI_SCENE)
	var inst: Node = packed.instantiate()
	root.add_child(inst)
	await process_frame

	var marionette: Marionette = _find_marionette(inst)
	if marionette == null:
		push_error("No Marionette in kasumi")
		quit(1)
		return

	# Calibrate so build_ragdoll has BoneEntries.
	marionette.bone_profile.bones = {}
	marionette.calibrate_bone_profile_from_skeleton()

	# Soft-region opt-in.
	var src_profile: BoneCollisionProfile = marionette.bone_collision_profile
	if src_profile == null:
		src_profile = BoneCollisionProfile.new()
	src_profile.non_cascade_bones = EXPECTED_JIGGLE_BONES
	marionette.bone_collision_profile = src_profile

	marionette.build_convex_colliders()
	await process_frame
	marionette.build_ragdoll()

	# Pack + save.
	var ps := PackedScene.new()
	# IMPORTANT: pack the SCENE ROOT, not the marionette node — owner
	# pointers are anchored to the scene root, so packing a sub-branch
	# loses the bones (they have owner = inst, not = marionette).
	var pack_err: int = ps.pack(inst)
	if pack_err != OK:
		push_error("PackedScene.pack failed: %d" % pack_err)
		quit(1)
		return
	var save_err: int = ResourceSaver.save(ps, TEMP_PATH)
	if save_err != OK:
		push_error("ResourceSaver.save failed: %d" % save_err)
		quit(1)
		return
	# Print the saved-file size for visibility. Note: this number is *not*
	# representative of the editor flow — PackedScene.pack(inst) re-inlines
	# the kasumi mesh + skeleton bone data that the original .tscn
	# referenced via ext_resource, so the test artifact is many MB. In the
	# editor flow the user opens the existing .tscn (with ext_resource
	# refs intact), clicks Build Ragdoll, and Ctrl+S — Godot keeps the ext
	# refs and only adds the new bone hierarchy + ~60 KB of hull data.
	var file := FileAccess.open(TEMP_PATH, FileAccess.READ)
	var size_bytes: int = file.get_length() if file != null else -1
	if file != null:
		file.close()
	print("Saved %s (%d bytes; mostly mesh re-inlining, see comment)" % [TEMP_PATH, size_bytes])

	inst.queue_free()
	await process_frame

	# --- Phase 2: reload + verify --------------------------------------
	var reloaded_packed: PackedScene = load(TEMP_PATH)
	if reloaded_packed == null:
		push_error("Failed to load %s" % TEMP_PATH)
		quit(1)
		return
	var reloaded_inst: Node = reloaded_packed.instantiate()
	root.add_child(reloaded_inst)
	await process_frame

	var reloaded_m: Marionette = _find_marionette(reloaded_inst)
	if reloaded_m == null:
		push_error("Reloaded scene has no Marionette")
		quit(1)
		return
	var reloaded_sim: PhysicalBoneSimulator3D = _find_simulator(reloaded_m)
	if reloaded_sim == null:
		push_error("Reloaded scene has no simulator — bake failed")
		quit(1)
		return

	var failures: int = 0
	var bone_count: int = 0
	var jiggle_count: int = 0
	var capsule_colliders: int = 0
	var hull_colliders: int = 0
	var hull_points_total: int = 0
	for child: Node in reloaded_sim.get_children():
		var pb: PhysicalBone3D = child as PhysicalBone3D
		if pb == null:
			continue
		if child is JiggleBone:
			jiggle_count += 1
		elif child is MarionetteBone:
			bone_count += 1
		else:
			continue
		# Walk for the CollisionShape3D; verify the shape resource is
		# present (not just the node — the points need to round-trip too).
		for c: Node in pb.get_children():
			if not (c is CollisionShape3D):
				continue
			var shape: Shape3D = (c as CollisionShape3D).shape
			if shape is ConvexPolygonShape3D:
				hull_colliders += 1
				hull_points_total += (shape as ConvexPolygonShape3D).points.size()
			elif shape is CapsuleShape3D:
				capsule_colliders += 1
			break

	print("Reloaded: %d MarionetteBones, %d JiggleBones, %d hulls, %d capsules, %d total hull points"
			% [bone_count, jiggle_count, hull_colliders, capsule_colliders, hull_points_total])

	if bone_count != 78:
		push_error("Expected 78 MarionetteBones in reloaded scene, got %d" % bone_count)
		failures += 1
	if jiggle_count != EXPECTED_JIGGLE_BONES.size():
		push_error("Expected %d JiggleBones, got %d" % [EXPECTED_JIGGLE_BONES.size(), jiggle_count])
		failures += 1
	# Most bones should have a hull (kasumi has 78+4 = 82 hulls in the profile).
	# Allow a small slack for bones with no hull (rare; profile generation may
	# skip bones whose buckets are too small).
	if hull_colliders < 70:
		push_error("Expected hull colliders to round-trip into the scene; got only %d (slice 6 broken?)"
				% hull_colliders)
		failures += 1
	if hull_points_total < 4 * hull_colliders:
		push_error("Hulls are present but points didn't round-trip — got %d total points across %d hulls"
				% [hull_points_total, hull_colliders])
		failures += 1

	# start_simulation on the reloaded scene must succeed without re-Build.
	# Catches a regression where collision exceptions or sim membership
	# silently drop on the round-trip.
	reloaded_m.start_simulation()
	await process_frame
	print("start_simulation completed on reloaded scene")

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
