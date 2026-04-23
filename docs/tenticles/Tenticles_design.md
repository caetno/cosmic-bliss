# Tenticles: custom GPU particle system design

A complete technical design document for a Housemarque‑NGP‑inspired, Godot 4.6+ GDExtension C++ particle/VFX system. **This is a plan, not a tutorial.** It is opinionated, implementation‑dense, and identifies every Godot 4.6 API point that must be re‑verified against the current stable docs before coding.

---

## Scope boundary with TentacleTech

Tenticles renders environmental and ambient particles, including high-count tentacles that are part of level geometry or visual background. **Tenticles particles never collide with, attach to, or otherwise physically interact with the hero character.** Hero-coupled tentacles — any tentacle that can touch, grab, penetrate, or interact with the hero — are rendered by TentacleTech's PBD solver and vertex-shader skinning pipeline. There is no runtime handover between the two systems.

If a scenario appears to require an environmental tentacle grabbing the hero, it is not an environmental tentacle. Author it as a TentacleTech tentacle anchored to level geometry.

## Fluids scope note

Fluid simulation (slime dynamics, body-fluid pooling, dripping, ejaculation, saliva volumes beyond simple strands) is a Tenticles Phase 7+ concern. Until Tenticles reaches fluid-capable phases, hero body-fluid visuals are handled by two other mechanisms: (1) the hero skin shader reads a per-orifice `wetness` scalar from TentacleTech and drives shader parameters (sheen, flow, drip appearance); (2) TentacleTech's fluid-strand-on-withdrawal system (~50 lines in TentacleTech) handles single strands on separation. There is no fluid overlap between the two systems, and no fluids code should be duplicated across extensions.

---

## 0. Executive summary and the opinionated bet

Build a **GPU‑only**, **compute‑driven**, **resource‑coupled** particle system that mirrors Housemarque's NGP architectural principles: any particle can be an emitter, any particle can be a node (parent in a hierarchy), any particle can read from and write to external GPU resources (textures, SDFs, mesh buffers, fluid fields), and any particle can emit triangles directly from its update. **Tentacles** are the first vertical slice because they exercise every axis of the system — neighbor‑aware sim, parent/child hierarchy, per‑particle tube emission, SDF reaction, and (later) fluid coupling.

The single most important architectural call: **reject MultiMesh/ParticleProcessMaterial as the rendering path**. Godot's built‑in GPUParticles3D is not extensible to per‑particle triangle emission and does not compose with a custom compute‑driven hierarchy. Instead the system owns (a) its own RenderingDevice storage buffers, (b) its own SPIR‑V compute pipelines, and (c) a custom draw path that uses `RenderingDevice.draw_list_draw_indirect` (verified present in 4.6) against a compute‑written vertex buffer. Godot is used as the window system, asset system, editor shell, and RenderingServer for high‑level rendering composition — not as the simulation author.

The opinionated bet is **indirect‑draw into a compute‑owned vertex buffer**, not MultiMesh. MultiMesh is a consolation prize when you only need transform‑instanced draws; it cannot express per‑particle triangle counts. Housemarque's NGP tube/ribbon rendering is fundamentally about *dynamic topology per particle*, which requires indirect draw. Godot 4.6 exposes exactly what we need: `draw_list_draw_indirect(draw_list, use_indices, buffer, offset, draw_count, stride)`, confirmed in the `rendering_device.h` source.

---

## 1. What the Returnal/Housmarque technique actually is

