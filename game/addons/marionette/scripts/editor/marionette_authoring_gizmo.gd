@tool
class_name MarionetteAuthoringGizmo
extends EditorNode3DGizmoPlugin

# Singleton handle: the EditorPlugin only ever instantiates one of these. We
# stash the live instance so editor-side scripts (e.g., MarionetteBoneSliders)
# can request a synchronous redraw without walking the EditorPlugin tree. The
# deferred Node3D.update_gizmos() path doesn't reliably drive the gizmo
# scheduler from @tool scripts, so this static path exists as the workaround.
static var _instance: MarionetteAuthoringGizmo


# Iterates every active gizmo of this plugin owned by `node` and runs
# `_redraw` directly. Synchronous; safe to call mid-pose-change.
static func redraw_for_node(node: Node3D) -> void:
	if _instance == null or node == null:
		return
	for gizmo: EditorNode3DGizmo in _instance.get_current_gizmos():
		if not is_instance_valid(gizmo):
			continue
		if gizmo.get_node_3d() == node:
			_instance._redraw(gizmo)

# Authoring-time gizmo for visually verifying P2.6 (archetype solvers) and
# P2.7 (muscle frame builder) on a Marionette node before the rest of Phase 2
# lands (no editor button, no shipped BoneProfile yet).
#
# Activates whenever a Marionette node is selected. Reads the SkeletonProfile
# off the assigned BoneProfile. Renders:
#
#   1. The muscle frame as a large CMY tripod at the hip midpoint.
#         magenta = character right
#         cyan    = up (toward head)
#         white   = forward (mesh-facing)
#
#   2. A medium saturated RGB tripod at each bone's world-rest origin:
#         red   = flex axis     (anatomical +X)
#         green = along-bone    (anatomical +Y)
#         blue  = abduction     (anatomical +Z)
#
#      Bones whose rest basis fails the permutation matcher (P2.8) draw all
#      three axes in saturated yellow.
#
# Materials: one per color, registered in _init with stable names. We do
# *not* route color through add_lines's `modulate` parameter — in 4.6 that
# argument doesn't reliably tint lines on top-rendered materials.

const _MUSCLE_FRAME_LENGTH: float = 0.4

# Per-bone tripod arms scale with bone-to-child distance, so a humerus
# gets a long tripod and a finger phalanx a short one — matching Godot's
# default Skeleton3D gizmo's bone-length-aware drawing. Constants below
# are the multiplier (fraction of bone length) and a floor in meters so
# zero-length terminal bones still draw something visible.
const _BONE_FRAME_FRACTION: float = 0.45
const _BONE_FRAME_MIN: float = 0.02

# Material names — also serve as the per-color keys.
const _MAT_MUSCLE_X: StringName = &"muscle_x"
const _MAT_MUSCLE_Y: StringName = &"muscle_y"
const _MAT_MUSCLE_Z: StringName = &"muscle_z"
const _MAT_BONE_X: StringName = &"bone_x"
const _MAT_BONE_Y: StringName = &"bone_y"
const _MAT_BONE_Z: StringName = &"bone_z"
const _MAT_BONE_UNMATCHED: StringName = &"bone_unmatched"

# Muscle-frame palette (CMY-ish; chosen to contrast with the default
# Skeleton3D gizmo's orange-yellow fan).
const _COL_MUSCLE_X: Color = Color(1.0, 0.0, 0.7)   # magenta
const _COL_MUSCLE_Y: Color = Color(0.0, 1.0, 1.0)   # cyan
const _COL_MUSCLE_Z: Color = Color(1.0, 1.0, 1.0)   # white

# Per-bone palette (saturated RGB for XYZ-gizmo convention).
const _COL_BONE_X: Color = Color(1.0, 0.0, 0.05)
const _COL_BONE_Y: Color = Color(0.0, 1.0, 0.1)
const _COL_BONE_Z: Color = Color(0.1, 0.3, 1.0)

# Unmatched bones (P2.8 below threshold).
const _COL_BONE_UNMATCHED: Color = Color(1.0, 1.0, 0.0)


func _init() -> void:
	_instance = self
	# on_top=true on every material so our lines win against the default
	# Skeleton3D gizmo's bone fan. EditorNode3DGizmoPlugin.create_material
	# signature: (name, color, billboard, on_top, use_vertex_color).
	create_material(_MAT_MUSCLE_X, _COL_MUSCLE_X, false, true)
	create_material(_MAT_MUSCLE_Y, _COL_MUSCLE_Y, false, true)
	create_material(_MAT_MUSCLE_Z, _COL_MUSCLE_Z, false, true)
	create_material(_MAT_BONE_X, _COL_BONE_X, false, true)
	create_material(_MAT_BONE_Y, _COL_BONE_Y, false, true)
	create_material(_MAT_BONE_Z, _COL_BONE_Z, false, true)
	create_material(_MAT_BONE_UNMATCHED, _COL_BONE_UNMATCHED, false, true)


