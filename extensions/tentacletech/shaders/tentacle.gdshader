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

// Surface uniforms (§10.2 mask-driven shading).
//
// Feature ID dispatch — values must match BakeContext.FEATURE_ID_*:
//   0 = BODY, 1 = SUCKER_CUP, 2 = SUCKER_RIM, 3 = SPINE, 4 = RIBBON, 5 = WART.
// Vertex-kernel features (knot, ribs, wart) keep BODY tagging — they're
// displaced body, not separate topology. Topology-adding features carry
// their own ID so the fragment can pick distinct surface params.
group_uniforms surface_body;
uniform vec3 body_albedo : source_color = vec3(0.72, 0.45, 0.55);
uniform float body_roughness : hint_range(0.0, 1.0) = 0.55;
// Tip darkening — multiplied by COLOR.a (tip blend, 0=mid-body → 1=apex).
// Authoring features that want a darker glans-like tip can write COLOR.a.
uniform float tip_darken : hint_range(0.0, 1.0) = 0.0;

group_uniforms surface_sucker;
// Cup interior: the floor fan inside each sucker fades from cup_floor_albedo
// at the pit (UV2 disc-radius=0) to cup_albedo at the cup-ring edge.
uniform vec3 cup_albedo : source_color = vec3(0.20, 0.06, 0.08);
uniform vec3 cup_floor_albedo : source_color = vec3(0.05, 0.02, 0.02);
uniform float cup_roughness : hint_range(0.0, 1.0) = 0.7;
uniform vec3 rim_albedo : source_color = vec3(0.85, 0.55, 0.60);
uniform float rim_roughness : hint_range(0.0, 1.0) = 0.25;

group_uniforms surface_appendages;
// Spines / ribbons share the body palette by default but can be retinted.
uniform vec3 spine_albedo : source_color = vec3(0.55, 0.40, 0.45);
uniform float spine_roughness : hint_range(0.0, 1.0) = 0.45;
uniform vec3 ribbon_albedo : source_color = vec3(0.78, 0.50, 0.58);
uniform float ribbon_roughness : hint_range(0.0, 1.0) = 0.40;

group_uniforms surface_masks;
// Photophore mask (COLOR.b) — emissive intensity scaled by the mask. The
// mask-only Photophore feature (§10.2, deferred) will write COLOR.b on body
// verts; until then this branch is dormant on a default mesh.
uniform vec3 photophore_emission : source_color = vec3(0.45, 0.75, 1.00);
uniform float photophore_strength : hint_range(0.0, 8.0) = 0.0;
// Papillae density (COLOR.g) — a roughness perturbation hook for the
// mask-only Papillae feature. Adds COLOR.g * papillae_roughness to body
// roughness; unaffected when the mask is unwritten.
uniform float papillae_roughness : hint_range(-0.5, 0.5) = 0.15;

// Per-vertex feature ID, dispatched in vertex(), branched in fragment().
// `flat` because all three vertices of any given triangle share the same
// feature ID (suckers/spines/ribbons are emitted as standalone topology;
// they don't share triangles with body verts), so interpolation is wasted
// and would produce stripes at the unwritten ≈0.5 boundary.
varying flat float v_feature_id;

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

	// Pass per-vertex feature ID to fragment for surface dispatch.
	v_feature_id = CUSTOM0.x;
}

void fragment() {
	// Feature-ID dispatch (§10.2). Values must match BakeContext.FEATURE_ID_*.
	// The `flat` varying carries the per-triangle integer cleanly; rounding
	// guards against any GPU rasterizer rounding the float edge case.
	int feature = int(v_feature_id + 0.5);

	vec3 albedo = body_albedo;
	float rough = body_roughness;
	vec3 emission = vec3(0.0);

	if (feature == 1) {
		// SUCKER_CUP. The cup is built as: center vertex (at UV2=(0.5,0.5),
		// disc-radius 0) → floor ring (UV2 on disc edge, disc-radius 1) →
		// cup ring (also disc-radius 1). Inside the floor fan UV2's radial
		// coord lerps 0→1 across the pit; outside the floor it pins at 1.
		// Use that to darken the pit center. The cup_ring section reads as
		// the plain cup_albedo because UV2 stays at radius 1 there.
		float disc_r = clamp(length(UV2 - vec2(0.5)) * 2.0, 0.0, 1.0);
		albedo = mix(cup_floor_albedo, cup_albedo, disc_r);
		rough = cup_roughness;
	} else if (feature == 2) {
		// SUCKER_RIM. Wet, low-roughness raised lip.
		albedo = rim_albedo;
		rough = rim_roughness;
	} else if (feature == 3) {
		// SPINE.
		albedo = spine_albedo;
		rough = spine_roughness;
	} else if (feature == 4) {
		// RIBBON / fin. COLOR.b carries the fin mask (= 1 on ribbon strips);
		// mask is informational here — the ID already selected this branch.
		albedo = ribbon_albedo;
		rough = ribbon_roughness;
	} else {
		// BODY (and vertex-kernel features WART/KNOT/RIBS, which retain
		// FEATURE_ID_BODY because they only displace existing body verts).
		// Mask channels apply here — they're the body-surface modulators.
		albedo = body_albedo;
		rough = body_roughness;
		// Papillae (COLOR.g) — roughness perturbation; default mesh has 0.
		rough = clamp(rough + COLOR.g * papillae_roughness, 0.0, 1.0);
		// Photophore (COLOR.b) — emissive; default mesh has 0.
		emission = photophore_emission * photophore_strength * COLOR.b;
		// Tip blend (COLOR.a) — multiplicative darken toward the apex.
		albedo *= mix(1.0, 1.0 - tip_darken, COLOR.a);
	}

	ALBEDO = albedo;
	ROUGHNESS = rough;
	METALLIC = 0.0;
	EMISSION = emission;
}
