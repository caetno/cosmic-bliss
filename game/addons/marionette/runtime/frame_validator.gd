@tool
class_name MarionetteFrameValidator
extends RefCounted

# Diagnostic for joint frames. Compares the BoneEntry-baked anatomical basis
# against the solver target basis (re-derived on the spot from muscle frame
# + archetype dispatch). Both bases are expressed in world space (composed
# with the bone's parent rest), so the comparison is rotation-only — no
# coordinate-system gotchas.
#
# Per axis we report cos(angle) between the baked column and the target
# column. The classification thresholds are:
#
#   OK      — every axis dot >= 0.95  (within ~18°)
#   WEAK    — every axis dot >= 0.70  (within ~45°), still same hemisphere
#   FLIPPED — at least one axis dot <= -0.50 — sign error (matcher picked
#             the wrong sign on a permutation candidate, or solver returned
#             the wrong half of a cross product)
#   SWAPPED — baked X is closer to target Y or Z than to target X (or
#             likewise for Y/Z): wrong axis was selected by the matcher
#   BAD     — none of the above; geometry is far from any cardinal pick
#
# Usage from the Marionette button:
#   var report := MarionetteFrameValidator.validate(bone_profile, skeleton, bone_map)
#   for d in report.diagnoses: print(d.format_line())
#
# The validator is *static analysis* — it doesn't perturb the live skeleton.
# It catches matcher / solver disagreements regardless of pose. A future
# dynamic test (apply +flex, observe child motion) is a separate addition;
# static catches every issue we've hit so far.

const _OK_THRESHOLD: float = 0.95
const _WEAK_THRESHOLD: float = 0.70
const _FLIP_THRESHOLD: float = -0.50


class BoneDiagnosis extends RefCounted:
	var bone_name: StringName
	var archetype_name: String
	var has_entry: bool = false
	var uses_calculated_frame: bool = false
	var matcher_score: float = 0.0
	# cos(angle) between baked-anatomical-column and target-anatomical-column
	# in world space, per anatomical axis.
	var flex_dot: float = 0.0
	var along_dot: float = 0.0
	var abd_dot: float = 0.0
	# Cross-axis dots — used to detect SWAPPED. baked_x_dot_target_y means
	# "the baked flex column ends up pointing where the target along-bone
	# column points." High cross-axis dot = matcher picked the wrong axis.
	var swap_baked_x_to_y: float = 0.0
	var swap_baked_x_to_z: float = 0.0
	var swap_baked_y_to_x: float = 0.0
	var swap_baked_y_to_z: float = 0.0
	var swap_baked_z_to_x: float = 0.0
	var swap_baked_z_to_y: float = 0.0
	var status: String = ""
	var notes: String = ""

	func format_line() -> String:
		var fr_marker: String = " (calc)" if uses_calculated_frame else ""
		# matcher_score: rig calibration signal. With use_calculated_frame=true
		# (the runtime default) the joint frame is exactly the solver target —
		# motion is correct regardless. A low matcher score just means the rig's
		# bone roll is far from the anatomical axes, so the calculated frame
		# ends up tilted in bone-local space (visualizations show non-axis-
		# aligned tripods). High score = rig is cleanly aligned, gizmos look
		# crisp; low score = calibration signal worth investigating in Blender.
		return "  %-28s %-8s%s %-8s flex=%+0.2f along=%+0.2f abd=%+0.2f  matcher=%+0.2f  %s" % [
				bone_name, archetype_name, fr_marker, status,
				flex_dot, along_dot, abd_dot, matcher_score, notes]


class ValidationReport extends RefCounted:
	var diagnoses: Array[BoneDiagnosis] = []
	var ok_count: int = 0
	var weak_count: int = 0
	var flipped_count: int = 0
	var swapped_count: int = 0
	var bad_count: int = 0
	var skipped_count: int = 0
	var error: String = ""

	func by_status(status: String) -> Array[StringName]:
		var out: Array[StringName] = []
		for d: BoneDiagnosis in diagnoses:
			if d.status == status:
				out.append(d.bone_name)
		return out