# Render after Godot's built-in Skeleton3D gizmo so our lines win the
# z-fight when on_top is on. EditorNode3DGizmoPlugin._get_priority returns
# int in 4.6 (negative = drawn earlier; we want a higher number).
func _get_priority() -> int:
	return 1


func _get_gizmo_name() -> String:
	return "Marionette Authoring"


func _has_gizmo(for_node_3d: Node3D) -> bool:
	return for_node_3d is Marionette


func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var node: Marionette = gizmo.get_node_3d() as Marionette
	if node == null:
		return
	var bp: BoneProfile = node.bone_profile
	if bp == null or bp.skeleton_profile == null:
		return
	var profile: SkeletonProfile = bp.skeleton_profile
	if profile.bone_size == 0:
		return

	var live_skeleton: Skeleton3D = node.resolve_skeleton()
	var bone_map: BoneMap = node.bone_map
	var use_live: bool = live_skeleton != null and bone_map != null

	var world_rests: Dictionary[StringName, Transform3D]
	var muscle_frame: MuscleFrame
	# `source_to_local` transforms a point from the data source's frame into
	# the Marionette node's local frame (gizmo coords). For template data
	# the source frame is the Marionette's own local frame, so it's identity.
	# For live data, points come in skeleton-local coords and we need to go
	# skeleton-local -> world -> marionette-local.
	var source_to_local: Transform3D = Transform3D.IDENTITY
	if use_live:
		# Use current poses so per-bone tripods follow the armature when the
		# muscle-test sliders pose bones. Muscle frame still derives from
		# rest topology (hip mid + head bone).
		world_rests = MuscleFrameBuilder.compute_skeleton_global_poses(live_skeleton, profile, bone_map)
		muscle_frame = MuscleFrameBuilder.build_from_skeleton(live_skeleton, profile, bone_map)
		source_to_local = node.global_transform.affine_inverse() * live_skeleton.global_transform
	else:
		world_rests = MuscleFrameBuilder.compute_world_rests(profile)
		muscle_frame = MuscleFrameBuilder.build(profile)

	if world_rests.is_empty():
		return

	var hip_mid: Vector3 = _hip_midpoint_from_rests(world_rests)
	_draw_muscle_frame(gizmo, source_to_local * hip_mid, muscle_frame, source_to_local.basis)
	_draw_per_bone_targets(gizmo, profile, world_rests, muscle_frame, source_to_local)


static func _hip_midpoint_from_rests(world_rests: Dictionary[StringName, Transform3D]) -> Vector3:
	if world_rests.has(&"LeftUpperLeg") and world_rests.has(&"RightUpperLeg"):
		return (world_rests[&"LeftUpperLeg"].origin + world_rests[&"RightUpperLeg"].origin) * 0.5
	if world_rests.has(&"Hips"):
		return world_rests[&"Hips"].origin
	return Vector3.ZERO


func _draw_line(gizmo: EditorNode3DGizmo, a: Vector3, b: Vector3, mat_name: StringName) -> void:
	gizmo.add_lines(_segment(a, b), get_material(mat_name, gizmo))


func _draw_muscle_frame(
		gizmo: EditorNode3DGizmo,
		origin: Vector3,
		frame: MuscleFrame,
		direction_basis: Basis) -> void:
	var len: float = _MUSCLE_FRAME_LENGTH
	_draw_line(gizmo, origin, origin + (direction_basis * frame.right) * len, _MAT_MUSCLE_X)
	_draw_line(gizmo, origin, origin + (direction_basis * frame.up) * len, _MAT_MUSCLE_Y)
	_draw_line(gizmo, origin, origin + (direction_basis * frame.forward) * len, _MAT_MUSCLE_Z)


