#[compute]
#version 450

// v1=kinematic-only shader (per Cosmic_Bliss_Update_2026-05-13_body_field_v1_kinematic_only.md).
// 4-bone weighted LBS using tet_skin_indices/tet_skin_weights from .bin v3.
// NOT the prototype's single-bone-assign + XPBD shader — that lives at
// ~/desktop/flesh-deformer/ and reactivates only if v1.5 opens.
//
// Each tet vertex's world position is a 4-bone weighted LBS of its rest
// position against the live per-bone skinning matrices uploaded from the
// CPU side. Padded skin slots use bone-index 0 with weight 0, so they
// contribute zero without needing an early-exit.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) readonly  buffer BT  { mat4  bone_transforms[]; };
layout(std430, set = 0, binding = 1) readonly  buffer TR  { float tet_rest[]; };
layout(std430, set = 0, binding = 2) readonly  buffer SI  { int   tet_skin_indices[]; };
layout(std430, set = 0, binding = 3) readonly  buffer SW  { float tet_skin_weights[]; };
layout(std430, set = 0, binding = 4) writeonly buffer TP  { float tet_pos[]; };

layout(push_constant, std430) uniform PC {
    uint n_verts;
    uint _pad0;
    uint _pad1;
    uint _pad2;
} pc;

void main() {
    uint vi = gl_GlobalInvocationID.x;
    if (vi >= pc.n_verts) return;

    vec3 rest = vec3(tet_rest[vi * 3u + 0u],
                     tet_rest[vi * 3u + 1u],
                     tet_rest[vi * 3u + 2u]);

    vec4 posed = vec4(0.0);
    for (uint k = 0u; k < 4u; ++k) {
        int   b = tet_skin_indices[vi * 4u + k];
        float w = tet_skin_weights[vi * 4u + k];
        posed += w * (bone_transforms[b] * vec4(rest, 1.0));
    }

    tet_pos[vi * 3u + 0u] = posed.x;
    tet_pos[vi * 3u + 1u] = posed.y;
    tet_pos[vi * 3u + 2u] = posed.z;
}
