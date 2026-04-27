shader_type spatial;

// TentacleTech tentacle vertex shader.
//
// Spec: docs/architecture/TentacleTech_Architecture.md §5.3.
//
// Mesh authoring convention (§10.1, defaults):
//   - Cylindrical mesh aligned along +Z.
//   - Origin at base center; base ring in z=0 plane.
//   - Vertex.z = arc-length from base; (x,y) = lateral offset from centerline.
//
// Compatibility for stock primitives and reversed conventions:
//   - `mesh_arc_axis` selects which mesh-local axis is the arc-length direction
//     (X/Y/Z; default Z).
//   - `mesh_arc_sign` is multiplied with the chosen axis (default +1.0). Set to
//     -1.0 if the mesh extends *backward* along that axis (e.g. TentacleMesh's
//     §10.1 -Z convention: tip at z=-length, base at z=0).
//   - `mesh_arc_offset` is added after sign multiplication; use it to shift a
//     centered mesh into base-at-zero coordinates.
//
// Stock CylinderMesh (Y-up, centered): mesh_arc_axis=1, mesh_arc_sign=+1,
// mesh_arc_offset=h/2.
// TentacleMesh (auto-configured): mesh_arc_axis=2, mesh_arc_sign=-1, mesh_arc_offset=0.
//
// Three-layer deformation stack:
//   1. Rest girth — already baked into mesh geometry; nothing to do here.
//   2. Per-particle girth_scale — interpolated from the spline data texture.
//   3. Asymmetric squeeze — per-particle asymmetry vector, axis-rotated.
//
// Final placement: the deformed lateral offset is laid in the spline's
// orthonormal frame at the corresponding arc-length sample point.

#include "tentacle_lib.gdshaderinc"

uniform sampler2D spline_data_texture : repeat_disable, filter_nearest;
uniform int spline_data_width = 1;
uniform sampler2D rest_girth_texture : repeat_disable, filter_linear;
// 0 = X, 1 = Y, 2 = Z (default, per §10.1).
uniform int mesh_arc_axis = 2;
// Sign applied to the chosen axis component before offset. Use -1.0 when the
// mesh extends in the negative direction (TentacleMesh's intrinsic_axis_sign=-1
// case). Default +1.0 keeps stock primitives working unchanged.
uniform float mesh_arc_sign = 1.0;
// Additive offset applied after sign. For a centered mesh, set to half the
// long-axis extent so the base maps to arc=0.
uniform float mesh_arc_offset = 0.0;

// Decompose the mesh vertex into (arc, lateral_a, lateral_b) according to
// mesh_arc_axis + mesh_arc_sign. lateral_a maps onto spline normal,
// lateral_b onto binormal.
void tt_decompose_mesh_vertex(vec3 v, out float arc, out vec2 lateral) {
	if (mesh_arc_axis == 0) {
		arc = v.x * mesh_arc_sign;
		lateral = v.yz;
	} else if (mesh_arc_axis == 1) {
		arc = v.y * mesh_arc_sign;
		lateral = v.xz;
	} else {
		arc = v.z * mesh_arc_sign;
		lateral = v.xy;
	}
}

// Decompose a mesh-space normal the same way, returning (along_arc, lateral).
// The sign multiplier flips the along-arc component too — a +Z-facing tip cap
// on a sign=-1 mesh actually points *forward* along the spline's tangent.
void tt_decompose_mesh_normal(vec3 n, out float along_arc, out vec2 lateral) {
	if (mesh_arc_axis == 0) {
		along_arc = n.x * mesh_arc_sign;
		lateral = n.yz;
	} else if (mesh_arc_axis == 1) {
		along_arc = n.y * mesh_arc_sign;
		lateral = n.xz;
	} else {
		along_arc = n.z * mesh_arc_sign;
		lateral = n.xy;
	}
}

void vertex() {
	int seg_n = tt_segment_count(spline_data_texture, spline_data_width);
	int dist_lut_n = tt_dist_lut_size(spline_data_texture, spline_data_width);
	int bn_lut_n = tt_bn_lut_size(spline_data_texture, spline_data_width);
	int point_n = tt_point_count(spline_data_texture, spline_data_width);
	float arc_len = tt_arc_length(spline_data_texture, spline_data_width);

	// Decompose mesh vertex per the configured axis convention; then convert
	// arc-distance to spline parameter via the distance LUT.
	float arc_length_v;
	vec2 lateral_in;
	tt_decompose_mesh_vertex(VERTEX, arc_length_v, lateral_in);
	arc_length_v += mesh_arc_offset;
	float t = (arc_len > 1e-6)
			? tt_distance_to_parameter(spline_data_texture, spline_data_width,
					arc_length_v, seg_n, dist_lut_n)
			: 0.0;

	// Layer 2: per-particle girth scale.
	vec2 lateral = lateral_in;
	float girth_scale = tt_interpolate_particle_girth_scale(
			spline_data_texture, spline_data_width, t,
			point_n, seg_n, dist_lut_n, bn_lut_n);
	lateral *= girth_scale;

	// Layer 3: asymmetric squeeze.
	vec2 asym = tt_interpolate_particle_asymmetry(
			spline_data_texture, spline_data_width, t,
			point_n, seg_n, dist_lut_n, bn_lut_n);
	lateral = tt_apply_asymmetry(lateral, asym);

	// Place in the spline frame.
	vec3 spline_pos = tt_evaluate_spline_position(
			spline_data_texture, spline_data_width, t, seg_n);
	vec3 tangent;
	vec3 normal_axis;
	vec3 binormal_axis;
	tt_evaluate_spline_frame(
			spline_data_texture, spline_data_width, t,
			seg_n, dist_lut_n, bn_lut_n,
			tangent, normal_axis, binormal_axis);

	// Final position: spline center + lateral offset rotated into the frame.
	// (Convention: lateral.x → normal, lateral.y → binormal; matches §5.3.)
	VERTEX = spline_pos + normal_axis * lateral.x + binormal_axis * lateral.y;

	// Normal: rotate the mesh-space normal into the spline frame using the
	// same axis decomposition. Cylinder side faces have along_arc≈0 and a
	// non-zero lateral component; caps have lateral≈0 and along_arc≈±1.
	float n_along_arc;
	vec2 n_lateral;
	tt_decompose_mesh_normal(normalize(NORMAL), n_along_arc, n_lateral);
	NORMAL = normalize(
			normal_axis * n_lateral.x
			+ binormal_axis * n_lateral.y
			+ tangent * n_along_arc);
}

void fragment() {
	// Phase 3a placeholder: solid albedo with simple wrap shading. The hero
	// skin shader (Phase 7) replaces this for cavity walls; tentacles will
	// get their own surface material later.
	ALBEDO = vec3(0.7, 0.45, 0.55);
	ROUGHNESS = 0.55;
	METALLIC = 0.0;
}
