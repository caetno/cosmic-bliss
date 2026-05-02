@tool
class_name ColliderBuilder

# Authoring-time tool that turns a skinned MeshInstance3D into a
# `BoneCollisionProfile` of per-bone convex hulls. Pure data flow; no
# physics, no scene mutation. Slice 2 wires the result into Marionette's
# build path so ragdoll creation uses these hulls instead of capsules.
#
# Pipeline:
#   1. Walk every surface of the mesh, classify each vertex into one or
#      more bone buckets via dominant-weight + threshold-overlap.
#   2. Transform each vertex into bone-local rest space using the Skin's
#      bind pose (which already bakes mesh-instance transform).
#   3. For each bucket, decimate adaptively: try increasing
#      furthest-point samples and stop at the first one whose silhouette
#      quality (mean directional-extent ratio over a Fibonacci sphere)
#      meets the resource's threshold.
#   4. Optionally shrink each hull toward its centroid.
#   5. Compute pairwise hull-AABB overlaps in skeleton-rest space and
#      record them as Vector2i bone-index exclusions.
#
# The result is portable: the BoneCollisionProfile knows nothing about
# the mesh that produced it — all geometry has been baked to bone-local
# rest space. Re-importing the rig invalidates the profile (skin bind
# poses change), so the build action is run once per character and
# re-run when the mesh / rig is re-exported.

# Number of bands the bucket is split into along its longest AABB axis when
# stratified-sampling. Each band gets its own furthest-point quota so wrist /
# ankle / toe-base cross-sections aren't crowded out by the wider muscle-belly
# vertices a single global FPS pass would prefer. 6 bands gives enough end-cap
# coverage on long limbs while staying inexpensive for the inner FPS calls.
const _STRATIFY_BANDS: int = 6
# Floor of points per band — guarantees even short bones get cross-section
# coverage at every band; the rest is allocated proportionally to the band's
# vertex count.
const _STRATIFY_FLOOR: int = 4


# Top-level entry. Reads the authoring parameters off `template`
# (typically a fresh BoneCollisionProfile.new()), produces a fully
# populated profile, returns it. Caller saves the .tres if desired.
static func build_profile(
		mesh_instance: MeshInstance3D,
		skel: Skeleton3D,
		bone_map: BoneMap,
		template: BoneCollisionProfile = null) -> BoneCollisionProfile:
	var profile := BoneCollisionProfile.new()
	if template != null:
		profile.weight_threshold = template.weight_threshold
		profile.max_points_per_hull = template.max_points_per_hull
		profile.shrink_factor = template.shrink_factor

	if mesh_instance == null or skel == null:
		push_error("ColliderBuilder.build_profile: mesh_instance and skel are required")
		return profile

	var buckets: Dictionary[StringName, PackedVector3Array] = harvest_vertex_buckets(
			mesh_instance, skel, bone_map, profile.weight_threshold)
	for bone_name: StringName in buckets.keys():
		var pts: PackedVector3Array = buckets[bone_name]
		if pts.size() < 4:
			continue
		var optimized: PackedVector3Array = find_optimal_decimation(
				pts, profile.max_points_per_hull)
		if profile.shrink_factor > 0.0:
			optimized = apply_shrink(optimized, profile.shrink_factor)
		profile.hulls[bone_name] = optimized

	profile.auto_exclusions = compute_overlap_pairs(profile, skel, bone_map)
	return profile