The primary public source is the official Housemarque engineering blog (15 September 2021, Jankkila & Jagadeesan, [housemarque.com/news/2021/9/15/returnal-vfx-breakdown](https://housemarque.com/news/2021/9/15/returnal-vfx-breakdown)); the GDC 2022 Visual Effects Summit talk "Can We Do It with Particles?" (GDC Vault id 1027742, YouTube `qbkb8ap7vts`) covers the same material publicly with additional video. Everything below is drawn from that blog or directly derivable from it.

### 1.1 NGP's architectural axioms

**NGP is a GPU‑only VFX authoring system with minimal CPU overhead.** Particle authoring is done by VFX artists who write compute shader snippets that define particle behavior and data; the engine takes care of memory allocation and boilerplate. The system is explicitly *not* only for particle effects — it is used for per‑voxel behavior in volumes and for generating dynamic procedural geometry. Crucially: **any particle can be an emitter**; there is no type distinction between "emitter" and "particle". A "particle" in NGP is literally a text file with HLSL in it declaring a struct plus update function.

### 1.2 Node particles (the hierarchy model)

Verbatim from the blog: *"This particle type allows for creating one-directional parent-child connections. … the connections cannot be established between different particle types. Any particle in the particle buffer may become a parent of a newly added child particle. A particle can be a parent to multiple children but a particle can have only one parent. For these reasons the children can query the parent but the parent cannot query its children. When reading the parent particle the parent data is one frame old, i.e. not the data that is being written to in the current frame."*

Four concrete design facts extracted:

1. **Same‑type constraint.** Parent and child are the same particle struct — this means a single SoA/SSBO is sufficient; no cross‑buffer indirection is needed.
2. **One parent per child, N children per parent.** The memory model is a `uint parent_index` field per particle; no child list.
3. **Parent cannot read children.** Eliminates the need for a gather pass. All communication is child‑reads‑parent.
4. **One‑frame‑old reads.** Children sample from the *previous frame's* particle buffer. This is ping‑pong double buffering used deliberately — the lag is the "organic" motion they prize. It also eliminates read/write hazards and any ordering dependence.

### 1.3 Tube/tentacle rendering (THE central technique for this project)

Verbatim: *"we settled on rendering the tentacles as cylindrical meshes that were constructed from NGP during runtime. … We used Catmull-Rom curves as a base for the cylindrical geometry with particle positions serving as curve control vertices. One of the challenges that we faced with this technique was the high amount of twisting on the curve normals when using analytical tangents. We solved this by doing a per particle normal pre-pass. This was done by picking a suitable normal vector for the first particle in the chain and then projecting child particles normal to a plane defined by their parent's position and normal. By temporally filtering the results we managed to reduce the twisting frequency and turned it into more organic motion along the particle chain."*

This is not Frenet and not textbook parallel‑transport. It is closer to a discrete rotation‑minimizing frame via projection, plus a low‑pass temporal filter. The algorithm is:

1. **Chain root** (parent‑less node particle) picks an initial normal `N₀ ⟂ T₀`, where `T₀` points to its first child.
2. **Each child** computes its own tangent `Tᵢ`, then projects its previous normal onto the plane through its parent's position with parent's normal as plane normal, then re‑orthonormalizes to `Tᵢ`. Formally: take parent's `N_{i-1}` (one frame old), project out the component along the new `Tᵢ`, normalize.
3. **Temporal filter** between frames: `Nᵢ_t = normalize(lerp(Nᵢ_{t-1}, Nᵢ_projected, α))`, `α ≈ 0.2–0.5`.
4. **Catmull‑Rom subdivision** generates smooth intermediate samples between control particles; each sampled point gets a ring.
5. **Ring vertices** placed at `pₖ + (R cos θ) Nₖ + (R sin θ) Bₖ` with `Bₖ = Tₖ × Nₖ`; triangles connect ring k to ring k+1.

This is the project's **canonical algorithm** for tube rendering. We adopt it exactly.

### 1.4 Per‑particle geometry emission

The blog does not expose the precise GPU mechanism, but the PS5 is a RDNA2 device with full Vulkan‑style indirect‑draw, global atomics, and compute‑written vertex buffers. The only sane implementation is: the particle update compute shader writes vertices and indices into a pre‑allocated SSBO using `atomicAdd` on a global counter to reserve contiguous output ranges; a final "build indirect args" compute shader writes a `VkDrawIndexedIndirectCommand` struct; draw path issues one `vkCmdDrawIndexedIndirect`. This is the pattern every GPU‑driven procedural mesh system uses (Wicked Engine, Niagara ribbons, UE5 Nanite's hull expansion in a less radical form). **We replicate this exactly in Godot 4.6 RenderingDevice.**

### 1.5 External resources

Verbatim: *"we have our own fluid simulation module that can feed its simulation data to NGP. Another example is a module called voxeliser which can convert an animated mesh to voxels. … Other resources like textures, bone matrices and vertex buffers can also be used as inputs for particle effects."*

Design implication: the particle system does not know what a "fluid simulation" is. It knows it has **named resource bindings** that resolve to GPU RIDs at dispatch time. The fluid sim is a separate module that owns its textures and publishes them to a resource registry; particles *look up* by name, not by calling into the module. This is exactly the "resources couple modules via data, not code" principle, and it is how we decouple tentacles‑now from fluid‑sim‑later.

### 1.6 Fluid simulation

Directly from the blog: **semi‑Lagrangian grid‑based** (Stam 1999, cited), **unconditionally stable**, takes **density input from particles**, accepts **forces from analytical shapes** (cylinders, spheres) with per‑voxel overlap weighting, **obstacles from SDFs and from per‑frame voxelized skeletal meshes**, **optional vorticity confinement** for detail, **curl‑noise added in particle update** scaled by local fluid velocity magnitude. All runs around the player.

### 1.7 Voxelizer

The voxelizer is based on Eisemann & Décoret 2008 (cited in the blog): single‑pass solid voxelization via depth‑per‑pixel XOR into a bit‑packed 2D virtual texture. Specifically Housemarque uses R32_UINT with a 4×2 pixel tile encoding 256 depth slices (32 bits × 8 pixels), mesh rotated so its long axis aligns with the depth axis of the virtual texture, then resolved to a 3D texture with optional downsampling. For non‑watertight meshes they fall back to encoding bone index in an unused vertex color channel and extruding particles from surface to bone.

### 1.8 Volumetric fog volumes

Fog volumes are themselves NGP particle systems: a particle per voxel, each particle stores a 3‑D index and whatever per‑voxel state it needs, volume bounds pushed as CPU constants. The particle update samples global fluid velocity at its world position and advects local density. Density is adaptively increased near surfaces (by sampling local SDF) and faded near volume bounds.

### 1.9 Authoring UI

*"By particle, Housemarque means a text file with some HLSL code in it."* The engine's graphical editor was added after Resogun and is auto‑generated from declarations in the shader file (curves, color pickers, tweakables). The exact annotation grammar is not public. For our purposes the pattern is what matters: **compute shader is the source of truth; the inspector UI is a reflection of declared parameters**.

---

## 2. GPU spatial hashing and neighbor queries

The system must support true neighbor queries on GPU — not fixed chains, not CPU broad‑phase. The recommended algorithm is a **counting‑sort bounded uniform grid with cell‑linear indexing**, following Hoetzlein's Fluids v3 (GTC 2014) pattern. It beats Simon Green's CUDA‑Particles radix‑sort path (~3× fewer dispatches), beats Müller's tenMinutePhysics unbounded hash on cache locality when the domain is bounded, and maps cleanly to Vulkan/GLSL 450.

### 2.1 Memory layout (std430)

```
Params (UBO)         : gridOrigin vec3, cellSize float, gridDim ivec3, numCells uint,
                        invCellSize float, maxParticles uint, particleCount uint
ParticlesA/B         : Particle[maxParticles]   // ping-pong, reordered after sort
CellCount            : uint[numCells]           // cleared each frame
CellStart            : uint[numCells+1]         // prefix sum result
ParticleCellIdx      : uint[maxParticles]       // filled in count pass
LocalOffset          : uint[maxParticles]       // slot within cell
AliveCount           : uint[1]                  // for indirect dispatch
FreeList + FreeTop   : stack of dead slots for spawn
IndirectArgs         : DrawIndexedIndirectCommand + DispatchIndirectCommand
```

**Critical GLSL gotcha:** `vec3` in `std430` is padded to 16 bytes (Godot issue #81511). Always use `vec4` with the `w` component carrying `life`, `type`, `parent_index`, etc., or declare `float pos[3]` explicitly. Every design below assumes vec4 packing.

### 2.2 Five-pass per-frame pipeline

1. **Clear cell counts** — one thread per cell.
2. **Count + local offset** — one thread per particle; `atomicAdd(CellCount[c], 1u)` returns the pre‑increment value, stored as `LocalOffset[i]`.
3. **Exclusive prefix sum** over `CellCount` → `CellStart`. Use subgroup‑arithmetic scan (`subgroupExclusiveAdd`) with per‑workgroup block sums and a second pass scanning block sums. For `numCells < 2M`, a two‑level scan is sufficient; for larger grids use Raph Levien's decoupled look‑back single‑pass scan (requires Vulkan memory model, which Godot 4.6 provides on Vulkan 1.2).
4. **Scatter (counting sort)** — each particle writes to `ParticlesOut[CellStart[c] + LocalOffset[i]] = ParticlesIn[i]`.
5. **Simulation** — per‑particle kernel reads 3×3×3 cell neighborhood via `[CellStart[c], CellStart[c+1])` ranges over the sorted array.

Build cost at 100k particles on a mid‑range desktop GPU (RTX 3060 / RX 6700 class) is roughly 0.3–0.5 ms for passes 1–4; 10 constraint‑solver iterations of pass 5 at ~0.5–1 ms each. Rebuilding the grid once per simulation step and reusing across all solver iterations is a free 3–5× win (this is what Macklin/Müller PBF 2013 calls out explicitly).

### 2.3 Core GLSL skeleton (pass 2, count + local offset)

```glsl
#[compute]
#version 450
layout(local_size_x = 256) in;

layout(set=0, binding=0, std140) uniform Params { /* as above */ } P;

struct Particle { vec4 posLife; vec4 velType; vec4 parentData; vec4 extra; };
layout(set=0, binding=1, std430) restrict buffer In  { Particle d[]; } Pin;
layout(set=0, binding=3, std430) restrict buffer CC  { uint d[]; }    Cnt;
layout(set=0, binding=5, std430) restrict buffer PCI { uint d[]; }    PCell;
layout(set=0, binding=6, std430) restrict buffer LO  { uint d[]; }    LOff;

uint cellLinear(ivec3 c) {
    c = clamp(c, ivec3(0), P.gridDim - 1);
    return uint(c.x + c.y*P.gridDim.x + c.z*P.gridDim.x*P.gridDim.y);
}

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= P.particleCount) return;
    Particle p = Pin.d[i];
    if (p.posLife.w <= 0.0) { PCell.d[i] = 0xFFFFFFFFu; return; }
    ivec3 c  = ivec3(floor((p.posLife.xyz - P.gridOrigin) * P.invCellSize));
    uint  ci = cellLinear(c);
    PCell.d[i] = ci;
    LOff.d[i]  = atomicAdd(Cnt.d[ci], 1u);
}
```

### 2.4 Dynamic particle counts: free‑list + indirect dispatch

No `AppendStructuredBuffer` on Vulkan. The standard emulation (Wicked Engine pattern): a free‑list stack `{ uint top; uint slots[]; }` of dead slot indices. Spawn does `uint freeIdx = atomicAdd(top, -1u) - 1u; if (int(freeIdx) < 0) bail; slot = slots[freeIdx]; Pin[slot] = newParticle;`. Death pushes the slot back: `slots[atomicAdd(top, 1u)] = i`. After each simulation step a tiny 1‑thread pass writes `IndirectArgs.dispatchX = (aliveCount + 127) / 128`; subsequent simulation passes use `compute_list_dispatch_indirect(list, indirect_rid, offset)`. This is confirmed available in Godot 4.6 (source `rendering_device.h`: `void compute_list_dispatch_indirect(ComputeListID, RID, uint32_t)`).

### 2.5 Neighbor query pattern (3×3×3, cell = kernel radius h)

Sweet spot is `cellSize == interactionRadius`: 27 cells visited per particle, ≈32 candidates of which ≈10 are true neighbors. Using `cellSize == h/2` with 125 cells is almost never a win for <500k particles. Within the inner loop, particles in the same cell are contiguous in the sorted array — this is the single biggest coalescing win and the reason to reorder rather than just index. For chained neighbor cells along x, reading `Start[c-1]..Start[c+2]` as a single range covers three cells in one loop.

### 2.6 When to use an unbounded hash instead

Only if the simulation domain is genuinely unbounded (e.g., open world vegetation not tied to a player‑centered grid). Then use Teschner 2003 hash `(x·p1) ^ (y·p2) ^ (z·p3) mod N` with `N ≈ 2 × maxParticles`. The counting‑sort pipeline is otherwise identical; only the `cellLinear` function changes. Accept that the 3‑cell‑strip loop fusion is lost and adjacent hashed cells may collide with non‑adjacent cells (benign — the r² check filters them out).

---

## 3. Godot 4.6 implementation reality check

All of this is verified against current docs and the `godotengine/godot` master source. **Every claim below should be re‑checked against your pinned 4.6 tag before committing code.**

### 3.1 Confirmed present in 4.6

- **`RenderingDevice.compute_list_dispatch_indirect(compute_list, buffer, offset)`** — confirmed.
- **`RenderingDevice.draw_list_draw_indirect(draw_list, use_indices, buffer, offset, draw_count, stride)`** — confirmed. This is the cornerstone of per‑particle triangle emission. Community demos (forum thread 131114, "marching cubes using DrawListDrawIndirect") confirm end‑to‑end compute‑to‑indirect‑draw works.
- **`RenderingDevice.shader_compile_spirv_from_source(RDShaderSource) -> RDShaderSPIRV`** — confirmed, accepts pure GLSL (not Godot `#[compute]` wrapper).
- **`Texture2DRD` / `Texture3DRD`** — confirmed; both wrap a RenderingDevice texture RID via `texture_rd_rid` and can be assigned to `sampler2D`/`sampler3D` uniforms on a standard `ShaderMaterial`. This is the SSBO‑to‑spatial‑shader bridge.
- **`RenderingServer.call_on_render_thread(callable)`** — confirmed. Essential: any code touching the global RenderingDevice must run on the render thread.
- **`RenderingServer.multimesh_get_buffer_rd_rid(multimesh) -> RID`** — confirmed (merged pre‑4.3, available in 4.6). Compute can write multimesh instance data directly.
- **`CompositorEffect` + `Compositor`** — confirmed; marked experimental but functional and GDExtension‑overridable since PR #99981. `_render_callback(callback_type, render_data)` is the hook.
- **`StorageBufferUsage` enum includes `DISPATCH_INDIRECT` and `DEVICE_ADDRESS` flags** — confirmed. Empirically, storage buffers with `DISPATCH_INDIRECT` also serve as draw‑indirect sources; validation layers accept it.
- **`EditorInspectorPlugin` registrable from GDExtension C++** — confirmed since 4.2, unchanged in 4.6.

### 3.2 Confirmed absent in 4.6 (so workarounds are mandatory)

- **Spatial shaders cannot bind SSBOs directly.** Only scalars, matrices, samplers. The Texture2DRD/Texture3DRD bridge is the only supported route: compute writes to an RD texture, a Texture2DRD wrapper exposes it, the spatial ShaderMaterial samples it with a regular `sampler2D`. For particle billboards this means packing position/color/size into RGBA texels keyed by `INSTANCE_ID`.
- **`multimesh_set_buffer_rd` does not exist** — only the CPU‑roundtrip `multimesh_set_buffer(PackedFloat32Array)`. Writing via `multimesh_get_buffer_rd_rid()` works but has a known sync bug (issue #105113) where the renderer sometimes doesn't pick up GPU‑written data until a CPU roundtrip happens. **Don't rely on MultiMesh for the primary render path.** It is acceptable for simple transform‑only particle effects (sparks, dust) as a secondary path.
- **No mesh shader exposure.** `VK_EXT_mesh_shader` is not surfaced. Stick to compute‑writes‑vertex‑buffer + indirect draw.
- **No runtime parsing of Godot's `#[compute]` `.glsl` wrapper from GDExtension** (proposal #6691). You must either (a) import shaders through the editor as `.res` and `load()` them, or (b) pass pure GLSL strings to `RDShaderSource.source_compute`. We pick (b) — it gives true runtime hot‑reload.
- **No reliable hot‑reload of `RDShaderFile` from external editor** (issue #110468, open at 4.5‑rc2 and still unaddressed in 4.6 release notes). Workaround: use `FileAccess` to read raw `.glsl` text, call `shader_compile_spirv_from_source` ourselves, ignore the importer entirely. We build our own include preprocessor.

### 3.3 Requires verification against your exact 4.6 tag

- **`draw_list_begin` parameter list** — third‑party 4.6 change summary claims many parameters removed and an optional breadcrumb added. Confirm against `docs.godotengine.org/en/4.6/tutorials/migrating/upgrading_to_godot_4.6.html` before adopting.
- **4.6 Shader Baker** — does it apply to `RDShaderFile`? Unknown from release notes; assume it does not affect custom RD compute shaders.
- **Godot 4.6 switched Windows default to D3D12** for new projects. RD compute is driver‑abstracted but push‑constant alignment and some buffer usage bits differ; validation should be run on both Vulkan and D3D12.

### 3.4 Rendering path decision matrix

| Path | Topology per particle | Lighting | Shadows | Custom material | Verdict |
|---|---|---|---|---|---|
| Built‑in `GPUParticles3D` | Fixed quad/mesh | Yes | Yes | ParticleProcessMaterial only | **Reject** — no hierarchy, no per-particle triangles, extending it is abandoning the whole design. |
| MultiMesh + compute writes to instance buffer RD RID | Fixed per-instance mesh | Yes (via standard material) | Yes | Yes | Secondary path only. Has sync bug #105113; no per‑particle triangle counts. |
| Texture2DRD-backed spatial shader sampling by INSTANCE_ID | Fixed billboard | Via material | Yes | Yes | Use for point-sprite-style effects. |
| **`draw_list_draw_indirect` with compute-written vertex buffer** | **Arbitrary** | Via custom pipeline | **Manual** | **Yes (our own)** | **Primary path for tubes, ribbons, destructibles.** |
| `CompositorEffect` compute pass | N/A (post-process) | N/A | N/A | N/A | Use for fluid sim injection, volumetric integration. |

**Decision:** the primary render path for tentacles, ribbons, and destructibles is indirect draw with a compute‑owned vertex buffer, drawn into a custom framebuffer that is composited via a `CompositorEffect`. Shadow casting is handled by registering a shadow variant of the pipeline and drawing into the shadow atlas as a second `CompositorEffect` callback attached to shadow‑map passes. For lighting, we sample Godot's GI (SDFGI/VoxelGI) via their published RID accessors in the fragment shader. Accept that this is more work than MultiMesh; it is the only way to get NGP‑level expressiveness.

---

## 4. Architecture for Codename Udon

### 4.1 Node and Resource hierarchy

- **`UdonParticleSystem : Node3D`** — the scene‑level simulation owner. Holds a `UdonParticleDefinition` resource, an `emitter_resources: Array[UdonParticleEmitter]`, a max‑particle budget, an AABB, and a `compositor_effect` that hooks into the camera's `Compositor`.
- **`UdonParticleDefinition : Resource`** — the compiled particle type. Fields: `shader_path`, introspected `schema: Array[UdonParamDef]`, `params: Dictionary`, `curves: Dictionary[String, Curve]`, `textures: Dictionary[String, Texture2D/3D]`, bound external resources (see §4.4).
- **`UdonParticleEmitter : Resource`** — a spawn source. Subclasses: `UdonPointEmitter`, `UdonShapeEmitter`, `UdonMeshEmitter`, `UdonNodeChildEmitter` (spawns N children on every particle matching a predicate, the foundation for tentacles).
- **`UdonParticleMaterial : Resource`** — the render‑side shader and per‑effect parameters. Separate from the compute shader on purpose: simulation and rendering evolve independently.
- **`UdonFluidVolume : Node3D`** — (phase 3) a player‑following fluid sim. Publishes `velocity`, `density`, `obstacle_sdf` RIDs into a global resource registry keyed by name.
- **`UdonSDFBaker : Node3D`** — (phase 3) wraps static meshes and baked SDFs, publishing them into the registry.
- **`UdonResourceRegistry` (autoload)** — name → RID table, the single point of indirection that couples producers and consumers without code dependencies. Producers call `register("global_fluid.velocity", texture_rd_rid)`; consumers (particle dispatches) look up at bind time. This is the mechanism that lets fluid sim be added later without touching the tentacle code.

### 4.2 Canonical particle struct

```glsl
// udon/particle.glsl — included by every particle shader
struct Particle {
    vec4 posLife;       // xyz = world pos,  w = life (seconds)
    vec4 velType;       // xyz = velocity,   w = particle type packed
    vec4 parentData;    // x = parent index (uint bitcast), y = depth, zw = custom
    vec4 normalUv;      // xyz = normal (for tubes/ribbons),  w = arcLength
    vec4 color;         // rgba
    vec4 user0;         // free slot for effect‑specific data
    vec4 user1;
    vec4 user2;
};
// total = 128 B per particle. 500k = 64 MB. Budget this; double‑buffered = 128 MB.
```

### 4.3 Authoring flow (shader is source of truth)

A particle effect is a single `.udon.glsl` file:

```glsl
// udon/effects/tentacle.udon.glsl

// @param name="segment_spacing" min=0.05 max=0.5 default=0.15 ui=slider
// @param name="base_radius"     min=0.01 max=0.3  default=0.06 ui=slider
// @param name="tip_radius"      min=0.0  max=0.1  default=0.005 ui=slider
// @curve name="radius_over_length" range=(0,1) default=1.0
// @curve name="color_over_life"    type=color
// @texture name="base_color_map"   dim=2D
// @resource name="player_sdf"      type=global_sdf
// @resource name="fluid_velocity"  type=fluid_velocity_3d  optional=true

#include "udon/particle.glsl"
#include "udon/tube_emission.glsl"

void update_particle(inout Particle p, uint idx, float dt) {
    // read parent (one frame old) from the previous buffer
    Particle par = read_parent(p);
    // projected-normal pass — canonical Housemarque technique (§1.3)
    vec3 T = normalize(par.posLife.xyz - p.posLife.xyz);
    vec3 N_prev = p.normalUv.xyz;
    vec3 N_proj = normalize(N_prev - dot(N_prev, T) * T);
    p.normalUv.xyz = normalize(mix(N_prev, N_proj, 0.3));
    // SDF reaction
    float d = sample_resource_sdf("player_sdf", p.posLife.xyz);
    vec3  g = sdf_gradient("player_sdf",       p.posLife.xyz);
    if (d < 0.5) p.velType.xyz += g * (0.5 - d) * 20.0 * dt;
    // fluid drag (optional binding — resolved at compile time)
    #ifdef HAS_RES_fluid_velocity
        vec3 v = sample_resource_vel3d("fluid_velocity", p.posLife.xyz);
        p.velType.xyz = mix(p.velType.xyz, v, 1.0 - exp(-2.0 * dt));
    #endif
    // integrate
    p.posLife.xyz += p.velType.xyz * dt;
    p.posLife.w   -= dt;
    // emit tube segment between self and parent
    emit_tube_ring(p, par, curve_sample("radius_over_length",
                                         p.parentData.y / float(CHAIN_LENGTH)),
                   /*ring_sides=*/ 8);
}
```

The `@param`, `@curve`, `@texture`, `@resource` annotations are parsed by our C++ preprocessor at import time. Each annotation becomes an entry in the `UdonParticleDefinition.schema` array, which drives: (a) the auto‑generated inspector UI, (b) uniform set construction, (c) `#define HAS_RES_*` flags for the `#ifdef` path.

### 4.4 Resource binding

Every external resource is a named slot resolved at pipeline‑build time. The registry provides one of the canonical types:

- `global_sdf` → `Texture3D<float>` (sampler3D) + world‑to‑grid transform UBO
- `fluid_velocity_3d` → `Texture3D<vec4>` + grid transform
- `fluid_density_3d` → `Texture3D<float>` + grid transform
- `skeletal_voxels` → `Texture3D<uint>` + mesh transform
- `mesh_vertex_buffer` → `StorageBuffer<Vertex>` + per‑piece table
- `bone_matrices` → `StorageBuffer<mat4>`

A compile step inspects the `@resource` annotations, queries the registry for the published types, and generates the correct `layout(set=N, binding=M) uniform sampler3D ...` declarations plus a helper accessor (`sample_resource_vel3d`). Missing optional resources are `#ifdef`'d out. Missing required resources fail at shader compile with a clear error.

This is the architectural lever that makes "fluid simulation comes later" actually work: **tentacle shaders today declare `@resource fluid_velocity optional=true`; the resource registry has nothing under that name; the shader compiles with `HAS_RES_fluid_velocity` undefined**. When the fluid module lands, it registers into the same name and no tentacle code changes.

### 4.6 Data layout across multiple particle systems

Each `UdonParticleSystem` owns its own particle SSBO, but shares the spatial grid SSBO only if it wants cross‑system neighbor queries. For tentacles we do not — tentacle neighbor queries are intra‑chain only and parent/child pointers suffice. For vegetation we eventually want a shared per‑player grid. Model: each `UdonParticleSystem` declares a `neighbor_domain` resource name; systems sharing a domain share a grid; systems in their own domain get their own grid. Default domain is `"none"` (no grid at all; use for strictly hierarchical systems).

---

## 5. Tube tentacle implementation

### 5.1 Per‑frame pipeline for a single tentacle system

1. **Parent pointer fixup pass** — when a child particle's parent has died, re‑parent or mark dead.
2. **Simulate** — update position/velocity/life per §4.3 shader. Reads previous‑frame buffer. Writes to current buffer.
3. **Normal propagation pass** — for each particle, compute projected normal from parent's normal as in §1.3. Already folded into step 2 in the example above; separate if you want explicit temporal filtering across iterations.
4. **Catmull‑Rom tessellation + ring emission pass** — one workgroup per chain (`local_size_x = chainLength × ringSides`). Thread layout: `thread.y` = ring index along arc (subdivided); `thread.x` = ring vertex index. Each thread:
   - Computes the Catmull‑Rom interpolated position at parametric position along the chain from four control particles `P_{k-1}, P_k, P_{k+1}, P_{k+2}`.
   - Interpolates tangent and normal likewise.
   - Writes one vertex: `pos + (R cos θ) N + (R sin θ) B` plus normal, UV, tangent.
   - Atomically reserves its vertex slot via `atomicAdd(VertexCount, 1)` — but since topology is fixed per frame's chain count, we pre‑allocate at known positions and skip the atomic.
5. **Index generation pass** — typically unnecessary because the triangle topology for a fixed (chainLength × ringSides) is regular; pre‑compute a static index buffer once and reuse. If tentacle length varies per particle, emit indices in this pass with a compaction atomic.
6. **Indirect args writeback** — one thread writes `DrawIndexedIndirectCommand { indexCount = liveChains × (chainLen-1) × ringSides × 6, instanceCount = 1, firstIndex = 0, vertexOffset = 0, firstInstance = 0 }` into the indirect buffer.
7. **Draw** — `CompositorEffect` post‑opaque callback ends compute list, begins draw list against the main framebuffer, binds the custom tube pipeline, issues `draw_list_draw_indirect(draw_list, true, indirect_rid, 0, 1, 0)`.

### 5.2 Why Catmull‑Rom over pure control‑point-per‑particle

Housemarque explicitly chose Catmull‑Rom to get smooth tube surfaces between control particles. At a typical chain length of 8–16 particles and 4 subdivisions per segment, this yields 32–64 rings per tentacle — enough to look smooth at close range without subdivision shader complexity. Catmull‑Rom's `C¹` continuity matters: `C⁰`‑only (linear) interpolation visibly creases at ring boundaries under specular lighting.

### 5.3 The twisting problem and the chosen fix

Analytical Frenet normals flip at inflection points and twist unpredictably under temporal particle motion. Parallel‑transport along the curve is stable spatially but still noisy temporally when control points jitter. Housemarque's fix — **project child normal onto plane of parent's position + normal, temporally low‑pass** — is a discrete rotation‑minimizing frame with temporal smoothing. It is what we implement. Temporal smoothing ratio `α ∈ [0.2, 0.5]`; lower = more stable, higher = snappier response.

For the chain root (`parent_index == INVALID`), seed with a stable reference vector — the enemy bone's local Y axis typically — carried across frames via a per‑chain root buffer that the simulation updates before propagation starts.

### 5.4 Player reaction

Four forces applied in the update shader, weighted by authored curves:

1. **SDF repulsion** from player: `force += gradient_sdf(player_sdf, p) * repulsion_strength * smoothstep(R, 0, d)` where `d = sample(player_sdf, p)`.
2. **SDF attraction** (for grabbing behaviors): `force += (playerPos - p) * attraction_strength * smoothstep(R_outer, R_inner, distance)`.
3. **Chain distance constraint** (Verlet / PBD style, 5–10 iterations per frame) to keep rest length `L` between parent and child: `p += 0.5 * (d − L) * dir; par -= 0.5 * (d − L) * dir` with `par` read‑only (we mutate only self, parent sees the correction one frame later — consistent with the one‑frame‑old model).
4. **Fluid drag** (optional resource) as shown in §4.3.

### 5.5 LOD and culling

- Per‑tentacle CPU‑side frustum cull using the bounding sphere around root position plus max chain length. Send a `uint[] aliveChains` list to the GPU; simulation runs always, rendering is the gated stage.
- Ring count drop: 12 sides at <5 m, 8 at 5–15 m, 6 at 15–30 m, 4 beyond. Reduces vertex count 9× at distance.
- Subdivision drop: 4 Catmull‑Rom subdivisions up close, 2 at medium, 1 (control points only) far.
- Merge short segments: if `|P_{i+1} − P_i| < ε`, emit a single ring lerping the two.
- Shadow LOD: always one tier lower than primary LOD.

---

## 6. Fluid simulation integration plan (phase 3)

Not built yet, but every architectural choice above must make fluid integration straightforward. The plan:

### 6.1 Grid topology

One 64³ player‑following grid, collocated cell‑centered, `R16G16B16A16_SFLOAT` for velocity + `R16_SFLOAT` for density + `R16_SFLOAT` ping‑pong for pressure. 64³ × 4 bytes × ~6 textures ≈ 6 MB. Good headroom for a second 32³ coarse level if wind must reach distant effects.

### 6.2 Player‑following via toroidal addressing

Grid origin snaps to integer texel positions: `gridOrigin = floor((playerPos - halfExtent) / cellSize) * cellSize`. Texel snapping eliminates shimmer. Contents do not move — lookups use `storeId = (logicalId + clipOffset) & (N-1)` with `N` power of two. When the player moves by `Δ` texels, only the newly exposed slab needs to be cleared (up to 6 thin slabs, typically 1–2 at normal gameplay speeds).

### 6.3 Per‑step passes (one simulation tick)

1. Clear newly‑exposed slabs.
2. Inject forces from analytical shapes + gameplay events.
3. Add density from particle scatter (`imageAtomicAdd` into quantized R32_UINT density, or `VK_EXT_shader_atomic_float`).
4. Semi‑Lagrangian advect velocity (RK2 backtrace with hardware trilinear `sampler3D`).
5. Advect density (same kernel).
6. Optional vorticity confinement (two passes: curl, then confine force).
7. Rasterize dynamic obstacle SDF: capsule list from skeletal bones (cheap, 60–150 capsules, <0.1 ms at 64³) union with pre‑baked environment SDF.
8. Compute divergence.
9. Jacobi pressure iterations (10–20 for game quality).
10. Gradient subtract + enforce obstacle velocity.

Budget: ~1.2 ms at 64³/10 iterations on RTX 2060 class. Scales 8× linearly to 128³.

### 6.4 Hooks exposed NOW

The fluid module will publish three resources by name: `global_fluid.velocity`, `global_fluid.density`, `global_fluid.grid_transform`. The particle system's `@resource` annotation grammar already accepts these names; we define their types in the registry today. Every tentacle shader that plans to react to wind declares `@resource global_fluid.velocity optional=true` now. Until the fluid module exists, the shader compiles with the `#ifdef` stub; when it lands, the shader recompiles once on reload and picks up the real binding.

### 6.5 Particles writing back to the fluid

Particles splat density via trilinear 8‑cell scatter with `imageAtomicAdd` on a quantized uint volume, followed by a divide‑by‑scale resolve pass. Velocity injection uses a per‑cell force buffer (not the velocity field directly — writing velocities breaks divergence‑free‑ness); the forces are added during step 2 of the next simulation tick. This two‑way coupling is how tentacles moving through the air disturb local wind, which disturbs vegetation.

### 6.6 Volumetric fog from fluid density

Phase 3b: Froxel (Wronski 2014) volumetric fog. Per froxel, world‑transform to the fluid grid, sample density with trilinear, accumulate scattering. Godot's built‑in `FogVolume` supports a user shader outputting density — we declare a `sampler3D` uniform pointing at the fluid density `Texture3DRD` and sample with the world‑to‑grid transform as a shader parameter. Zero custom rendering required here; it's a direct consumer of the resource registry.

---

## 7. File‑by‑file implementation plan

### 7.1 Tree

```
udon_gdextension/
├── SConstruct                                  # godot-cpp build
├── udon.gdextension                            # extension manifest
├── src/
│   ├── register_types.cpp                      # GDExtension entry
│   ├── core/
│   │   ├── udon_resource_registry.h/.cpp       # name→RID autoload singleton
│   │   ├── udon_rd_utils.h/.cpp                # RID wrappers, barrier helpers
│   │   ├── udon_shader_preprocessor.h/.cpp     # @annotation parser, #include expander
│   │   ├── udon_shader_cache.h/.cpp            # SPIR-V cache, file-watcher hot reload
│   │   └── udon_indirect_args.h                # DrawIndexedIndirectCommand layout
│   ├── sim/
│   │   ├── udon_particle_system.h/.cpp         # Node3D, per-frame orchestration
│   │   ├── udon_particle_definition.h/.cpp     # Resource, schema + params
│   │   ├── udon_particle_emitter.h/.cpp        # emitter base + subclasses
│   │   ├── udon_spatial_grid.h/.cpp            # counting-sort uniform grid
│   │   ├── udon_free_list.h/.cpp               # spawn/destroy slot manager
│   │   └── udon_compute_pipeline.h/.cpp        # SPIR-V compilation + uniform sets
│   ├── render/
│   │   ├── udon_tube_renderer.h/.cpp           # Catmull-Rom + ring emission
│   │   ├── udon_point_renderer.h/.cpp          # Texture2DRD billboard path
│   │   ├── udon_destructible_renderer.h/.cpp   # piece-per-particle indirect draw
│   │   ├── udon_compositor_effect.h/.cpp       # CompositorEffect subclass for draw
│   │   └── udon_particle_material.h/.cpp       # Resource, render shader
│   ├── fluid/                                  # phase 3, stubbed today
│   │   ├── udon_fluid_volume.h/.cpp
│   │   └── udon_fluid_passes.h/.cpp
│   ├── voxel/                                  # phase 3, stubbed today
│   │   ├── udon_voxelizer.h/.cpp
│   │   ├── udon_sdf_baker.h/.cpp
│   │   ├── udon_marching_cubes.h/.cpp
│   │   └── udon_jfa.h/.cpp
│   ├── editor/
│   │   ├── udon_editor_plugin.h/.cpp           # EditorPlugin registration
│   │   ├── udon_inspector_plugin.h/.cpp        # EditorInspectorPlugin
│   │   ├── udon_param_editors.h/.cpp           # slider, color, curve, tex editors
│   │   └── udon_shader_hot_reload.h/.cpp       # FileAccess watcher
│   └── util/
│       ├── udon_log.h
│       └── udon_math.h                          # Catmull-Rom, RMF helpers
├── shaders/
│   ├── include/
│   │   ├── particle.glsl                       # Particle struct
│   │   ├── spatial_grid.glsl                   # cellLinear, cellHash, lookup macros
│   │   ├── hash.glsl                           # noise, random
│   │   ├── curl_noise.glsl
│   │   ├── tube_emission.glsl                  # emit_tube_ring, Catmull-Rom
│   │   ├── resource_access.glsl                # sample_resource_* macros
│   │   └── constants.glsl
│   ├── sim/
│   │   ├── grid_clear.glsl
│   │   ├── grid_count.glsl
│   │   ├── grid_scan_block.glsl
│   │   ├── grid_scan_final.glsl
│   │   ├── grid_scatter.glsl
│   │   ├── spawn.glsl
│   │   ├── integrate.glsl
│   │   └── write_indirect_args.glsl
│   ├── tube/
│   │   ├── normal_pre_pass.glsl
│   │   ├── catmull_rom_tessellate.glsl
│   │   └── ring_emit.glsl
│   ├── destructible/
│   │   └── piece_transform.glsl
│   └── render/
│       ├── tube.vert / tube.frag
│       └── point.vert / point.frag
└── effects/                                    # authored by artists
    ├── tentacle.udon.glsl
    ├── bullet_trail.udon.glsl
    └── test_neighbor.udon.glsl
```

### 7.2 Key class responsibilities

**`UdonParticleSystem`** — orchestrator. In `_ready` it compiles its `UdonParticleDefinition` via `UdonShaderCache`, allocates RD buffers via `UdonRDUtils`, creates uniform sets. In `_process` it enqueues a `RenderingServer.call_on_render_thread` closure that records the full per‑frame command list: spatial grid build → simulate → normal pass → tube tessellate → indirect args → emit draw indirectly via its `UdonCompositorEffect`. Holds lifetime of all RIDs and frees them in `_exit_tree`.

**`UdonSpatialGrid`** — encapsulates the 5‑pass counting‑sort build. Exposes `build(compute_list, particle_buffer, alive_count)` and `query_uniform_set()` that downstream shaders bind. Has fixed‑size grid and unbounded‑hash variants behind a build flag.

**`UdonShaderPreprocessor`** — regex tokenizer that scans `.udon.glsl` for `@param/@curve/@texture/@resource` annotations preceded by `// @`, builds a `ShaderSchema` (flat array of `{name, type, widget, min, max, default, label}`), inlines `#include "udon/*.glsl"` from the include path, resolves `@resource` declarations against the registry and emits matching `layout(...) uniform ...` blocks plus `#define HAS_RES_<name>`. Emits final pure GLSL 450 string for `shader_compile_spirv_from_source`.

**`UdonShaderCache`** — keyed by `(path, preprocessor_hash, godot_version)`; persists SPIR‑V to disk under `user://udon_spirv_cache/`; on file change invalidates and recompiles. Provides hot‑reload on `NOTIFICATION_APPLICATION_FOCUS_IN` via `FileAccess` modification‑time scan.

**`UdonTubeRenderer`** — holds the pre‑computed static index buffer for the canonical (chainLenMax × ringSidesMax) topology, a pair of vertex SSBO+vertex‑format RIDs (ping‑pong), a graphics pipeline RID, an indirect args buffer RID. Its `tessellate_and_emit_indirect(compute_list, particle_buffer, chain_count)` chains Catmull‑Rom and ring‑emit passes. Its `draw(draw_list)` binds and calls `draw_list_draw_indirect`.

**`UdonCompositorEffect`** — subclass of `CompositorEffect`, `effect_callback_type = EFFECT_CALLBACK_TYPE_POST_OPAQUE`. In `_render_callback` it obtains the color+depth buffers from `render_data.get_render_scene_buffers()`, begins a draw list against them, iterates the owning `UdonParticleSystem`'s renderers and issues their indirect draws. This is the clean integration point with Godot's renderer.

**`UdonInspectorPlugin`** — subclass of `EditorInspectorPlugin`. `_can_handle` returns true for `UdonParticleDefinition`. `_parse_begin` adds a "Reload shader" button. `_parse_property` replaces the default editor for each `params/curves/textures` dictionary key with a custom `EditorProperty` built from the schema entry (slider, color, curve editor, file picker). `_parse_end` shows compile status.

### 7.3 Implementation phases

**Phase 0 — Skeleton (1 week).** `register_types.cpp`, extension manifest, empty `UdonParticleSystem` node, RD handshake via `call_on_render_thread`, a hello‑world compute dispatch that writes a test pattern into a `Texture2DRD` visible in a ShaderMaterial. Establishes the build, the render‑thread discipline, and GDExtension↔Godot plumbing.

**Phase 1 — Linear particles without hierarchy (1–2 weeks).** One particle SSBO, one emitter (point), one compute kernel that integrates position/velocity, point renderer using `Texture2DRD` + spatial shader `INSTANCE_ID` sampling. No neighbors yet. Free list + indirect dispatch. This proves the core compute loop and the RID lifetime model.

**Phase 2 — Spatial grid (1 week).** Counting‑sort uniform grid, 5 passes, indirect dispatch sizing. Demo: 50k particles with repulsion forces between neighbors. No rendering change; particles still render as points. This is the neighbor‑query foundation.

**Phase 3 — Node particles + tube renderer (2–3 weeks).** Parent/child pointers, ping‑pong buffer discipline, normal pre‑pass with temporal filtering, Catmull‑Rom tessellation, ring emission with static index buffer, indirect draw via `CompositorEffect`. Demo: a tentacle rigged to a bone that reacts to player position via an analytical capsule SDF. **This is the first vertical slice that matches the Returnal tentacle demo.**

**Phase 4 — Authoring layer (1–2 weeks).** Annotation preprocessor, schema, resource definition. `EditorInspectorPlugin` generating sliders/color/curve pickers from the shader. Hot reload from external editor. `UdonResourceRegistry` published and consumed by name. A second effect (bullet trail as a 2‑particle chain) to validate reuse.

**Phase 5 — Destructible (2 weeks).** Houdini `.fracture` asset importer. Shared vertex/index buffer with per‑piece range table. Particle‑per‑piece with indirect multi‑draw (or instanced‑by‑piece‑type bucket sort). Node‑particle grouping for clustered fracture. SDF collision against a stub baked environment SDF.

**Phase 6 — SDF + voxelizer (2–3 weeks).** Jump Flooding Algorithm for unsigned distance; sign via rasterization. Static mesh SDF baking (offline) with 3D texture import. Eisemann‑Décoret single‑pass voxelization of skeletal meshes — bit‑packed `R32_UINT` virtual 2D texture with 4×2 tile encoding 256 slices, resolved to 3D, published to the registry.

**Phase 7 — Marching cubes density volume (1–2 weeks).** Scan‑based MC on GPU; one thread per cell classifies, exclusive prefix sum, one thread per active cell emits triangles into a vertex SSBO; indirect draw. Particles splat density via atomic add into a float volume. Cavern‑sphere demo.

**Phase 8 — Fluid simulation (3–4 weeks).** Clipmap grid, semi‑Lagrangian advection, Jacobi pressure, vorticity confinement, two‑way particle coupling, obstacle SDF and skeletal voxel integration. Register in the resource registry. Wire existing tentacle shaders' optional `fluid_velocity` binding. Replace capsule‑only SDF reaction with real environment SDF.

**Phase 9 — Volumetric fog** and **vegetation** (open‑ended). Fog volumes as NGP effects sampling fluid density. Vegetation as instanced tubes/ribbons using the same tube renderer.

---

## 8. Godot‑specific workarounds and sharp edges

**Spatial shaders cannot bind SSBOs.** Every cross‑pipeline communication goes through `Texture2DRD`/`Texture3DRD`. For tube rendering we avoid this entirely by using our own custom pipeline (we *are* the spatial shader equivalent; we are not using `ShaderMaterial` on a `MeshInstance3D`). For point particles, pack attributes into RGBA16F `Texture2DRD` and sample by `INSTANCE_ID`.

**MultiMesh GPU‑write sync bug (#105113).** If we do fall back to MultiMesh for simple cases, we must trigger a CPU roundtrip `multimesh_get_buffer / multimesh_set_buffer` once after compute writes to force RenderingServer state refresh. Accept the perf hit or avoid the path entirely.

**No hot reload for `RDShaderFile` (#110468).** We implement our own: `FileAccess.get_modified_time` polled on `NOTIFICATION_APPLICATION_FOCUS_IN` and every ~500 ms, reading raw `.glsl` text, running our preprocessor, calling `shader_compile_spirv_from_source`. This gives better hot‑reload than Godot's built‑in system because we control the pipeline end‑to‑end.

**Skeletal voxelization requires watertight mesh.** Eisemann‑Décoret's XOR method fails on non‑manifold geometry. Fall back to Housemarque's bone‑extrusion trick: encode bone index in a spare vertex color channel; in the particle spawn shader, create particles along the vector from each vertex to its closest bone point. Preserves visual volume without requiring watertightness.

**Marching cubes on GPU.** Use the scan‑based path (classify → prefix sum → generate → indirect draw). HistoPyramid (Dyken/Ziegler 2008) is marginally faster at very high cell counts but adds pyramid construction and lookup complexity; not worth it under 128³. Surface Nets is a smoother alternative for blobby effects — swap in as a second MC variant if quality demands it.

**`call_on_render_thread` discipline.** Every RID lifecycle call, every compute/draw list recording, every `buffer_update` must run inside a `RenderingServer.call_on_render_thread` closure. GDScript wrappers around the C++ methods must wrap their implementations. Direct calls from the main thread will hit the "Storage buffer supplied invalid" error (#105100). Make this a code‑review rule from day one.

**Editor vs runtime separation.** The `UdonInspectorPlugin` and annotation parser live in an editor‑only registration level (`MODULE_INITIALIZATION_LEVEL_EDITOR`). The runtime particle system never links against editor code. Hot‑reload is editor‑only; runtime builds load pre‑compiled SPIR‑V from the cache directory shipped with the game.

**D3D12 on Windows 4.6 default.** Validation on both Vulkan and D3D12 backends is mandatory because push‑constant alignment rules differ and some barrier ordering is more strict. Prefer UBOs over push constants for anything larger than 64 bytes to stay portable.

**Godot `RDShaderFile` can't be parsed from GDExtension at runtime (#6691).** We sidestep by never using the `#[compute]` wrapper — our shaders are pure GLSL 450, fed through `RDShaderSource.source_compute` and `shader_compile_spirv_from_source`. Editor import bypassed entirely; our preprocessor is the source of truth.

---

## 9. Prior art and references

**Housemarque / Returnal (primary inspiration).**
- Jankkila, Jagadeesan, "RETURNAL VFX BREAKDOWN", Housemarque blog, 15 Sep 2021 — the authoritative public source, with references to Stam 1999 and Eisemann‑Décoret 2008.
- PlayStation.Blog companion article "From Resogun to Returnal", 16 Sep 2021.
- 80.lv article on the GDC 2022 talk, for the "text file with HLSL in it" quote on authoring.
- GDC 2022 Visual Effects Summit, "Can We Do It with Particles?" (GDC Vault 1027742, YouTube `qbkb8ap7vts`).
- Housemarque "The Art and Science of Explosions" (Aug 2021) — contextual info on Risto Jankkila's background and the Kaamos/NGP naming.

**GPU spatial hashing / neighbor queries.**
- Green, "Particle Simulation using CUDA", NVIDIA whitepaper.
- Hoetzlein, "Fast Fixed-Radius Nearest Neighbors", GTC 2014 S4117, and the Fluids v3 reference implementation.
- Teschner et al., "Optimized Spatial Hashing for Collision Detection of Deformable Objects", VMV 2003.
- Ihmsen et al., "A Parallel SPH Implementation on Multi-Core CPUs", CGF 2011.
- Macklin & Müller, "Position Based Fluids", TOG 2013.
- Müller, "Ten Minute Physics #11: Blazing Fast Neighbor Search".
- Raph Levien, "Prefix sum on Vulkan" (2020) and "Prefix sum on portable compute shaders" (2021).
- Wicked Engine, "GPU-based particle simulation" (append buffer emulation on Vulkan).

**Tube/ribbon rendering.**
- Bishop, "There is more than one way to frame a curve", Amer. Math. Monthly 82(3), 1975.
- Hanson & Ma, "Parallel Transport Approach to Curve Framing", Indiana TR425, 1995.
- Wang, Jüttler, Zheng, Liu, "Computation of Rotation Minimizing Frames", ACM ToG 27(1), 2008 — the double‑reflection algorithm; reference for higher‑order frames.
- Unreal CableComponent docs — the canonical CPU Verlet+Gram‑Schmidt tube.
- Unreal Niagara Ribbon renderer — the modern GPU analog.

**Fluid simulation.**
- Stam, "Stable Fluids", SIGGRAPH 1999.
- Stam, "Real-Time Fluid Dynamics for Games", GDC 2003.
- Harris, GPU Gems 1 Ch. 38, "Fast Fluid Dynamics Simulation on the GPU".
- Crane, Llamas, Tariq, GPU Gems 3 Ch. 30 (3D GPU fluid) — the basis for "Smoke in a Box".
- Bridson, "Fluid Simulation for Computer Graphics" (book).
- Aaltonen, "GPU‑Based Clay Simulation", GDC 2018 (Claybook).
- Unreal Niagara Fluids docs.
- Wronski, "Volumetric Fog", SIGGRAPH 2014 — froxel model used everywhere since.

**Marching cubes / voxelization / SDF.**
- Bourke tables for classic MC (`paulbourke.net/geometry/polygonise`).
- Dyken, Ziegler, Theobalt, Seidel, "High-speed Marching Cubes using Histogram Pyramids", CGF 2008.
- NVIDIA GPU Gems 3 Ch. 1 — procedural terrain MC.
- Lengyel, Transvoxel (LOD stitching).
- Eisemann & Décoret, "Single-Pass GPU Solid Voxelization", GI 2008 — Housemarque's explicit reference.
- Rong & Tan, Jump Flooding Algorithm, i3D 2006; RTSDF (2020+) for real‑time 3D SDF.
- Barill et al., "Fast Winding Numbers", SIGGRAPH 2018.
- Unreal Mesh Distance Fields and Global Distance Field docs.

**Destruction.**
- NVIDIA Blast (`github.com/NVIDIAGameWorks/Blast`) — support graph + stress solver pattern.
- Chaos Destruction (UE5) — clustering and runtime fracture.
- Houdini Voronoi Fracture / RBD Material Fracture.
- Houdini → Chaos integration docs (piece_id export schema).

**Engine authoring models to study.**
- Unreal Niagara CustomHLSL and module parameter exposure.
- Unity VFX Graph and ShaderLab Properties syntax.
- Media Molecule Dreams' splat/wire system (Alex Evans, Umbra Ignite 2015).

---

## 10. Conclusion — what's novel, what's derivative, what to do Monday

Nothing in this design is individually new: counting‑sort grids are twelve years old, Catmull‑Rom tube rendering is textbook, Stable Fluids is from 1999, Eisemann‑Décoret is from 2008. **The novelty is in the Godot 4.6 stack adaptation and the architectural coupling via the resource registry**, which together let a small team replicate NGP's expressive power without writing a proprietary engine.

Three convictions to carry into implementation:

- **The resource registry is the most important abstraction in this document.** It is what lets tentacles ship in Phase 3 and fluid sim ship in Phase 8 without rewriting tentacles. Name‑based, type‑checked, optional — get this right first.
- **Indirect draw into a compute‑written vertex buffer is non‑negotiable.** MultiMesh is a detour. Godot 4.6 gives us the exact Vulkan primitive we need; the only complexity is the `CompositorEffect` plumbing, and that is one file.
- **Shader is source of truth; UI is reflection.** Don't build a visual node editor in Phase 1. Don't even build a parser in Phase 1. Ship Phase 1–3 with plain `@export` dictionaries, add the annotation preprocessor in Phase 4, and keep the visual graph as a Phase ∞ dream. NGP's productivity comes from the compute‑shader‑is‑the‑effect model, not from the UI polish — replicate the model, not the chrome.

Monday's first commit should be Phase 0: a `UdonParticleSystem` Node3D that, inside a `call_on_render_thread` closure, creates a storage buffer, dispatches a one‑pass compute shader that writes a test pattern, exposes it as a `Texture2DRD`, and displays it on a quad. Everything else in this document is elaboration on that thirty‑line prototype.
