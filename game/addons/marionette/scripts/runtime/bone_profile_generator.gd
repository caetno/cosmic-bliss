@tool
class_name BoneProfileGenerator
extends RefCounted

# P2.10 — fills a BoneProfile by running the authoring-time pipeline:
#   muscle frame -> archetype lookup -> per-archetype solver
#   -> permutation matcher -> clinical ROM defaults.
#
# Pure data path; the inspector button (`MarionetteBoneProfileInspector`) and
# the Marionette node's "Calibrate Profile from Skeleton" button wrap this
# with a press handler. CLI tests call `generate()` directly.
#
# Per-bone update. Existing entries on the BoneProfile are kept by default and
# overwritten only for bones the generator actually solves this pass; bones
# that aren't in the data source (e.g. a live rig missing toe bones) keep
# their previous (template-derived) entry instead of disappearing. Bones not
# in `MarionetteArchetypeDefaults` are reported in `skipped_bones` and never
# touched by the generator.
#
# By default the SkeletonProfile's reference poses drive the muscle frame and
# rest bases (the path the inspector button takes — the shipped default
# BoneProfile is template-derived). Pass a live `Skeleton3D` + `BoneMap` to
# calibrate against a specific rig instead; the matcher then sees that rig's
# rest bases including any per-bone roll baked at modeling time.

const _CHILD_NUDGE: float = 0.02


# Authoring method for deriving each bone's anatomical target basis.
#   ARCHETYPE — original path: per-archetype geometric solvers over rest-pose
#               bone-to-child world geometry, with permutation matching.
#   TPOSE     — alternative path: canonical T-pose along-direction lookup +
#               one cross product. See
#               `docs/marionette/Marionette_Update_TPose_Calibration.md`.
# Both paths share every other generator step (data substrate selection, muscle
# frame, matcher score for diagnostics, calculated_anatomical_basis bake,
# mirror_abd, ROM defaults) — they only differ in how `target_basis` is built.
enum Method { ARCHETYPE, TPOSE }


# Result of a generate() pass. Reported back so the inspector button can
# print a one-line summary and the test harness can spot-check counts.
class GenerateReport extends RefCounted:
	var generated: int = 0
	var matched: int = 0
	var unmatched: int = 0
	var skipped: int = 0
	var preserved: int = 0
	var unmatched_bones: Array[StringName] = []
	var skipped_bones: Array[StringName] = []
	var preserved_bones: Array[StringName] = []
	var error: String = ""


# Existing entry point — preserved for callers (tests, older scripts) that
# don't pass a method. Defaults to the archetype path.
static func generate(
		bone_profile: BoneProfile,
		live_skeleton: Skeleton3D = null,
		bone_map: BoneMap = null,
		verbose: bool = false,
		forward_override: Vector3 = Vector3.ZERO) -> GenerateReport:
	return generate_with_method(
			bone_profile, Method.ARCHETYPE,
			live_skeleton, bone_map, verbose, forward_override)