static func validate(
		bone_profile: BoneProfile,
		live_skeleton: Skeleton3D = null,
		bone_map: BoneMap = null) -> ValidationReport:
	var report := ValidationReport.new()
	if bone_profile == null:
		report.error = "bone_profile is null"
		return report
	var profile: SkeletonProfile = bone_profile.skeleton_profile
	if profile == null:
		report.error = "bone_profile.skeleton_profile is null"
		return report

	# Re-derive solver inputs the same way BoneProfileGenerator does so the
	# comparison reflects what would be baked on a regenerate.
	var use_live: bool = live_skeleton != null and bone_map != null
	var world_rests: Dictionary[StringName, Transform3D]
	var muscle_frame: MuscleFrame
	if use_live:
		world_rests = MuscleFrameBuilder.compute_skeleton_world_rests(live_skeleton, profile, bone_map)
		muscle_frame = MuscleFrameBuilder.build_from_skeleton(live_skeleton, profile, bone_map)
	else:
		world_rests = MuscleFrameBuilder.compute_world_rests(profile)
		muscle_frame = MuscleFrameBuilder.build(profile)

	var first_child: Dictionary[StringName, StringName] = {}
	for i in range(profile.bone_size):
		var parent_name: StringName = profile.get_bone_parent(i)
		if parent_name != &"" and not first_child.has(parent_name):
			first_child[parent_name] = profile.get_bone_name(i)

	for i in range(profile.bone_size):
		var bone_name: StringName = profile.get_bone_name(i)
		var archetype: int = MarionetteArchetypeDefaults.archetype_for_bone(bone_name)
		if archetype < 0:
			report.skipped_count += 1
			continue
		# Skip ROOT/FIXED — solver targets are placeholder for those, no
		# anatomical frame meaning. Same exclusions as the generator.
		if archetype == BoneArchetype.Type.ROOT or archetype == BoneArchetype.Type.FIXED:
			report.skipped_count += 1
			continue
		if not world_rests.has(bone_name):
			report.skipped_count += 1
			continue

		var diag := BoneDiagnosis.new()
		diag.bone_name = bone_name
		diag.archetype_name = BoneArchetype.to_name(archetype)
		var entry: BoneEntry = bone_profile.get_entry(bone_name)
		if entry == null:
			diag.status = "NO_ENTRY"
			diag.notes = "bone has archetype but no BoneEntry — regenerate the profile"
			report.diagnoses.append(diag)
			continue
		diag.has_entry = true
		diag.uses_calculated_frame = entry.use_calculated_frame

		var bone_world: Transform3D = world_rests[bone_name]
		var child_world: Transform3D = _resolve_child_world(profile, i, bone_world, world_rests, first_child)
		var parent_name: StringName = profile.get_bone_parent(i)
		var parent_world: Transform3D = world_rests[parent_name] if (parent_name != &"" and world_rests.has(parent_name)) else Transform3D()
		var is_left_side: bool = String(bone_name).begins_with("Left")

		# Solver target in bone-parent space (i.e., the same frame as
		# bone_world.basis). Compose with bone_world.basis to get world.
		var motion_target: Vector3 = MarionetteSolverUtils.anatomical_motion_target(
				bone_name, archetype, muscle_frame)
		var target_basis: Basis = MarionetteArchetypeSolverDispatch.solve(
				archetype, bone_world, child_world, muscle_frame, is_left_side,
				parent_world, motion_target)
		# Baked frame: BoneEntry's anatomical basis (signed permutation OR
		# calculated frame) is in BONE-LOCAL space; compose with bone_world.basis
		# to get world.
		var baked_in_bone_local: Basis = entry.anatomical_basis_in_bone_local()
		var baked_world: Basis = bone_world.basis * baked_in_bone_local

		var matcher: MarionettePermutationMatch = MarionettePermutationMatcher.find_match(
				bone_world.basis, target_basis)
		diag.matcher_score = matcher.score

		# target_basis is in *parent* space; bone_world.basis is also in
		# parent-space-relative-to-skeleton. Both are world-space orthonormal
		# rotations from the skeleton root. Direct dot product.
		var bx: Vector3 = baked_world.x.normalized()
		var by: Vector3 = baked_world.y.normalized()
		var bz: Vector3 = baked_world.z.normalized()
		var tx: Vector3 = target_basis.x.normalized()
		var ty: Vector3 = target_basis.y.normalized()
		var tz: Vector3 = target_basis.z.normalized()

		diag.flex_dot = bx.dot(tx)
		diag.along_dot = by.dot(ty)
		diag.abd_dot = bz.dot(tz)
		diag.swap_baked_x_to_y = bx.dot(ty)
		diag.swap_baked_x_to_z = bx.dot(tz)
		diag.swap_baked_y_to_x = by.dot(tx)
		diag.swap_baked_y_to_z = by.dot(tz)
		diag.swap_baked_z_to_x = bz.dot(tx)
		diag.swap_baked_z_to_y = bz.dot(ty)

		_classify(diag)
		report.diagnoses.append(diag)
		match diag.status:
			"OK": report.ok_count += 1
			"WEAK": report.weak_count += 1
			"FLIPPED": report.flipped_count += 1
			"SWAPPED": report.swapped_count += 1
			"BAD": report.bad_count += 1

	return report


