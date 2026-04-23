#ifndef DPG_MATH_H
#define DPG_MATH_H

#include <godot_cpp/variant/vector3.hpp>

namespace dpg {

/// Clamp a penetrator origin so it sits at least `min_gap` behind marker0
/// along `pen_fwd`, without introducing a discontinuity when the raw origin
/// crosses the clamp boundary.
///
/// The forward component of `pen_origin - marker0` is clamped to at most
/// `-min_gap` via MIN(); the lateral component is preserved. This avoids the
/// Catmull-Rom first-segment degenerate knot_interval, and eliminates the
/// engagement pop the old Euclidean-distance guard introduced by snapping
/// pen_origin discontinuously onto the forward axis.
inline godot::Vector3 compute_safe_pen_origin(
		const godot::Vector3 &marker0,
		const godot::Vector3 &pen_origin,
		const godot::Vector3 &pen_fwd,
		float min_gap) {
	godot::Vector3 rel = pen_origin - marker0;
	float fwd_comp = rel.dot(pen_fwd);
	float clamped = fwd_comp < -min_gap ? fwd_comp : -min_gap;
	godot::Vector3 lat = rel - pen_fwd * fwd_comp;
	return marker0 + lat + pen_fwd * clamped;
}

} // namespace dpg

#endif // DPG_MATH_H
