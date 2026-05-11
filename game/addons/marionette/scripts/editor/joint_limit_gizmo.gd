@tool
class_name MarionetteJointLimitGizmo
extends EditorNode3DGizmoPlugin

# Singleton handle for synchronous redraw from editor scripts — see
# MarionetteAuthoringGizmo for the rationale.
static var _instance: MarionetteJointLimitGizmo


static func redraw_for_node(node: Node3D) -> void:
	if _instance == null or node == null:
		return
	for gizmo: EditorNode3DGizmo in _instance.get_current_gizmos():
		if not is_instance_valid(gizmo):
			continue
		if gizmo.get_node_3d() == node:
			_instance._redraw(gizmo)

# P3.9 — per-bone ROM arcs at each bone's joint origin. Arcs live in
# joint-local space; after build_ragdoll bakes joint_rotation that frame
# equals anatomical (CLAUDE.md §3), so the same arcs match what the user
# sees in the diagnostic dock and the inspector ROM fields.
#
#   red   = flex sweep (rotation around joint-local +X) — arc in YZ plane
#   green = rotation sweep (around joint-local +Y)      — arc in XZ plane
#   blue  = abduction sweep (around joint-local +Z)     — arc in XY plane
#
# Attaches to the Marionette node (not per MarionetteBone): selecting the
# Marionette shows every bone's ROM at once, which is what authoring needs.
# Only bones with non-zero ROM in the BoneProfile get arcs; ROOT / FIXED /
# locked-axis archetypes (matcher-skipped or zero-range) are silently
# omitted so the viewport stays scannable.
#
# Data path mirrors MarionetteAuthoringGizmo: live skeleton + bone_map when
# both available, else SkeletonProfile reference poses.

const _ARC_FRACTION: float = 0.32
const _ARC_FLOOR: float = 0.03
const _BASE_SEGMENTS: int = 14
const _MIN_RANGE: float = 0.001  # below this, treat the axis as locked

const _MAT_FLEX: StringName = &"jl_flex"
const _MAT_ROT: StringName = &"jl_rot"
const _MAT_ABD: StringName = &"jl_abd"

# Distinct from the authoring gizmo's saturated R/G/B (which mark the
# tripod axes); the ROM arcs use slightly desaturated tones so the eye
# can tell tripod-axis from sweep-arc at a glance.
const _COL_FLEX: Color = Color(1.0, 0.35, 0.35)
const _COL_ROT: Color = Color(0.4, 1.0, 0.4)
const _COL_ABD: Color = Color(0.4, 0.55, 1.0)


func _init() -> void:
	_instance = self
	create_material(_MAT_FLEX, _COL_FLEX, false, true)
	create_material(_MAT_ROT, _COL_ROT, false, true)
	create_material(_MAT_ABD, _COL_ABD, false, true)


# Higher than authoring (1) so arcs draw above tripods at the same origin.
func _get_priority() -> int:
	return 2


func _get_gizmo_name() -> String:
	return "Marionette Joint Limits"


func _has_gizmo(for_node_3d: Node3D) -> bool:
	return for_node_3d is Marionette