# Reads ARRAY_BONES + ARRAY_WEIGHTS from every surface, classifies each
# vertex by dominant + overlap-threshold weights, transforms to bone-local
# rest space via Skin.get_bind_pose, returns one PackedVector3Array per
# profile bone name (or skeleton bone name when `bone_map` is null).
#
# Multi-bone assignment: a vertex contributes to its dominant bone's
# bucket plus every additional bone whose weight ≥ `weight_threshold`.
# That overlap is what keeps adjacent hulls covering the joint seams.
static func harvest_vertex_buckets(
		mesh_instance: MeshInstance3D,
		skel: Skeleton3D,
		bone_map: BoneMap,
		weight_threshold: float) -> Dictionary[StringName, PackedVector3Array]:
	var buckets: Dictionary[StringName, PackedVector3Array] = {}
	if mesh_instance == null or skel == null:
		push_error("ColliderBuilder.harvest: mesh_instance and skel are required")
		return buckets
	var arr_mesh: ArrayMesh = mesh_instance.mesh as ArrayMesh
	if arr_mesh == null:
		push_error("ColliderBuilder.harvest: mesh is not an ArrayMesh")
		return buckets
	var skin: Skin = mesh_instance.skin
	if skin == null:
		push_error("ColliderBuilder.harvest: MeshInstance3D '%s' has no Skin assigned" % mesh_instance.name)
		return buckets

	var skin_to_profile: Array[StringName] = _build_skin_name_table(skin, skel, bone_map)
	# Pre-cache bind poses so the inner loop avoids the GDScript getter cost
	# on every vertex (Skin getters are O(1) but reflective).
	var bind_poses: Array[Transform3D] = []
	bind_poses.resize(skin.get_bind_count())
	for i: int in skin.get_bind_count():
		bind_poses[i] = skin.get_bind_pose(i)

	for s: int in arr_mesh.get_surface_count():
		var arrays: Array = arr_mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if verts.is_empty():
			continue
		var bones_arr: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights_arr: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		if bones_arr.is_empty() or weights_arr.is_empty():
			continue
		# Stride is 4 by default, 8 when ARRAY_FLAG_USE_8_BONE_WEIGHTS is set.
		# Detected from the actual array length so we don't depend on the
		# format flags — those vary by importer / glb bake settings.
		var stride: int = bones_arr.size() / verts.size()
		if stride != 4 and stride != 8:
			push_warning("ColliderBuilder.harvest: surface %d has unexpected bone stride %d, skipping" % [s, stride])
			continue
		_classify_surface(
				verts, bones_arr, weights_arr, stride,
				skin_to_profile, bind_poses, weight_threshold,
				buckets)
	return buckets


# Inner classification loop pulled out so harvest_vertex_buckets stays
# readable. Mutates `buckets` in place.
static func _classify_surface(
		verts: PackedVector3Array,
		bones_arr: PackedInt32Array,
		weights_arr: PackedFloat32Array,
		stride: int,
		skin_to_profile: Array[StringName],
		bind_poses: Array[Transform3D],
		weight_threshold: float,
		buckets: Dictionary[StringName, PackedVector3Array]) -> void:
	var bind_count: int = bind_poses.size()
	for vi: int in verts.size():
		var v: Vector3 = verts[vi]
		var base: int = vi * stride
		var best_w: float = -1.0
		var best_skin: int = -1
		# First pass picks the dominant bone — that's the one we always
		# assign even when no weight meets the threshold.
		for k: int in stride:
			var w: float = weights_arr[base + k]
			if w > best_w:
				best_w = w
				best_skin = bones_arr[base + k]
		if best_skin < 0 or best_skin >= bind_count:
			continue
		# Track which skin indices we've already emitted for this vertex
		# so the same bucket doesn't get the point twice (4-bone slots can
		# carry duplicate indices when the rig has < 4 influences).
		var emitted: Array[int] = []
		_emit_to_bucket(v, best_skin, skin_to_profile, bind_poses, buckets, emitted)
		for k: int in stride:
			var w: float = weights_arr[base + k]
			if w < weight_threshold:
				continue
			var skin_idx: int = bones_arr[base + k]
			if skin_idx == best_skin or skin_idx < 0 or skin_idx >= bind_count:
				continue
			_emit_to_bucket(v, skin_idx, skin_to_profile, bind_poses, buckets, emitted)


static func _emit_to_bucket(
		v: Vector3,
		skin_idx: int,
		skin_to_profile: Array[StringName],
		bind_poses: Array[Transform3D],
		buckets: Dictionary[StringName, PackedVector3Array],
		emitted: Array[int]) -> void:
	if emitted.has(skin_idx):
		return
	emitted.append(skin_idx)
	var profile_name: StringName = skin_to_profile[skin_idx]
	if profile_name == &"":
		return
	var v_local: Vector3 = bind_poses[skin_idx] * v
	if not buckets.has(profile_name):
		buckets[profile_name] = PackedVector3Array()
	# Dictionary[K, PackedV3] returns a copy on .get/[]; we have to write
	# the whole array back. Cheap because PackedVector3Array is COW-shared
	# until the next mutation.
	var arr: PackedVector3Array = buckets[profile_name]
	arr.append(v_local)
	buckets[profile_name] = arr