# Sets diag.status and (for non-OK) diag.notes to a human-readable hint.
static func _classify(d: BoneDiagnosis) -> void:
	var min_dot: float = minf(d.flex_dot, minf(d.along_dot, d.abd_dot))
	if min_dot >= _OK_THRESHOLD:
		d.status = "OK"
		return
	# Flipped: at least one axis is roughly antiparallel to its target.
	if d.flex_dot <= _FLIP_THRESHOLD or d.along_dot <= _FLIP_THRESHOLD or d.abd_dot <= _FLIP_THRESHOLD:
		d.status = "FLIPPED"
		var flipped_axes: Array[String] = []
		if d.flex_dot <= _FLIP_THRESHOLD: flipped_axes.append("flex")
		if d.along_dot <= _FLIP_THRESHOLD: flipped_axes.append("along")
		if d.abd_dot <= _FLIP_THRESHOLD: flipped_axes.append("abd")
		d.notes = "sign error on " + ", ".join(flipped_axes)
		return
	# Swapped: a baked axis is closer to a *different* target column than its
	# matching one. We check each baked column vs. the alternate target columns.
	var swap_evidence: Array[String] = []
	if absf(d.swap_baked_x_to_y) > absf(d.flex_dot) or absf(d.swap_baked_x_to_z) > absf(d.flex_dot):
		swap_evidence.append("baked-flex points where target along/abd does")
	if absf(d.swap_baked_y_to_x) > absf(d.along_dot) or absf(d.swap_baked_y_to_z) > absf(d.along_dot):
		swap_evidence.append("baked-along points where target flex/abd does")
	if absf(d.swap_baked_z_to_x) > absf(d.abd_dot) or absf(d.swap_baked_z_to_y) > absf(d.abd_dot):
		swap_evidence.append("baked-abd points where target flex/along does")
	if not swap_evidence.is_empty():
		d.status = "SWAPPED"
		d.notes = "; ".join(swap_evidence)
		return
	if min_dot >= _WEAK_THRESHOLD:
		d.status = "WEAK"
		d.notes = "matcher tolerance — consider use_calculated_frame=true"
		return
	d.status = "BAD"
	d.notes = "no axis matches; check archetype assignment + solver"


# ---------- Motion-direction test (catches solver bugs, not matcher bugs) ----------
#
# The static `validate()` above checks that the baked entry matches the solver
# target — useful for catching matcher / hand-edit drift. With
# use_calculated_frame=true (the default since the matcher-tolerance fix), it
# trivially passes: baked equals target by construction.
#
# To catch errors in the *solver itself* we compare the joint frame's flex
# axis to a coarse anatomical expectation derived independently of the solver:
#
#   BALL / SADDLE / SPINE_SEGMENT / CLAVICLE limb-axis flex
#       expected motion direction: muscle_frame.forward (anterior; "raise arm
#       forward", "tilt trunk forward", etc.) — except clavicle which expects
#       up (shrug elevation).
#   HINGE flex
#       in the limb-plane (perpendicular to the cross product of parent/child
#       directions); for the canonical bent-elbow case the wrist moves in
#       muscle_frame.forward at small angles, same as BALL.
#   abd / med-rot
#       skipped — too archetype-specific to predict cleanly without more
#       muscle-frame infrastructure.
#
# Motion direction at small angles is `(flex_axis_world × bone_to_child)` —
# computed analytically so no live pose mutation is needed.

class MotionDiagnosis extends RefCounted:
	var bone_name: StringName
	var archetype_name: String
	var motion_actual: Vector3 = Vector3.ZERO
	var motion_expected: Vector3 = Vector3.ZERO
	var alignment: float = 0.0
	# Per-axis abduction motion direction. The chirality of a right-handed
	# basis with flex=forward forces +rotation around basis.z to go in
	# motion = -flex_axis direction, which on most bones is sign-flipped
	# from anatomical abduction. A negative `abd_alignment` is the smoking
	# gun for that bug — the user sees ROM-Z slider drive bones in the
	# adduction direction.
	var abd_motion_actual: Vector3 = Vector3.ZERO
	var abd_motion_expected: Vector3 = Vector3.ZERO
	var abd_alignment: float = 0.0
	var status: String = ""
	var notes: String = ""

	func format_line() -> String:
		return "  %-28s %-8s %-10s flex_dot=%+0.2f abd_dot=%+0.2f  flex=%s expected=%s  %s" % [
				bone_name, archetype_name, status,
				alignment, abd_alignment,
				_fmt_vec(motion_actual), _fmt_vec(motion_expected),
				notes]

	static func _fmt_vec(v: Vector3) -> String:
		return "(%+0.2f,%+0.2f,%+0.2f)" % [v.x, v.y, v.z]


