@tool
class_name MarionetteSolverUtils
extends RefCounted

# Shared geometric helpers used by the per-archetype solvers (P2.6). Kept in
# one file because they are pure math; CLAUDE.md only forbids generic *solvers*
# that bury archetype logic in conditionals — utility math is fine.

const _EPSILON: float = 1.0e-6


# Returns the component of `v` perpendicular to `axis`, normalized. If `v` is
# parallel to `axis` (zero residual), returns Vector3.ZERO — caller decides
# fallback. `axis` should already be unit.
static func perpendicular_component(v: Vector3, axis: Vector3) -> Vector3:
	var residual: Vector3 = v - axis * v.dot(axis)
	if residual.length_squared() < _EPSILON:
		return Vector3.ZERO
	return residual.normalized()


# Returns a unit vector perpendicular to `axis` that is closest to `preferred`.
# If `preferred` is parallel to `axis`, falls back to a deterministic
# perpendicular (the most-perpendicular world axis).
static func perpendicular_to_axis_near(axis: Vector3, preferred: Vector3) -> Vector3:
	var p: Vector3 = perpendicular_component(preferred, axis)
	if p != Vector3.ZERO:
		return p
	# Fallback: pick a world axis with smallest |dot(axis)|.
	var candidates: Array[Vector3] = [Vector3.RIGHT, Vector3.UP, Vector3.FORWARD]
	var best_axis: Vector3 = Vector3.RIGHT
	var best_dot: float = INF
	for c: Vector3 in candidates:
		var d: float = absf(axis.dot(c))
		if d < best_dot:
			best_dot = d
			best_axis = c
	return perpendicular_component(best_axis, axis)


# Direction from bone origin to its child origin, normalized. Returns
# Vector3.ZERO if degenerate; callers must handle.
static func along_bone_direction(bone_world: Transform3D, child_world: Transform3D) -> Vector3:
	var d: Vector3 = child_world.origin - bone_world.origin
	if d.length_squared() < _EPSILON:
		return Vector3.ZERO
	return d.normalized()


# Anatomical basis assembled from three orthogonal unit vectors. Columns:
# (flex, along_bone, abduction). Validates orthogonality cheaply; if the
# inputs are non-orthogonal, the abduction axis is forced to flex × along.
static func make_anatomical_basis(flex: Vector3, along: Vector3) -> Basis:
	# Guard against degenerate input.
	var f: Vector3 = flex
	var a: Vector3 = along
	if f.length_squared() < _EPSILON or a.length_squared() < _EPSILON:
		return Basis.IDENTITY
	# Orthogonalize flex against along.
	f = (f - a * f.dot(a))
	if f.length_squared() < _EPSILON:
		# flex collinear with along; pick deterministic perpendicular.
		f = perpendicular_to_axis_near(a, Vector3.RIGHT)
	f = f.normalized()
	a = a.normalized()
	var abd: Vector3 = f.cross(a).normalized()
	return Basis(f, a, abd)


# For limb bones whose flex axis is the body's lateral axis: returns the
# lateral direction in world space, signed so that positive flexion is the
# anatomical forward-raise gesture (CLAUDE.md §2). For both sides, this is
# the same world direction — both arms flex around the same lateral line
# through both shoulders. We use the muscle frame's "left" direction (=
# -muscle_frame.right) because rotating around it by +θ takes a downward
# bone (-up) toward the forward axis.
static func limb_flex_axis(muscle_frame: MuscleFrame, _is_left_side: bool) -> Vector3:
	return -muscle_frame.right


