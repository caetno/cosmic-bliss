#pragma once

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

// Hot inner loops for the §10.2 vertex-displacement features. GDScript
// builds the feature parameter arrays (sampling Curves, generating wart
// anchors via RNG, computing fin azimuths) and hands them off here; the
// kernels do the per-vertex math at C++ speed. Each method returns the
// modified vertex array (PackedVector3Array is CoW — the input is not
// mutated, but the returned buffer holds the displaced positions).
//
// Static-only utility class. Per the CLAUDE.md C++/GDScript split:
// "math-heavy inner loops (PBD iterations, collision projection, spline
// evaluation)" — the Wart kernel in particular runs O(V_body × N_warts)
// per bake, which dominates editor latency at modest resolutions.
class ProceduralKernels : public godot::Object {
	GDCLASS(ProceduralKernels, godot::Object)

public:
	// 3D Gaussian wart bumps. Each wart is an (axial_t, radial_angle)
	// anchor with sigma (= half base diameter, post-smoothing scale) and
	// height; body vertices within 3σ accumulate the summed bump radially
	// outward. `smoothing` is applied caller-side as a σ multiplier.
	static godot::PackedVector3Array displace_warts(
			godot::PackedVector3Array p_verts,
			const godot::PackedFloat32Array &p_custom0,
			float p_length,
			const godot::PackedFloat32Array &p_centers_t,
			const godot::PackedFloat32Array &p_centers_phi,
			const godot::PackedFloat32Array &p_sigma,
			const godot::PackedFloat32Array &p_height);

	// KnotField: radius scale max-blended from per-knot influence at axial
	// distance. profile_idx ∈ {0=Gaussian, 1=Sharp, 2=Asymmetric}.
	static godot::PackedVector3Array displace_knots(
			godot::PackedVector3Array p_verts,
			const godot::PackedFloat32Array &p_custom0,
			float p_length,
			const godot::PackedFloat32Array &p_centers_t,
			float p_sigma,
			float p_max_radius_multiplier,
			int p_profile_idx);

	// Ribs: radius scale inward at rib centers. profile_idx ∈ {0=U, 1=V}.
	static godot::PackedVector3Array displace_ribs(
			godot::PackedVector3Array p_verts,
			const godot::PackedFloat32Array &p_custom0,
			float p_length,
			const godot::PackedFloat32Array &p_centers_t,
			float p_half_width,
			float p_depth,
			int p_profile_idx);

	// Fins: axial ridges with raised-cosine cross-section. The axial
	// height taper is pre-sampled by GDScript into evenly-spaced bins
	// across [t_start..t_end].
	static godot::PackedVector3Array displace_fins(
			godot::PackedVector3Array p_verts,
			const godot::PackedFloat32Array &p_custom0,
			float p_length,
			const godot::PackedFloat32Array &p_fin_phis,
			float p_max_height,
			const godot::PackedFloat32Array &p_axial_height_samples,
			float p_half_width,
			float p_t_start,
			float p_t_end,
			float p_twist_per_length);

protected:
	static void _bind_methods();
};
