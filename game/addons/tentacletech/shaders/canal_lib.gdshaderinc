// TentacleTech canal interior shader library.
//
// Spec: docs/architecture/TentacleTech_Architecture.md §6.12.5.
//
// **5E status (2026-05-12) — placeholder routing only.**
// The §6.12.5 vertex shader path is documented here as a reusable
// include with identity-stub helpers so:
//
//   - Phase 7's hero_skin shader can `#include "canal_lib.gdshaderinc"`
//     alongside its bulger-array deformation block (§7.1) and call
//     `canal_route_vertex(...)` per vertex. The non-canal branch falls
//     through unchanged.
//   - 5F replaces `centerline_eval`, `centerline_basis`, and
//     `rest_basis_at_s` with the live state lookup
//     (`tunnel_state[canal_id]` texture sample + centerline data
//     texture) without changing the call shape.
//
// In 5E the helpers return identity-equivalents: the deformed
// centerline frame equals the rest spline frame at s, and
// dynamic_radius equals rest_radius. The branch therefore produces
// VERTEX == modeled-mesh rest position — bit-equivalent to skipping
// the routing entirely. This documents the §6.12.5 wiring point
// without committing to a hero-shader prototype that has nothing to
// drive it.
//
// `CUSTOM0.r = canal_index + 1` is the routing key:
//   = 0  → body skin / exterior vert; fall through to bulger path
//   ≥ 1  → canal interior vert; carries per-vert baked (s, θ,
//          rest_radius, rest_outward_normal) in CUSTOM1/CUSTOM2
//          (written by CanalAutoBaker §10.6 step 10).

// 5E identity stubs. 5F replaces these with the live per-canal data
// lookup. The signatures are stable so 5F's change is a body swap,
// not an interface change.
//
// `centerline_eval` returns the world-space position of the deformed
// centerline at arc length s for the given canal. 5E returns the rest
// position (sampled from a per-canal rest-spline data texture, or —
// for the placeholder include with no concrete shader consuming it —
// a stub at the origin).
vec3 centerline_eval(int canal_id, float s) {
	return vec3(0.0);
}

// `centerline_basis` returns the orthonormal frame {tangent, normal,
// binormal} as a mat3 (column 0 = tangent, 1 = normal, 2 = binormal).
// 5E returns identity; 5F samples the live rotation-minimizing frame.
mat3 centerline_basis(int canal_id, float s) {
	return mat3(1.0);
}

// `rest_basis_at_s` returns the REST-pose frame at arc length s on
// the rest spline. Used to map `rest_outward_normal` (stored in canal-
// local coordinates) back through the deformed frame so the lit
// normal tracks the deformed wall correctly. 5E returns identity.
mat3 rest_basis_at_s(int canal_id, float s) {
	return mat3(1.0);
}

// Reads the per-canal `tunnel_state` texture's dynamic_wall_radius
// channel (R) at (s_norm, theta_norm). 5E returns rest_radius
// unconditionally (no concrete texture binding); 5F implements the
// live texelFetch via canal-indexed sampler array.
float sample_dynamic_radius(int canal_id, float s_norm, float theta_norm,
		float rest_radius) {
	return rest_radius;
}

// §6.12.5 vertex routing. Mutates `vertex` and `normal` in place
// when the per-vert canal_id ≥ 0; leaves them untouched otherwise.
// Caller invokes once per vertex; the non-canal branch is a single
// integer test + early return.
//
// Per-vert input contract (written by CanalAutoBaker §10.6 step 10):
//   custom0.r        = canal_index + 1  (0 reserved for "not canal")
//   custom1.rgb      = (s, theta, rest_radius_at_vert)
//   custom2.rgb      = rest_outward_normal in canal-local frame
//   custom2.a        = optional rim-blend factor (§10.4 step 12)
void canal_route_vertex(
		vec4 custom0, vec4 custom1, vec4 custom2,
		float canal_axial_extent, // total arc length of canal centerline (m)
		float canal_angular_period, // typically 2π
		inout vec3 vertex, inout vec3 normal) {
	int canal_id = int(custom0.r) - 1;
	if (canal_id < 0) {
		return;
	}
	float s            = custom1.r;
	float theta        = custom1.g;
	float rest_radius  = custom1.b;
	vec3  rest_normal  = custom2.rgb;

	// Normalize s, θ into texture-sampling coordinates for the
	// per-canal tunnel_state texture (5F: actually samples; 5E: stub).
	float s_norm = (canal_axial_extent > 1e-6)
			? clamp(s / canal_axial_extent, 0.0, 1.0)
			: 0.0;
	float theta_norm = fract(theta / max(canal_angular_period, 1e-6));

	vec3 deformed_pos = centerline_eval(canal_id, s);
	mat3 deformed_basis = centerline_basis(canal_id, s);
	vec3 deformed_outward = deformed_basis
			* vec3(cos(theta), sin(theta), 0.0);

	float dynamic_radius = sample_dynamic_radius(
			canal_id, s_norm, theta_norm, rest_radius);

	vertex = deformed_pos + deformed_outward * dynamic_radius;

	// rest_normal lives in the rest-pose canal-local frame; map it
	// through (rest_basis)⁻¹ → deformed_basis so the lit normal
	// tracks the deformed wall. 5E both frames are identity → no
	// rotation; 5F flips both.
	mat3 rest_basis = rest_basis_at_s(canal_id, s);
	// mat3 inverse() is supported in Godot's GLSL dialect for
	// orthonormal frames; 5F should use transpose() if the basis is
	// guaranteed orthonormal (faster).
	normal = deformed_basis * inverse(rest_basis) * rest_normal;
}
