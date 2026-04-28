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