func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var node: Marionette = gizmo.get_node_3d() as Marionette
	if node == null:
		return
	var bp: BoneProfile = node.bone_profile
	if bp == null or bp.skeleton_profile == null or bp.bones.is_empty():
		return
	var profile: SkeletonProfile = bp.skeleton_profile

	var live_skeleton: Skeleton3D = node.resolve_skeleton()
	var bone_map: BoneMap = node.bone_map
	var use_live: bool = live_skeleton != null and bone_map != null

	# Live path uses "rest in current parent's frame" — the wedge tracks the
	# parent (so an elbow's ROM wedge follows the upper arm when the shoulder
	# rotates) but stays still when the bone itself rotates (so the forearm
	# sweeps *through* a stationary elbow wedge between rom_min and rom_max
	# instead of dragging the wedge along with it). Template path stays on
	# rest since there's no live skeleton to follow.
	var world_rests: Dictionary[StringName, Transform3D]
	var source_to_local: Transform3D = Transform3D.IDENTITY
	if use_live:
		world_rests = MuscleFrameBuilder.compute_skeleton_rest_in_live_parent(live_skeleton, profile, bone_map)
		source_to_local = node.global_transform.affine_inverse() * live_skeleton.global_transform
	else:
		world_rests = MuscleFrameBuilder.compute_world_rests(profile)

	if world_rests.is_empty():
		return

	var first_child: Dictionary[StringName, StringName] = {}
	for i in range(profile.bone_size):
		var pn: StringName = profile.get_bone_parent(i)
		if pn != &"" and not first_child.has(pn):
			first_child[pn] = profile.get_bone_name(i)

	for bone_name: StringName in bp.bones.keys():
		var entry: BoneEntry = bp.bones[bone_name]
		if entry == null:
			continue
		# Skip locked / matcher-skipped bones (ROOT, FIXED, default-zero ROM).
		if entry.rom_min == Vector3.ZERO and entry.rom_max == Vector3.ZERO:
			continue
		if not world_rests.has(bone_name):
			continue

		var bone_world: Transform3D = world_rests[bone_name]
		var radius: float = _ARC_FLOOR
		if first_child.has(bone_name) and world_rests.has(first_child[bone_name]):
			var child_origin: Vector3 = world_rests[first_child[bone_name]].origin
			radius = max((child_origin - bone_world.origin).length() * _ARC_FRACTION, _ARC_FLOOR)

		var origin: Vector3 = source_to_local * bone_world.origin
		# Joint frame in source space = bone rest basis composed with the
		# bone-local anatomical frame (signed permutation OR calculated-frame
		# fallback, decided by entry.use_calculated_frame). Then bring into
		# Marionette-local for draw.
		var joint_in_source: Basis = bone_world.basis * entry.anatomical_basis_in_bone_local()
		var draw_basis: Basis = source_to_local.basis * joint_in_source

		# Arcs are drawn in joint-local space (joint identity = rest pose), so
		# canonical-anatomy bounds (rom_min/rom_max) shift by `-rest_offset`
		# — the same shift `_apply_joint_constraints` applies to Jolt limits.
		# On T-pose rigs rest_offset = 0 so the arc renders unchanged.
		var rest_offset: Vector3 = entry.rest_anatomical_offset
		# Flex: rotate +Y (along-bone) around +X (flex axis).
		_draw_arc(gizmo, origin, draw_basis, Vector3.RIGHT, Vector3.UP,
				entry.rom_min.x - rest_offset.x, entry.rom_max.x - rest_offset.x,
				radius, _MAT_FLEX)
		# Rotation: rotate +X (flex axis) around +Y (along-bone). Doesn't move
		# the bone tip but visualizes the twist range as a fan in joint-XZ.
		# Right-side BALL / CLAVICLE bones have their +med-rot input negated
		# at apply time (`AnatomicalPose.bone_local_rotation`), so the wedge
		# has to sweep the opposite direction to match the bone's actual
		# travel — otherwise the bone moves *out* of the displayed wedge as
		# the slider runs from rom_min to rom_max.
		var rot_min: float = entry.rom_min.y - rest_offset.y
		var rot_max: float = entry.rom_max.y - rest_offset.y
		var is_right_sided_med: bool = (
				not entry.is_left_side
				and (entry.archetype == BoneArchetype.Type.BALL
					or entry.archetype == BoneArchetype.Type.CLAVICLE))
		if is_right_sided_med:
			var t: float = rot_min
			rot_min = -rot_max
			rot_max = -t
		_draw_arc(gizmo, origin, draw_basis, Vector3.UP, Vector3.RIGHT,
				rot_min, rot_max, radius, _MAT_ROT)
		# Abduction: rotate +Y around +Z. mirror_abd flips the runtime sign
		# of +abd input (so anatomical abduction lands consistently across
		# left/right side chirality) — sweep the wedge the opposite way for
		# those bones for the same reason as the rotation arc above.
		var abd_min: float = entry.rom_min.z - rest_offset.z
		var abd_max: float = entry.rom_max.z - rest_offset.z
		if entry.mirror_abd:
			var t: float = abd_min
			abd_min = -abd_max
			abd_max = -t
		_draw_arc(gizmo, origin, draw_basis, Vector3.BACK, Vector3.UP,
				abd_min, abd_max, radius, _MAT_ABD)


# Draws an arc in the plane perpendicular to `rot_axis_local`, sweeping
# `start_dir_local` from `min_angle` to `max_angle`. Both vectors are
# expressed in the joint-local frame; `draw_basis` rotates them into the
# source frame Marionette draws in. Adds two radial boundary lines so the
# user can read min/max as terminal positions, not just sweep endpoints.
func _draw_arc(
		gizmo: EditorNode3DGizmo,
		origin: Vector3,
		draw_basis: Basis,
		rot_axis_local: Vector3,
		start_dir_local: Vector3,
		min_angle: float,
		max_angle: float,
		radius: float,
		mat_name: StringName) -> void:
	var span: float = max_angle - min_angle
	if absf(span) < _MIN_RANGE:
		return
	# Normalize: `draw_basis` accumulates the skeleton rest basis (which can
	# carry scale, e.g. Blender's bone roll matrices) and the source-to-local
	# transform, so even unit local vectors come out non-unit. Basis(axis, θ)
	# errors on non-unit axes — the spam is loud (3 arcs × N bones each
	# redraw). Normalizing also gives the radius a predictable meaning.
	var rot_axis: Vector3 = (draw_basis * rot_axis_local).normalized()
	var start_dir: Vector3 = (draw_basis * start_dir_local).normalized()
	if rot_axis == Vector3.ZERO or start_dir == Vector3.ZERO:
		return
	# Roughly one segment per 6° of sweep, floor at _BASE_SEGMENTS so tiny
	# spans still render visibly.
	var seg: int = max(_BASE_SEGMENTS, int(absf(span) * 30.0))

	var pts: PackedVector3Array = PackedVector3Array()
	var prev: Vector3 = origin + (Basis(rot_axis, min_angle) * start_dir) * radius
	for i in range(1, seg + 1):
		var t: float = float(i) / float(seg)
		var angle: float = lerp(min_angle, max_angle, t)
		var pt: Vector3 = origin + (Basis(rot_axis, angle) * start_dir) * radius
		pts.append(prev)
		pts.append(pt)
		prev = pt
	# Boundary radials.
	pts.append(origin)
	pts.append(origin + (Basis(rot_axis, min_angle) * start_dir) * radius)
	pts.append(origin)
	pts.append(origin + (Basis(rot_axis, max_angle) * start_dir) * radius)
	gizmo.add_lines(pts, get_material(mat_name, gizmo))