class MotionReport extends RefCounted:
	var diagnoses: Array[MotionDiagnosis] = []
	var ok_count: int = 0
	var weak_count: int = 0
	var wrong_count: int = 0
	var skipped_count: int = 0
	var error: String = ""

	func by_status(status: String) -> Array[StringName]:
		var out: Array[StringName] = []
		for d: MotionDiagnosis in diagnoses:
			if d.status == status:
				out.append(d.bone_name)
		return out


# Validates flex-axis motion direction against archetype-specific anatomical
# expectations. Skips bones where motion direction is hard to predict
# (PIVOT, ROOT, FIXED, and non-flex axes).
static func validate_motion(
		bone_profile: BoneProfile,
		live_skeleton: Skeleton3D = null,
		bone_map: BoneMap = null) -> MotionReport:
	var report := MotionReport.new()
	if bone_profile == null:
		report.error = "bone_profile is null"
		return report
	var profile: SkeletonProfile = bone_profile.skeleton_profile
	if profile == null:
		report.error = "bone_profile.skeleton_profile is null"
		return report

	var use_live: bool = live_skeleton != null and bone_map != null
	var world_rests: Dictionary[StringName, Transform3D]
	var muscle_frame: MuscleFrame
	if use_live:
		world_rests = MuscleFrameBuilder.compute_skeleton_world_rests(live_skeleton, profile, bone_map)
		muscle_frame = MuscleFrameBuilder.build_from_skeleton(live_skeleton, profile, bone_map)
	else:
		world_rests = MuscleFrameBuilder.compute_world_rests(profile)
		muscle_frame = MuscleFrameBuilder.build(profile)

	var first_child: Dictionary[StringName, StringName] = {}
	for i in range(profile.bone_size):
		var pn: StringName = profile.get_bone_parent(i)
		if pn != &"" and not first_child.has(pn):
			first_child[pn] = profile.get_bone_name(i)

	for i in range(profile.bone_size):
		var bone_name: StringName = profile.get_bone_name(i)
		var archetype: int = MarionetteArchetypeDefaults.archetype_for_bone(bone_name)
		if archetype < 0:
			report.skipped_count += 1
			continue
		if archetype == BoneArchetype.Type.ROOT or archetype == BoneArchetype.Type.FIXED \
				or archetype == BoneArchetype.Type.PIVOT:
			report.skipped_count += 1
			continue
		if not world_rests.has(bone_name):
			report.skipped_count += 1
			continue
		var entry: BoneEntry = bone_profile.get_entry(bone_name)
		if entry == null:
			report.skipped_count += 1
			continue

		var bone_world: Transform3D = world_rests[bone_name]
		var child_world: Transform3D = _resolve_child_world(profile, i, bone_world, world_rests, first_child)
		var offset: Vector3 = child_world.origin - bone_world.origin
		if offset.length_squared() < 1.0e-6:
			report.skipped_count += 1
			continue

		# Anatomical flex axis in world space. With use_calculated_frame=true
		# this equals the solver target's flex column composed with bone_world.
		var anat_basis_world: Basis = bone_world.basis * entry.anatomical_basis_in_bone_local()
		var flex_world: Vector3 = anat_basis_world.x.normalized()
		var abd_world: Vector3 = anat_basis_world.z.normalized()
		var motion_actual: Vector3 = flex_world.cross(offset)
		if motion_actual.length_squared() < 1.0e-9:
			# Flex axis parallel to bone — degenerate; can't measure motion.
			report.skipped_count += 1
			continue
		motion_actual = motion_actual.normalized()

		var motion_expected: Vector3 = MarionetteSolverUtils.anatomical_motion_target(
				bone_name, archetype, muscle_frame)
		if motion_expected == Vector3.ZERO:
			report.skipped_count += 1
			continue
		motion_expected = motion_expected.normalized()

		# Abduction motion: rotation around basis.z applied to bone-along
		# direction. Expected direction depends on the bone — for limb balls
		# (shoulder, hip) the anatomical abd direction is "lateral, away from
		# body midline." For LEFT side bones that's +muscle_frame.right's
		# negative (i.e. body-left = -muscle_frame.right); for RIGHT it's
		# +muscle_frame.right. For spine + clavicle the expectation is body-
		# right. This is heuristic — used to flag chirality / mirror sign
		# issues, not a strict per-bone anatomical reference.
		# Account for runtime mirror_abd compensation — when the entry has
		# the flag set, +abd_slider drives -rotation around basis.z, so the
		# effective motion direction is -basis.z × offset, not basis.z × offset.
		var abd_motion_actual: Vector3 = abd_world.cross(offset)
		if entry.mirror_abd:
			abd_motion_actual = -abd_motion_actual
		var abd_motion_expected: Vector3 = MarionetteSolverUtils.expected_abd_motion_direction(
				archetype, entry.is_left_side, muscle_frame)
		if abd_motion_actual.length_squared() > 1.0e-9 and abd_motion_expected != Vector3.ZERO:
			abd_motion_actual = abd_motion_actual.normalized()
			abd_motion_expected = abd_motion_expected.normalized()
		else:
			abd_motion_actual = Vector3.ZERO
			abd_motion_expected = Vector3.ZERO

		var diag := MotionDiagnosis.new()
		diag.bone_name = bone_name
		diag.archetype_name = BoneArchetype.to_name(archetype)
		diag.motion_actual = motion_actual
		diag.motion_expected = motion_expected
		diag.alignment = motion_actual.dot(motion_expected)
		diag.abd_motion_actual = abd_motion_actual
		diag.abd_motion_expected = abd_motion_expected
		diag.abd_alignment = abd_motion_actual.dot(abd_motion_expected) if abd_motion_actual != Vector3.ZERO else 0.0

		_classify_motion(diag)
		report.diagnoses.append(diag)
		match diag.status:
			"OK": report.ok_count += 1
			"WEAK": report.weak_count += 1
			"WRONG": report.wrong_count += 1

	return report


