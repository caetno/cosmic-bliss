@tool
class_name MarionettePermutationMatcher
extends RefCounted

# P2.8 — finds the signed permutation of a bone's rest basis whose columns
# best align with a solver-produced anatomical target basis. Authoring-time
# only; the result is baked into BoneEntry.{flex,along_bone,abduction}_axis.
#
# Enumeration: the 24 signed permutations of three orthogonal unit vectors
# with determinant +1 (the chiral octahedral group). Reflections are
# excluded — a bone's local frame is always right-handed, and side-mirroring
# is a separate concern handled at solver time via is_left_side.
#
# Scoring: per-anatomical-column dot product between the candidate's
# rest-basis-rotated unit axis and the target's column. The candidate's
# total score is the worst (minimum) of the three column dots. This punishes
# permutations that line up two axes while leaving the third badly skewed.
#
# Match threshold: 0.85 ≈ cos(31°). With identity rest_basis, a target
# rotated 30° about any single axis still passes; a 45° rotation does not.
# Unmatched bones flag a re-roll-the-bone (or accept rotated-frame) decision.

const DEFAULT_MATCH_THRESHOLD: float = 0.85

# Lazily built on first use. Eagerly initializing via
# `static var _candidates = _build_candidates()` is unreliable under @tool
# hot-reload in Godot 4.6 — the initializer can run before the SignedAxis
# class_name is fully resolved, producing an empty list and silently
# zeroing every match. Lazy init dodges the load-order trap.
static var _candidates: Array = []


# Returns the candidate list, building it on demand if not yet populated.
static func _ensure_candidates() -> Array:
	if _candidates.is_empty():
		_candidates = _build_candidates()
	return _candidates


# Returns 24 candidate (flex, along, abduction) triples whose unit-vector
# basis has determinant +1. Order is deterministic but otherwise arbitrary
# (lexicographic on the SignedAxis enum integer values).
static func _build_candidates() -> Array:
	var all_axes: Array[SignedAxis.Axis] = [
		SignedAxis.Axis.PLUS_X, SignedAxis.Axis.MINUS_X,
		SignedAxis.Axis.PLUS_Y, SignedAxis.Axis.MINUS_Y,
		SignedAxis.Axis.PLUS_Z, SignedAxis.Axis.MINUS_Z,
	]
	var out: Array = []
	for flex: SignedAxis.Axis in all_axes:
		var fi: int = SignedAxis.index_of(flex)
		var fv: Vector3 = SignedAxis.to_vector3(flex)
		for along: SignedAxis.Axis in all_axes:
			var ai: int = SignedAxis.index_of(along)
			if ai == fi:
				continue
			var av: Vector3 = SignedAxis.to_vector3(along)
			for abd: SignedAxis.Axis in all_axes:
				var bi: int = SignedAxis.index_of(abd)
				if bi == fi or bi == ai:
					continue
				var bv: Vector3 = SignedAxis.to_vector3(abd)
				# Determinant of a basis whose columns are signed unit axes
				# is the signed volume of the parallelepiped (= ±1). Take
				# only proper rotations.
				if Basis(fv, av, bv).determinant() > 0.0:
					out.append([flex, along, abd])
	return out


# Public for tests and diagnostic dock (P2.12).
static func candidate_count() -> int:
	return _ensure_candidates().size()


# Find the best signed permutation of `rest_basis`'s columns to align with
# `target`. Both bases are interpreted in the same parent frame.
#
# `target` is the solver output (P2.6) — its columns are the anatomical
# (flex, along-bone, abduction) directions in the bone's parent space.
# `rest_basis` is the bone's rest basis in the same parent space.
#
# The returned permutation tells you which signed bone-local axis to pick
# for each anatomical direction: e.g., flex_axis=PLUS_Z means "the bone's
# +Z axis is the flex axis, after baking joint_rotation."
#
# Method named `find_match` because `match` is a GDScript keyword.
static func find_match(
		rest_basis: Basis,
		target: Basis,
		threshold: float = DEFAULT_MATCH_THRESHOLD) -> MarionettePermutationMatch:
	var best: MarionettePermutationMatch = MarionettePermutationMatch.new()
	best.score = -INF
	for triple: Array in _ensure_candidates():
		var fa: SignedAxis.Axis = triple[0]
		var aa: SignedAxis.Axis = triple[1]
		var ba: SignedAxis.Axis = triple[2]
		# Rotate the bone-local signed axis into parent space via rest_basis,
		# then dot with the target's anatomical column for that slot.
		var s_flex: float = (rest_basis * SignedAxis.to_vector3(fa)).dot(target.x)
		var s_along: float = (rest_basis * SignedAxis.to_vector3(aa)).dot(target.y)
		var s_abd: float = (rest_basis * SignedAxis.to_vector3(ba)).dot(target.z)
		var s: float = minf(s_flex, minf(s_along, s_abd))
		if s > best.score:
			best.score = s
			best.flex_axis = fa
			best.along_bone_axis = aa
			best.abduction_axis = ba
	best.matched = best.score >= threshold
	return best
