extends SceneTree

# Headless smoke test for ColliderBuilder.
#
# Instances the kasumi rig, walks the scene tree to find every skinned
# MeshInstance3D under the GeneralSkeleton, runs ColliderBuilder.build_profile
# on each, and merges the results into a single BoneCollisionProfile saved
# at OUT_PATH. Prints per-bone hull stats plus the auto_exclusions count
# so we can eyeball whether the harvest + decimation pipeline produced
# something reasonable before wiring it into the editor inspector.
#
# Run:
#   godot --headless --path /home/caetano/desktop/cosmic-bliss/game \
#         --script /home/caetano/desktop/cosmic-bliss/extensions/marionette/tests/build_collision_profile_test.gd

const KASUMI_SCENE: String = "res://tests/marionette/kasumi/kasumi.tscn"
const OUT_PATH: String = "res://tests/marionette/kasumi/kasumi_collision_profile.tres"


func _init() -> void:
	print("==== ColliderBuilder smoke test ====")
	var packed: PackedScene = load(KASUMI_SCENE)
	if packed == null:
		push_error("Failed to load kasumi scene")
		quit(1)
		return

	var inst: Node = packed.instantiate()
	root.add_child(inst)
	# Let _ready run on the imported scene so any retargeting / bone-map
	# resolution settles before we read mesh data.
	await process_frame

	var marionette: Marionette = _find_marionette(inst)
	if marionette == null:
		push_error("No Marionette node in kasumi scene")
		quit(1)
		return
	var skel: Skeleton3D = marionette.resolve_skeleton()
	if skel == null:
		push_error("Could not resolve Skeleton3D from Marionette.skeleton path")
		quit(1)
		return
	var bone_map: BoneMap = marionette.bone_map

	var meshes: Array[MeshInstance3D] = []
	_collect_skinned_meshes(skel.get_parent(), skel, meshes)
	# Kasumi's body mesh sometimes lives as a sibling of the Skeleton3D under
	# the same `root`; if nothing turned up, widen to the whole instance.
	if meshes.is_empty():
		_collect_skinned_meshes(inst, skel, meshes)
	if meshes.is_empty():
		push_error("No skinned MeshInstance3D found targeting %s" % skel.get_path())
		quit(1)
		return

	print("Skeleton: %s   bones=%d" % [skel.get_path(), skel.get_bone_count()])
	print("BoneMap: %s" % ("(none)" if bone_map == null else "set"))
	print("Found %d skinned mesh(es):" % meshes.size())
	for m: MeshInstance3D in meshes:
		var surface_count: int = (m.mesh as ArrayMesh).get_surface_count() if m.mesh is ArrayMesh else 0
		print("  - %s   surfaces=%d   skin=%s" % [
				m.get_path(), surface_count,
				"yes" if m.skin != null else "MISSING"])

	# Build a profile per mesh, then merge. Most rigs have one body mesh +
	# accessories; merging lets accessories contribute to their host bone's
	# hull (e.g. clothing on the chest) without overwriting it.
	var template := BoneCollisionProfile.new()
	# Defaults match the resource's exported defaults; kept explicit here
	# so the test's behavior doesn't drift if the resource defaults are
	# tuned later.
	template.weight_threshold = 0.3
	template.max_points_per_hull = 64
	template.shrink_factor = 0.02

	var merged := BoneCollisionProfile.new()
	merged.weight_threshold = template.weight_threshold
	merged.max_points_per_hull = template.max_points_per_hull
	merged.shrink_factor = template.shrink_factor

	for m: MeshInstance3D in meshes:
		if m.mesh == null or m.skin == null:
			continue
		print()
		print("Building from %s ..." % m.name)
		var per_mesh: BoneCollisionProfile = ColliderBuilder.build_profile(m, skel, bone_map, template)
		_merge_into(merged, per_mesh)

	# Re-derive auto_exclusions on the merged hulls so they reflect the
	# final geometry, not just the first mesh's.
	merged.auto_exclusions = ColliderBuilder.compute_overlap_pairs(merged, skel, bone_map)

	print()
	print("=== Merged profile ===")
	print("hulls: %d   auto_exclusions: %d" % [
			merged.hulls.size(), merged.auto_exclusions.size()])
	# Per-bone stats sorted by point count so the heaviest hulls surface first.
	var rows: Array[Dictionary] = []
	for bone_name: StringName in merged.hulls.keys():
		var pts: PackedVector3Array = merged.hulls[bone_name]
		var aabb := AABB(pts[0], Vector3.ZERO)
		for i: int in range(1, pts.size()):
			aabb = aabb.expand(pts[i])
		rows.append({
			"name": String(bone_name),
			"count": pts.size(),
			"size": aabb.size,
		})
	rows.sort_custom(func(a, b): return a["count"] > b["count"])
	print()
	print("%-28s | %5s | size (m)" % ["bone", "pts"])
	print("-".repeat(70))
	for r: Dictionary in rows:
		print("%-28s | %5d | %.3f x %.3f x %.3f" % [
				r["name"], r["count"],
				r["size"].x, r["size"].y, r["size"].z])

	var save_err: int = ResourceSaver.save(merged, OUT_PATH)
	print()
	print("Saved %s -> err=%d" % [OUT_PATH, save_err])
	quit()


func _find_marionette(node: Node) -> Marionette:
	if node is Marionette:
		return node
	for c: Node in node.get_children():
		var m: Marionette = _find_marionette(c)
		if m != null:
			return m
	return null


# Walks `from` recursively, appending every MeshInstance3D whose `skeleton`
# NodePath resolves to `target_skel`. Skips meshes without a Skin assigned
# (we can't harvest weights from those).
func _collect_skinned_meshes(from: Node, target_skel: Skeleton3D, out: Array[MeshInstance3D]) -> void:
	if from == null:
		return
	if from is MeshInstance3D:
		var mi: MeshInstance3D = from
		if mi.skin != null and not mi.skeleton.is_empty():
			var resolved: Node = mi.get_node_or_null(mi.skeleton)
			if resolved == target_skel:
				out.append(mi)
	for c: Node in from.get_children():
		_collect_skinned_meshes(c, target_skel, out)


# Folds `src.hulls` into `dst.hulls`. When both profiles cover the same
# bone, points are concatenated and re-decimated to the cap so accessories
# don't blow the per-hull point count past the limit. AABB / exclusion
# state is left to the caller — see the post-merge compute_overlap_pairs.
func _merge_into(dst: BoneCollisionProfile, src: BoneCollisionProfile) -> void:
	for bone_name: StringName in src.hulls.keys():
		var src_pts: PackedVector3Array = src.hulls[bone_name]
		if src_pts.is_empty():
			continue
		if not dst.hulls.has(bone_name):
			dst.hulls[bone_name] = src_pts
			continue
		var combined: PackedVector3Array = dst.hulls[bone_name]
		combined.append_array(src_pts)
		# Cap by re-running the same adaptive decimation; keeps merged
		# hulls comparable to single-source ones in point count.
		dst.hulls[bone_name] = ColliderBuilder.find_optimal_decimation(
				combined, dst.max_points_per_hull)