static func generate_with_method(
		bone_profile: BoneProfile,
		method: Method,
		live_skeleton: Skeleton3D = null,
		bone_map: BoneMap = null,
		verbose: bool = false,
		forward_override: Vector3 = Vector3.ZERO) -> GenerateReport:
	var report := GenerateReport.new()
	if bone_profile == null:
		report.error = "bone_profile is null"
		return report
	var profile: SkeletonProfile = bone_profile.skeleton_profile
	if profile == null:
		report.error = "bone_profile.skeleton_profile is null"
		return report
	if profile.bone_size == 0:
		report.error = "skeleton_profile has zero bones"
		return report

	var use_live: bool = live_skeleton != null and bone_map != null
	var world_rests: Dictionary[StringName, Transform3D]
	var muscle_frame: MuscleFrame
	if use_live:
		world_rests = MuscleFrameBuilder.compute_skeleton_world_rests(live_skeleton, profile, bone_map)
		muscle_frame = MuscleFrameBuilder.build_from_skeleton(live_skeleton, profile, bone_map, forward_override)
	else:
		world_rests = MuscleFrameBuilder.compute_world_rests(profile)
		muscle_frame = MuscleFrameBuilder.build(profile, forward_override)

	if verbose:
		var method_label: String = "ARCHETYPE" if method == Method.ARCHETYPE else "TPOSE"
		print("[BoneProfileGenerator] %s pass against %d-bone profile (rig has %d resolvable bones, method=%s)"
				% ["live-skeleton" if use_live else "template",
					profile.bone_size, world_rests.size(), method_label])
		print("[BoneProfileGenerator] muscle frame: right=%s up=%s forward=%s%s" % [
				muscle_frame.right, muscle_frame.up, muscle_frame.forward,
				" (override applied)" if forward_override != Vector3.ZERO else ""])

	# parent-name -> first-listed-child-name lookup, for the child-hint each
	# solver needs when SkeletonProfile.get_bone_tail() isn't set.
	var first_child: Dictionary[StringName, StringName] = {}
	for i in range(profile.bone_size):
		var pn: StringName = profile.get_bone_parent(i)
		if pn != &"" and not first_child.has(pn):
			first_child[pn] = profile.get_bone_name(i)

	# Start from the existing entries so bones missing from a live rig keep
	# their previous (template-derived) entries — calibrate against an
	# 84-bone profile with a 78-bone skeleton no longer drops 6 entries.
	#
	# Deep-duplicate each preserved entry so the new dict owns fresh
	# BoneEntry instances. A shallow duplicate keeps the original
	# sub-resource references that came from the on-disk .tres file, and
	# Godot's serializer was dropping those preserved 6 entries on
	# ResourceSaver.save — visible as the bones array snapping back from
	# 84 to 78 on project reload.
	var entries: Dictionary[StringName, BoneEntry] = {}
	for existing_key: StringName in bone_profile.bones.keys():
		var existing_entry: BoneEntry = bone_profile.bones[existing_key]
		if existing_entry != null:
			entries[existing_key] = existing_entry.duplicate(true)

	for i in range(profile.bone_size):
		var bone_name: StringName = profile.get_bone_name(i)
		var archetype: int = MarionetteArchetypeDefaults.archetype_for_bone(bone_name)
		if archetype < 0:
			report.skipped += 1
			report.skipped_bones.append(bone_name)
			if verbose:
				print("  %-28s SKIPPED (no archetype mapping)" % bone_name)
			continue
		if not world_rests.has(bone_name):
			# Not in the data source. Preserve any existing entry so per-bone
			# state survives a partial-rig calibrate.
			if entries.has(bone_name):
				report.preserved += 1
				report.preserved_bones.append(bone_name)
				if verbose:
					print("  %-28s MISSING from rig — preserved existing entry"
							% bone_name)
			else:
				report.skipped += 1
				report.skipped_bones.append(bone_name)
				if verbose:
					print("  %-28s MISSING from rig — no existing entry to preserve"
							% bone_name)
			continue

		var bone_world: Transform3D = world_rests[bone_name]
		var child_world: Transform3D = _resolve_child_world(profile, i, bone_world, world_rests, first_child)
		var parent_name: StringName = profile.get_bone_parent(i)
		var parent_world: Transform3D = world_rests[parent_name] if (parent_name != &"" and world_rests.has(parent_name)) else Transform3D()
		var is_left_side: bool = String(bone_name).begins_with("Left")

		# Capture any tuning the user did on the previous entry (joint spring
		# values, possibly other future-tuneable fields). We rebuild the
		# entry from scratch each pass — solver basis, mirror_abd, ROM
		# defaults are all regenerated — but tuning that lives outside that
		# regeneration scope is propagated into the fresh entry below so a
		# re-Calibrate doesn't blow it away.
		var prior_stiffness: Vector3 = Vector3.ZERO
		var prior_damping: Vector3 = Vector3.ZERO
		var prior_mass_fraction: float = 0.0
		if entries.has(bone_name) and entries[bone_name] != null:
			prior_stiffness = entries[bone_name].spring_stiffness
			prior_damping = entries[bone_name].spring_damping
			prior_mass_fraction = entries[bone_name].mass_fraction

		var entry := BoneEntry.new()
		entry.archetype = archetype
		entry.is_left_side = is_left_side
		entry.spring_stiffness = prior_stiffness
		entry.spring_damping = prior_damping
		entry.mass_fraction = prior_mass_fraction

		# ROOT and FIXED bones aren't SPD-driven; the matcher score is
		# meaningless for them. Leave permutation at BoneEntry defaults
		# (PLUS_X / PLUS_Y / PLUS_Z) — write_into() would only echo that anyway.
		var outcome_label: String = "GENERATED (no SPD frame)"
		if archetype != BoneArchetype.Type.ROOT and archetype != BoneArchetype.Type.FIXED:
			var target_basis: Basis
			match method:
				Method.ARCHETYPE:
					var motion_target: Vector3 = MarionetteSolverUtils.anatomical_motion_target(
							bone_name, archetype, muscle_frame)
					target_basis = MarionetteArchetypeSolverDispatch.solve(
							archetype, bone_world, child_world, muscle_frame, is_left_side,
							parent_world, motion_target)
				Method.TPOSE:
					target_basis = MarionetteTPoseBasisSolver.solve(
							bone_name, archetype, muscle_frame, is_left_side)
			var match_result: MarionettePermutationMatch = MarionettePermutationMatcher.find_match(
					bone_world.basis, target_basis)
			match_result.write_into(entry)
			# Cache the calculated bone-local frame and always bake it as the
			# runtime joint frame. The matcher's signed permutation is kept on
			# the entry for diagnostics (validator + tripod gizmos signal the
			# rig's calibration quality) but is NOT used for runtime motion —
			# the 0.85 match threshold accepts up to ±31° of axis tilt, and
			# even a 15° tilt makes shoulder flex rotate slightly off-plane.
			# Always-calculated-frame eliminates that whole class of error.
			# bone_world.basis is orthonormal (Skeleton3D rest), so .inverse()
			# is the same as .transposed() up to FP error.
			entry.calculated_anatomical_basis = bone_world.basis.inverse() * target_basis
			entry.use_calculated_frame = true
			# Detect chirality flip on the abduction axis and store the
			# compensation flag. Evaluates the natural +joint_z rotation
			# motion (target_basis.z × along) at the *canonical* anatomical
			# pose, not at rest. This matters for bones whose rest deviates
			# from canonical along by ~90° (e.g. shoulder T-pose, where the
			# arm sits perpendicular to canonical-down): the rest-pose motion
			# direction is perpendicular to expected_abd, which gives dot=0
			# and silently picks the wrong mirror sign. Rotating the motion
			# vector by Q(rest→canonical) puts it back where +abd is by
			# definition aligned with expected_abd.
			var expected_abd: Vector3 = MarionetteSolverUtils.expected_abd_motion_direction(
					archetype, is_left_side, muscle_frame)
			if expected_abd != Vector3.ZERO:
				var along_world: Vector3 = (child_world.origin - bone_world.origin)
				if along_world.length_squared() > 1e-9:
					var rest_along: Vector3 = along_world.normalized()
					var natural_abd_at_rest: Vector3 = target_basis.z.cross(rest_along)
					if natural_abd_at_rest.length_squared() > 1e-9:
						var canonical_along: Vector3 = _canonical_along(
								archetype, bone_name, is_left_side,
								bone_world, child_world, parent_world, muscle_frame)
						var natural_abd: Vector3 = natural_abd_at_rest
						if canonical_along != Vector3.ZERO \
								and not canonical_along.is_equal_approx(rest_along):
							var q := Quaternion(rest_along, canonical_along)
							natural_abd = q * natural_abd_at_rest
						entry.mirror_abd = natural_abd.normalized().dot(expected_abd) < 0.0
			if match_result.matched:
				report.matched += 1
				outcome_label = "MATCHED  score=%.2f perm=[%s,%s,%s]" % [
						match_result.score,
						SignedAxis.to_name(match_result.flex_axis),
						SignedAxis.to_name(match_result.along_bone_axis),
						SignedAxis.to_name(match_result.abduction_axis)]
			else:
				report.unmatched += 1
				report.unmatched_bones.append(bone_name)
				outcome_label = "FALLBACK score=%.2f (calculated frame baked into joint_rotation)" % match_result.score

		MarionetteRomDefaults.apply(entry, bone_name)
		# Spring defaults: archetype + bone-name-refined values. Per-axis
		# preservation — any non-zero value carried over from prior tuning
		# stays; zeros get the default for that axis. ROOT and FIXED bones
		# stay at zero (no spring needed; not joint-driven).
		MarionetteSpringDefaults.apply(entry, bone_name)
		# Mass defaults: anthropometric per-bone fractions (~50 % trunk,
		# ~10 % per upper leg, etc.). Preserved across re-Calibrate via
		# the same non-zero-stays-tuned policy.
		MarionetteMassDefaults.apply(entry, bone_name)
		entry.rest_anatomical_offset = _compute_rest_offset(
				archetype, bone_world, child_world, parent_world,
				muscle_frame, entry, bone_name)

		entries[bone_name] = entry
		report.generated += 1

		if verbose:
			print("  %-28s %-8s %s" % [bone_name, BoneArchetype.to_name(archetype), outcome_label])

	bone_profile.bones = entries

	if verbose:
		print("[BoneProfileGenerator] generated=%d matched=%d fallback=%d preserved=%d skipped=%d (final size=%d)"
				% [report.generated, report.matched, report.unmatched,
					report.preserved, report.skipped, bone_profile.bones.size()])

	return report