# Maps each skin bind index to its profile bone name. For bones that aren't
# in the profile (twist helpers, leaf tails, accessory bones) we walk up the
# skeleton hierarchy until an ancestor *is* — so e.g. ARP's `arm_twist.l`
# (parented under `arm_stretch.l` → LeftUpperArm) contributes its skin
# weights to the upper-arm hull instead of forming a dead bucket. Without
# the cascade, vertices skinned to the 8 ARP twist bones (arm_twist,
# forearm_twist, thigh_twist, leg_twist × L/R) get dropped from the limb
# hulls — visible as a missing band of skin around the long-bone midshafts.
# `_twist_leaf` cascades through twist→stretch in two steps.
#
# Two retargeting workflows are both supported:
#   - Pre-retarget (skel uses ARP names): `bone_map.find_profile_bone_name`
#     resolves `arm_stretch.l` → `LeftUpperArm` directly.
#   - Post-retarget (skel uses profile names; the kasumi pipeline):
#     `find_profile_bone_name` returns &"" for everything because the map
#     is keyed on ARP source names, but `bone_map.profile.find_bone(name)`
#     is non-negative for legitimate profile slots — so we accept the skel
#     name as-is when it's a slot, and cascade for the leftover helpers.
# Null `bone_map` falls back to the legacy identity behavior (no profile
# oracle available).
static func _build_skin_name_table(
		skin: Skin,
		skel: Skeleton3D,
		bone_map: BoneMap) -> Array[StringName]:
	var out: Array[StringName] = []
	out.resize(skin.get_bind_count())
	var profile: SkeletonProfile = bone_map.profile if bone_map != null else null
	for i: int in skin.get_bind_count():
		var bind_name: StringName = StringName(skin.get_bind_name(i))
		var skel_idx: int = skin.get_bind_bone(i)
		var skel_name: StringName = bind_name
		if skel_name == &"" and skel_idx >= 0:
			skel_name = StringName(skel.get_bone_name(skel_idx))
		out[i] = _resolve_profile_name_with_cascade(skel_name, skel_idx, skel, bone_map, profile)
	return out


# Skeleton bone name -> profile bone name with parent-chain cascade for
# helper bones. Resolution order:
#   1. `bone_map.find_profile_bone_name(name)` (pre-retarget map hit).
#   2. `profile.find_bone(name) >= 0` (post-retarget identity — the skel
#      name already IS the profile slot name).
#   3. Walk up the skeleton, repeating 1+2 at each ancestor.
# Returns &"" only when no ancestor satisfies either path (e.g. `c_traj`
# above the hips). Null `bone_map` short-circuits to identity, matching
# the pre-cascade fallback behavior.
static func _resolve_profile_name_with_cascade(
		skel_name: StringName,
		skel_idx_hint: int,
		skel: Skeleton3D,
		bone_map: BoneMap,
		profile: SkeletonProfile) -> StringName:
	if bone_map == null:
		return skel_name
	var direct: StringName = _try_map_or_profile(skel_name, bone_map, profile)
	if direct != &"":
		return direct
	var idx: int = skel_idx_hint
	if idx < 0:
		idx = skel.find_bone(skel_name)
	while idx >= 0:
		idx = skel.get_bone_parent(idx)
		if idx < 0:
			break
		var ancestor_name: StringName = StringName(skel.get_bone_name(idx))
		var ancestor: StringName = _try_map_or_profile(ancestor_name, bone_map, profile)
		if ancestor != &"":
			return ancestor
	return &""


static func _try_map_or_profile(
		name: StringName,
		bone_map: BoneMap,
		profile: SkeletonProfile) -> StringName:
	var pn: StringName = bone_map.find_profile_bone_name(name)
	if pn != &"":
		return pn
	if profile != null and profile.find_bone(name) >= 0:
		return name
	return &""


# Greedy farthest-point sampling. Seed at the most-negative-X point so
# sampling is deterministic across runs (no RNG); then repeatedly pick
# the input point furthest from the already-selected set. Produces a
# subset whose hull silhouette closely matches the full set's, even at
# small k.
static func furthest_point_sample(points: PackedVector3Array, k: int) -> PackedVector3Array:
	var n: int = points.size()
	if n <= k:
		return points
	var sample := PackedVector3Array()
	sample.resize(k)
	var distances := PackedFloat32Array()
	distances.resize(n)
	# Deterministic seed: most-negative-X point. Any extremal choice would
	# work; this one needs no global compare against centroid.
	var seed_idx: int = 0
	for i: int in n:
		if points[i].x < points[seed_idx].x:
			seed_idx = i
	sample[0] = points[seed_idx]
	for i: int in n:
		distances[i] = (points[i] - sample[0]).length_squared()
	for s_idx: int in range(1, k):
		var max_d: float = -1.0
		var max_i: int = 0
		for i: int in n:
			if distances[i] > max_d:
				max_d = distances[i]
				max_i = i
		sample[s_idx] = points[max_i]
		var pivot: Vector3 = points[max_i]
		for i: int in n:
			var d: float = (points[i] - pivot).length_squared()
			if d < distances[i]:
				distances[i] = d
	return sample