# Returns a flex axis (perpendicular to `along`) such that rotating `along`
# around it by +θ produces motion in the `target_motion` direction.
#
# Math: motion = flex × along. Solving for flex (with flex ⊥ along) gives
# flex = along × target_motion. This formula automatically yields opposite
# signs for left and right limbs whose `along` vectors are mirrored, which
# is the fix for the right-side flex-direction bug — driving +flex now moves
# every limb-tip forward (or up, for clavicle) regardless of side.
#
# When `along` is parallel to `target_motion` (e.g. an arm pointing exactly
# forward — degenerate for forward-flex motion), falls back to a side-aware
# lateral perpendicular so the basis is still well-defined.
# Maps a bone to the world-space direction its tip should move on +flex.
# Convention is set so the muscle-test dock's macros (Open/Close, etc.) and
# downstream emotional-body composition reach intuitive poses with positive
# flex coefficients:
#
#   Arms / spine / hip / elbow — forward (shoulder flex, hip flex, trunk
#                                forward bend, elbow fold).
#   Knee (LowerLeg)            — backward (anatomical knee flexion folds the
#                                calf posteriorly toward the butt; the only
#                                limb-hinge whose +flex direction is the
#                                opposite of the limb's parent ball joint).
#   Hand (wrist Saddle)       — down (palmar flex; from T-pose with palms
#                                down, wrist drops). This also makes the
#                                X / Z gizmo axes land in the body's
#                                sagittal / frontal planes anatomically.
#   Finger phalanges          — down (curl into a fist, same convention).
#   Foot (ankle Saddle)       — up (dorsiflex; toes lift). Macros plantarflex
#                                via negative coefficients.
#   Toes (compound + phalanges) — down (curl; toes grip floor).
#   Clavicle                  — up (shoulder elevation / shrug).
#   Pivot / Root / Fixed      — Vector3.ZERO (no flex DOF; caller skips).
#
# Drives both the solver's flex-axis derivation and the validator's expected
# motion direction so the two stay in lockstep — when the convention changes
# we update one place and both sides follow.
static func anatomical_motion_target(
		bone_name: StringName,
		archetype: int,
		muscle_frame: MuscleFrame) -> Vector3:
	var s: String = String(bone_name)
	# Toe phalanges + the Toes compound bone: anatomical flex curls the toes
	# (anatomical-posterior of the foot), motion is downward.
	if s.contains("Toe") or s.contains("Hallux"):
		return -muscle_frame.up
	# Ankle Saddle ("Foot" / "LeftFoot" / "RightFoot"): dorsiflex = toes-up.
	if s.ends_with("Foot"):
		return muscle_frame.up
	# Knee Hinge ("LowerLeg"): anatomical flexion bends the calf POSTERIORLY
	# (foot toward butt), opposite of the elbow / hip / shoulder flex-forward
	# convention. The knee is the only mainstream limb hinge that bends the
	# distal segment backward — every other limb-flex direction has a forward
	# component from a standing pose, but knee flex is the carve-out.
	if s.ends_with("LowerLeg"):
		return -muscle_frame.forward
	# Wrist Saddle: palmar flex direction = down.
	if s.ends_with("Hand"):
		return -muscle_frame.up
	# Finger phalanges + thumb metacarpal: curl direction = down.
	if s.contains("Thumb") or s.contains("Index") or s.contains("Middle") \
			or s.contains("Ring") or s.contains("Little"):
		return -muscle_frame.up
	if archetype == BoneArchetype.Type.CLAVICLE:
		return muscle_frame.up
	if archetype == BoneArchetype.Type.PIVOT \
			or archetype == BoneArchetype.Type.ROOT \
			or archetype == BoneArchetype.Type.FIXED:
		return Vector3.ZERO
	return muscle_frame.forward


# Anatomical "+abd motion" expectation per archetype + side. Used by both the
# generator (to set BoneEntry.mirror_abd when chirality flips the natural
# rotation against anatomy) and the validator (to compute abd_dot in the
# motion-direction check).
#
#   Limb balls (shoulder, hip)   — laterally outward (away from midline).
#   Saddles (wrist, ankle, MCP)  — same lateral-outward convention.
#   Spine                        — body-right (matches "+1 = bend right" macro).
#   Clavicle                     — anteriorly forward (protraction direction).
#   Pivot / Hinge / Root / Fixed — Vector3.ZERO (locked or undefined).
static func expected_abd_motion_direction(
		archetype: int,
		is_left_side: bool,
		muscle_frame: MuscleFrame) -> Vector3:
	match archetype:
		BoneArchetype.Type.BALL, BoneArchetype.Type.SADDLE:
			return -muscle_frame.right if is_left_side else muscle_frame.right
		BoneArchetype.Type.SPINE_SEGMENT:
			return muscle_frame.right
		BoneArchetype.Type.CLAVICLE:
			return muscle_frame.forward
	return Vector3.ZERO


static func anatomical_flex_axis(
		along: Vector3,
		target_motion: Vector3,
		muscle_frame: MuscleFrame,
		is_left_side: bool) -> Vector3:
	var f: Vector3 = along.cross(target_motion)
	if f.length_squared() < _EPSILON:
		# Bone is collinear with the target motion direction — can't derive
		# flex from the cross. Sign the lateral fallback by side so each
		# limb still gets the right rotation direction.
		var lateral: Vector3 = -muscle_frame.right
		f = lateral if is_left_side else -lateral
		# Project off any along-component (mostly a no-op since lateral is
		# generally perpendicular to a forward-pointing along).
		f = f - along * f.dot(along)
		if f.length_squared() < _EPSILON:
			return Vector3.ZERO
	return f.normalized()