# How far the rest pose deviates from canonical anatomical zero, expressed
# in joint-frame (flex, medial_rot, abduction) radians. See
# `BoneEntry.rest_anatomical_offset` for the runtime contract.
#
# Algorithm (uniform across archetypes):
#   1. Pick canonical_along per archetype (`_canonical_along`).
#   2. Compute the shortest-arc rotation R that takes canonical_along to
#      the bone's rest_along (axis = canonical × rest, angle = acos(dot)).
#   3. Express R as an axis-angle vector in joint-frame coords by projecting
#      the world axis onto the joint basis (= bone_world.basis · calculated
#      anatomical basis), then scaling by angle.
#   4. Apply mirror_abd / sided-medial-rotation flips so the offset reads in
#      canonical-positive convention (matches rom_min/rom_max). The runtime
#      layer (`AnatomicalPose.bone_local_rotation`) re-applies the same flips
#      when composing the joint quaternion, so slider value = rest_offset
#      lands on rest-pose identity.
#
# Canonical poses (per archetype):
#   BALL     — limb hangs down (-muscle_frame.up). Shoulder T-pose has +90°
#              abd offset; hip T-pose ≈ canonical, offset ≈ 0.
#   HINGE    — parent and child collinear (extended limb). Carrying-angle
#              elbow / bent-knee A-pose pick up flex offset; T-pose ≈ 0.
#   SADDLE   — Foot canonical = horizontal (muscle_frame.forward); Hand and
#              MCP/MTP saddles canonical = collinear with parent (extended).
#   SPINE    — collinear with parent (straight spine).
#   CLAVICLE — laterally outward (±muscle_frame.right). T-pose ≈ canonical.
#   ROOT/FIXED/PIVOT — no DOF, returns ZERO.
static func _compute_rest_offset(
		archetype: int,
		bone_world: Transform3D,
		child_world: Transform3D,
		parent_world: Transform3D,
		muscle_frame: MuscleFrame,
		entry: BoneEntry,
		bone_name: StringName) -> Vector3:
	if archetype == BoneArchetype.Type.ROOT \
			or archetype == BoneArchetype.Type.FIXED \
			or archetype == BoneArchetype.Type.PIVOT:
		return Vector3.ZERO
	var rest_along: Vector3 = MarionetteSolverUtils.along_bone_direction(bone_world, child_world)
	if rest_along == Vector3.ZERO:
		return Vector3.ZERO
	var canonical_along: Vector3 = _canonical_along(
			archetype, bone_name, entry.is_left_side,
			bone_world, child_world, parent_world, muscle_frame)
	if canonical_along == Vector3.ZERO:
		return Vector3.ZERO
	var dot: float = clampf(canonical_along.dot(rest_along), -1.0, 1.0)
	var angle: float = acos(dot)
	if angle < 1e-6:
		return Vector3.ZERO
	var axis_world: Vector3 = canonical_along.cross(rest_along)
	if axis_world.length_squared() < 1e-12:
		# 180°: rest is anti-parallel to canonical. Axis is ambiguous; punt.
		# Pathological for our rigs (would mean the bone points "up" when
		# anatomy says "down"). Caller can flag via gizmo if it shows up.
		return Vector3.ZERO
	axis_world = axis_world.normalized()
	# Joint frame in world = bone_world.basis · calculated anatomical basis.
	# Both factors are orthonormal, so .inverse() = .transposed() up to FP.
	var joint_basis_world: Basis = bone_world.basis * entry.calculated_anatomical_basis
	var axis_joint: Vector3 = joint_basis_world.inverse() * axis_world
	var offset: Vector3 = axis_joint * angle
	# Match the canonical-positive convention used by rom_min/rom_max.
	# Runtime mirrors live in AnatomicalPose; apply them here too so the
	# slider value `rest_offset` lands on Quaternion.IDENTITY (= rest pose).
	if entry.mirror_abd:
		offset.z = -offset.z
	var is_sided_med_rot: bool = (
			archetype == BoneArchetype.Type.BALL
			or archetype == BoneArchetype.Type.CLAVICLE)
	if is_sided_med_rot and not entry.is_left_side:
		offset.y = -offset.y
	return offset