# Furthest-point sampling stratified along the bucket's longest AABB axis.
# Splits the bucket into `_STRATIFY_BANDS` slabs along that axis and runs FPS
# inside each slab with its own quota, so narrow cross-sections (wrist, ankle,
# toe-base on a foot) get dedicated samples instead of being out-bid by the
# wider muscle-belly band a single global FPS pass prefers. This is what fixes
# the pinched-wrist / pinched-ankle hulls that show up once the cascade folds
# twist-bone vertices into the parent limb's bucket.
#
# Allocation per band: a floor of `_STRATIFY_FLOOR` points (so even sparse
# end caps still get a polygon), plus a proportional share of the leftover
# budget weighted by the band's vertex count. Bands with no input contribute
# nothing.
static func stratified_furthest_point_sample(
		points: PackedVector3Array, k: int) -> PackedVector3Array:
	var n: int = points.size()
	if n <= k:
		return points
	# Find the bucket's AABB and the index (0/1/2) of its longest axis.
	var aabb_min: Vector3 = points[0]
	var aabb_max: Vector3 = points[0]
	for i: int in range(1, n):
		var p: Vector3 = points[i]
		aabb_min = aabb_min.min(p)
		aabb_max = aabb_max.max(p)
	var size: Vector3 = aabb_max - aabb_min
	var axis: int = 0
	if size.y > size[axis]:
		axis = 1
	if size.z > size[axis]:
		axis = 2
	var span: float = size[axis]
	# Degenerate (planar / collinear) bucket — fall back to plain FPS to
	# avoid div-by-zero on the band partition.
	if span <= 1e-6:
		return furthest_point_sample(points, k)
	# Bin every input vertex into a band by its position along `axis`.
	var bands: Array[PackedVector3Array] = []
	bands.resize(_STRATIFY_BANDS)
	for bi: int in _STRATIFY_BANDS:
		bands[bi] = PackedVector3Array()
	var axis_min: float = aabb_min[axis]
	for i: int in n:
		var t: float = (points[i][axis] - axis_min) / span
		var bi: int = clampi(int(t * _STRATIFY_BANDS), 0, _STRATIFY_BANDS - 1)
		bands[bi].append(points[i])
	# Allocate per-band quotas: floor + proportional share of the leftover.
	# Empty bands contribute nothing; their quota becomes 0 and the floor
	# rolls over into the proportional pool.
	var occupied: int = 0
	for bi: int in _STRATIFY_BANDS:
		if bands[bi].size() > 0:
			occupied += 1
	var floor_total: int = min(_STRATIFY_FLOOR * occupied, k)
	var leftover: int = k - floor_total
	var quotas: Array[int] = []
	quotas.resize(_STRATIFY_BANDS)
	var assigned: int = 0
	for bi: int in _STRATIFY_BANDS:
		var sz: int = bands[bi].size()
		if sz == 0:
			quotas[bi] = 0
			continue
		var prop: int = int(round(float(leftover) * float(sz) / float(n)))
		quotas[bi] = min(sz, _STRATIFY_FLOOR + prop)
		assigned += quotas[bi]
	# Rounding leftovers / cap clamps may leave us short of k. Distribute
	# the remainder to bands that still have headroom (largest band first).
	var deficit: int = k - assigned
	while deficit > 0:
		var best_bi: int = -1
		var best_room: int = 0
		for bi: int in _STRATIFY_BANDS:
			var room: int = bands[bi].size() - quotas[bi]
			if room > best_room:
				best_room = room
				best_bi = bi
		if best_bi < 0:
			break
		var add: int = min(deficit, best_room)
		quotas[best_bi] += add
		deficit -= add
	# Run FPS inside each band with its quota. Concatenate.
	var out := PackedVector3Array()
	for bi: int in _STRATIFY_BANDS:
		var q: int = quotas[bi]
		if q <= 0:
			continue
		out.append_array(furthest_point_sample(bands[bi], q))
	return out


