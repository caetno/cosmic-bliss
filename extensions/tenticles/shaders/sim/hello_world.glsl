#version 450

// Phase 0 hello-world: writes an animated UV+checker test pattern into an
// rgba8 storage image. Proves the GDExtension -> RenderingDevice -> compute
// dispatch -> Texture2DRD bridge end-to-end. Replaced in Phase 1 by a real
// particle integrator. Pure GLSL 450; do NOT add Godot's `#[compute]` wrapper.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba8) uniform restrict writeonly image2D out_tex;

layout(push_constant, std430) uniform Params {
    float time;
    float _pad0;
    float _pad1;
    float _pad2;
} P;

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size  = imageSize(out_tex);
    if (coord.x >= size.x || coord.y >= size.y) return;

    vec2  uv = vec2(coord) / vec2(size);
    float t  = P.time;

    vec2  cell    = uv * 8.0 + vec2(t * 0.5, 0.0);
    float checker = mod(floor(cell.x) + floor(cell.y), 2.0);

    vec3 col = vec3(uv.x, uv.y, 0.5 + 0.5 * sin(t));
    col = mix(col, vec3(1.0) - col, checker * 0.3);

    imageStore(out_tex, coord, vec4(col, 1.0));
}