# Coarse archetype-driven anatomical expectation for +flex motion direction
# of the bone tip. Returned vectors are normalized.
static func _expected_flex_motion_direction(archetype: int, frame: MuscleFrame) -> Vector3:
	match archetype:
		BoneArchetype.Type.CLAVICLE:
			# Clavicle "flex" = elevation (shoulder shrug). Bone tip moves up.
			return frame.up.normalized()
		BoneArchetype.Type.BALL, BoneArchetype.Type.HINGE, BoneArchetype.Type.SADDLE, \
		BoneArchetype.Type.SPINE_SEGMENT:
			# Limb / spine flex: bone tip moves anteriorly (in the body's
			# forward direction). For shoulder this is "raise arm forward",
			# for elbow "fold forearm forward", for spine "bend trunk forward".
			return frame.forward.normalized()
	return Vector3.ZERO


static func _classify_motion(d: MotionDiagnosis) -> void:
	# Tighter threshold than the static validator: motion direction errors
	# above ~26° (cos < 0.9) make poses look visibly off-plane on the rig.
	if d.alignment >= 0.9:
		d.status = "OK"
		return
	if d.alignment <= -0.5:
		d.status = "WRONG"
		d.notes = "flex axis points opposite the anatomical direction"
		return
	if d.alignment >= 0.5:
		d.status = "WEAK"
		d.notes = "flex motion is off-plane — check bone geometry / muscle frame facing"
		return
	d.status = "WRONG"
	d.notes = "flex motion is roughly perpendicular to anatomical direction"


static func _resolve_child_world(
		profile: SkeletonProfile,
		bone_index: int,
		bone_world: Transform3D,
		world_rests: Dictionary[StringName, Transform3D],
		first_child: Dictionary[StringName, StringName]) -> Transform3D:
	# Mirrors BoneProfileGenerator._resolve_child_world so the validator sees
	# the same target the generator would have computed.
	var explicit_tail: StringName = profile.get_bone_tail(bone_index)
	if explicit_tail != &"" and world_rests.has(explicit_tail):
		return world_rests[explicit_tail]
	var bone_name: StringName = profile.get_bone_name(bone_index)
	if first_child.has(bone_name) and world_rests.has(first_child[bone_name]):
		return world_rests[first_child[bone_name]]
	var nudge: Vector3 = bone_world.basis.y.normalized() * 0.02
	if nudge == Vector3.ZERO:
		nudge = Vector3(0.0, 0.02, 0.0)
	var fallback: Transform3D = bone_world
	fallback.origin = bone_world.origin + nudge
	return fallback