# Picks the per-bone hull input set: stratified FPS at the cap. Sub-4 input
# is returned untouched (Jolt won't hull a degenerate set). The cap is now
# the binding constraint — there's no early-stop because the previous
# silhouette-quality criterion measured global directional extent and would
# happily certify a hull that pinched at the wrist as long as the long-axis
# extent stayed within tolerance.
static func find_optimal_decimation(
		points: PackedVector3Array,
		max_points: int) -> PackedVector3Array:
	var n: int = points.size()
	if n <= 4:
		return points
	return stratified_furthest_point_sample(points, min(max_points, n))


# Scales each point inward toward the centroid by `shrink` (0..0.5).
# Operates in bone-local space so the centroid is meaningful per-bone.
static func apply_shrink(points: PackedVector3Array, shrink: float) -> PackedVector3Array:
	if shrink <= 0.0 or points.is_empty():
		return points
	var centroid := Vector3.ZERO
	for p: Vector3 in points:
		centroid += p
	centroid /= float(points.size())
	var keep: float = 1.0 - clamp(shrink, 0.0, 0.5)
	var out := PackedVector3Array()
	out.resize(points.size())
	for i: int in points.size():
		out[i] = centroid + (points[i] - centroid) * keep
	return out


# AABB-overlap detection in skeleton-rest space. Each bone's hull points
# are transformed via the bone's global rest, then bracketed by an AABB;
# pairs whose AABBs intersect become exclusion entries. Coarse — a hull
# whose AABB intersects another's AABB doesn't necessarily share volume —
# but it's the right side to err on: false positives just exclude pairs
# that wouldn't have collided anyway, while false negatives let the
# physics chain explode.
#
# Parent-child pairs are still added; consumers (Marionette
# _apply_collision_exclusions) merge these with the standard
# CollisionExclusionProfile and dedupe naturally via Jolt's exception
# list (repeat add_collision_exception_with calls are no-ops).
static func compute_overlap_pairs(
		profile: BoneCollisionProfile,
		skel: Skeleton3D,
		bone_map: BoneMap) -> Array[Vector2i]:
	var pairs: Array[Vector2i] = []
	if profile == null or skel == null:
		return pairs
	# Resolve every hull's bone index + AABB once.
	var entries: Array[Dictionary] = []
	for bone_name: StringName in profile.hulls.keys():
		var pts: PackedVector3Array = profile.hulls[bone_name]
		if pts.size() < 4:
			continue
		var skel_idx: int = _profile_to_skel_index(bone_name, skel, bone_map)
		if skel_idx < 0:
			continue
		var bone_global: Transform3D = skel.get_bone_global_rest(skel_idx)
		var aabb := AABB(bone_global * pts[0], Vector3.ZERO)
		for i: int in range(1, pts.size()):
			aabb = aabb.expand(bone_global * pts[i])
		entries.append({"idx": skel_idx, "aabb": aabb})
	for i: int in entries.size():
		for j: int in range(i + 1, entries.size()):
			var a_aabb: AABB = entries[i]["aabb"]
			var b_aabb: AABB = entries[j]["aabb"]
			if a_aabb.intersects(b_aabb):
				var ai: int = entries[i]["idx"]
				var bi: int = entries[j]["idx"]
				pairs.append(Vector2i(min(ai, bi), max(ai, bi)))
	return pairs


# Profile bone name -> skeleton bone index. Direct skeleton lookup first
# (covers the post-retarget rig where bone names already match the
# profile, which is the kasumi pipeline) and a reverse-walk through the
# BoneMap as fallback for the legacy pre-retarget case.
#
# We deliberately *don't* call `bone_map.get_skeleton_bone_name` here:
# Godot pushes an ERROR for any name not in the map, which spams the log
# every time the harvest produces an ARP-helper bone the canonical
# BoneMap doesn't know about. find_profile_bone_name is silent on miss.
static func _profile_to_skel_index(
		profile_name: StringName,
		skel: Skeleton3D,
		bone_map: BoneMap) -> int:
	var direct: int = skel.find_bone(profile_name)
	if direct >= 0:
		return direct
	if bone_map == null:
		return -1
	for i: int in skel.get_bone_count():
		var skel_name: StringName = StringName(skel.get_bone_name(i))
		if bone_map.find_profile_bone_name(skel_name) == profile_name:
			return i
	return -1