# Canonical anatomical along-bone direction in world space, per archetype.
# Used by `_compute_rest_offset` and by the canonical-pose mirror_abd check
# in `generate_with_method`. Returns Vector3.ZERO when the archetype has no
# meaningful canonical (ROOT, FIXED, PIVOT, or degenerate parent geometry).
static func _canonical_along(
		archetype: int,
		bone_name: StringName,
		is_left_side: bool,
		bone_world: Transform3D,
		child_world: Transform3D,
		parent_world: Transform3D,
		muscle_frame: MuscleFrame) -> Vector3:
	var name: String = String(bone_name)
	match archetype:
		BoneArchetype.Type.BALL:
			# Shoulder / hip: limb hangs straight down at anatomical neutral.
			return -muscle_frame.up
		BoneArchetype.Type.HINGE:
			# Elbow / knee / phalanges: extended (parent and child collinear).
			var v: Vector3 = bone_world.origin - parent_world.origin
			if v.length_squared() < 1e-9:
				return Vector3.ZERO
			return v.normalized()
		BoneArchetype.Type.SADDLE:
			# Ankle is the only saddle whose canonical isn't "extended": the
			# foot sits perpendicular to the leg (flat on ground) at neutral.
			# Wrist, thumb metacarpal, MCP/MTP saddles are all "extended".
			if name.ends_with("Foot"):
				return muscle_frame.forward
			var v: Vector3 = bone_world.origin - parent_world.origin
			if v.length_squared() < 1e-9:
				return Vector3.ZERO
			return v.normalized()
		BoneArchetype.Type.SPINE_SEGMENT:
			# Vertebrae / neck / head: collinear with parent (straight spine).
			var v: Vector3 = bone_world.origin - parent_world.origin
			if v.length_squared() < 1e-9:
				return Vector3.ZERO
			return v.normalized()
		BoneArchetype.Type.CLAVICLE:
			# Clavicle goes laterally outward from sternum to shoulder. The
			# bone-local along is signed by side; muscle_frame.right gives the
			# body-right direction independent of bone-local convention.
			return -muscle_frame.right if is_left_side else muscle_frame.right
	return Vector3.ZERO


# Resolve the bone's child world-rest transform: explicit tail bone first,
# then first listed child bone, then a small nudge along bone-local +Y so
# terminal bones still produce a non-degenerate hint.
static func _resolve_child_world(
		profile: SkeletonProfile,
		bone_index: int,
		bone_world: Transform3D,
		world_rests: Dictionary[StringName, Transform3D],
		first_child: Dictionary[StringName, StringName]) -> Transform3D:
	var explicit_tail: StringName = profile.get_bone_tail(bone_index)
	if explicit_tail != &"" and world_rests.has(explicit_tail):
		return world_rests[explicit_tail]
	var bone_name: StringName = profile.get_bone_name(bone_index)
	if first_child.has(bone_name) and world_rests.has(first_child[bone_name]):
		return world_rests[first_child[bone_name]]
	var nudge: Vector3 = bone_world.basis.y.normalized() * _CHILD_NUDGE
	if nudge == Vector3.ZERO:
		nudge = Vector3(0.0, _CHILD_NUDGE, 0.0)
	var fallback: Transform3D = bone_world
	fallback.origin = bone_world.origin + nudge
	return fallback