func _draw_per_bone_targets(
		gizmo: EditorNode3DGizmo,
		profile: SkeletonProfile,
		world_rests: Dictionary[StringName, Transform3D],
		muscle_frame: MuscleFrame,
		source_to_local: Transform3D) -> void:
	var bone_count: int = profile.bone_size
	# Build an index from parent-name to the first child's world-rest for the
	# child-hint each solver needs. SkeletonProfile.get_bone_tail() returns
	# an explicit tail when tail_direction == 1, otherwise we fall back to
	# scanning for the first child bone.
	var first_child: Dictionary[StringName, StringName] = {}
	for i in range(bone_count):
		var parent_name: StringName = profile.get_bone_parent(i)
		if parent_name != &"" and not first_child.has(parent_name):
			first_child[parent_name] = profile.get_bone_name(i)

	var direction_basis: Basis = source_to_local.basis
	for i in range(bone_count):
		var bone_name: StringName = profile.get_bone_name(i)
		var archetype: int = MarionetteArchetypeDefaults.archetype_for_bone(bone_name)
		if archetype < 0:
			continue
		# Skip bones not present in the data source (live skeleton may not
		# have every template bone mapped/found).
		if not world_rests.has(bone_name):
			continue
		var bone_world: Transform3D = world_rests[bone_name]

		# Resolve child world-rest. Order: explicit tail bone (tail_direction==1),
		# else first listed child, else nudge along bone-local +Y.
		var child_world: Transform3D = bone_world
		var explicit_tail: StringName = profile.get_bone_tail(i)
		var has_real_child: bool = false
		if explicit_tail != &"" and world_rests.has(explicit_tail):
			child_world = world_rests[explicit_tail]
			has_real_child = true
		elif first_child.has(bone_name) and world_rests.has(first_child[bone_name]):
			child_world = world_rests[first_child[bone_name]]
			has_real_child = true
		else:
			# Synthesize: bone origin + small step along bone-local +Y. Only
			# used to give the solver a non-degenerate hint; tripod length
			# falls back to _BONE_FRAME_MIN below.
			var nudge: Vector3 = bone_world.basis.y.normalized() * _BONE_FRAME_MIN
			if nudge == Vector3.ZERO:
				nudge = Vector3(0.0, _BONE_FRAME_MIN, 0.0)
			child_world = bone_world
			child_world.origin = bone_world.origin + nudge

		var is_left_side: bool = String(bone_name).begins_with("Left")
		var parent_name: StringName = profile.get_bone_parent(i)
		var parent_world: Transform3D = world_rests[parent_name] if (parent_name != &"" and world_rests.has(parent_name)) else Transform3D()
		var target_basis: Basis = MarionetteArchetypeSolverDispatch.solve(
				archetype, bone_world, child_world, muscle_frame, is_left_side, parent_world)

		# What gets drawn = what gets baked.
		#   ROOT / FIXED: no SPD frame; show the target so the muscle frame
		#     derivation is still visualizable. Saturated RGB.
		#   Matched SPD bone: show the permuted bone basis the matcher
		#     committed to — the actual joint frame after baking. Saturated
		#     RGB.
		#   Unmatched SPD bone: the generator falls back to baking the
		#     calculated target; that *is* the joint frame at runtime. Yellow
		#     to signal the rig couldn't axis-align cleanly here.
		var draw_basis_in_source: Basis = target_basis
		var unmatched: bool = false
		if archetype != BoneArchetype.Type.ROOT and archetype != BoneArchetype.Type.FIXED:
			var match_result: MarionettePermutationMatch = MarionettePermutationMatcher.find_match(
					bone_world.basis, target_basis)
			unmatched = not match_result.matched
			if not unmatched:
				var perm: Basis = Basis(
						SignedAxis.to_vector3(match_result.flex_axis),
						SignedAxis.to_vector3(match_result.along_bone_axis),
						SignedAxis.to_vector3(match_result.abduction_axis))
				draw_basis_in_source = bone_world.basis * perm

		var origin: Vector3 = source_to_local * bone_world.origin
		# Bone length drives tripod size — long bones (humerus, femur) get
		# long arms; phalanges get short ones. Floor at _BONE_FRAME_MIN so
		# zero-length terminal bones still render.
		var bone_length: float = (child_world.origin - bone_world.origin).length() if has_real_child else 0.0
		var len: float = max(bone_length * _BONE_FRAME_FRACTION, _BONE_FRAME_MIN)
		var mat_x: StringName = _MAT_BONE_UNMATCHED if unmatched else _MAT_BONE_X
		var mat_y: StringName = _MAT_BONE_UNMATCHED if unmatched else _MAT_BONE_Y
		var mat_z: StringName = _MAT_BONE_UNMATCHED if unmatched else _MAT_BONE_Z
		_draw_line(gizmo, origin, origin + (direction_basis * draw_basis_in_source.x) * len, mat_x)
		_draw_line(gizmo, origin, origin + (direction_basis * draw_basis_in_source.y) * len, mat_y)
		_draw_line(gizmo, origin, origin + (direction_basis * draw_basis_in_source.z) * len, mat_z)


static func _segment(a: Vector3, b: Vector3) -> PackedVector3Array:
	var arr: PackedVector3Array = PackedVector3Array()
	arr.append(a)
	arr.append(b)
	return arr
