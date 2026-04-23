# CLAUDE.md — Tenticle

Custom GPU particle system for Godot 4.6+. GDExtension C++ core, GLSL 450 compute shaders,
inspired by Housemarque's NGP (Returnal). See `docs/design.md` for full architecture.

## Paths

- `../godot-cpp/` — pre-compiled godot-cpp bindings. Do not rebuild. Link against it.
- `../../docs/` — general Godot reference material. Check here BEFORE searching the web
  for Godot API questions.
- `shaders/` — authored GLSL 450. Pure GLSL, NOT Godot's `#[compute]` wrapper format.
- `effects/*.udon.glsl` — artist-authored particle effects with `@param`/`@resource` annotations.
- `src/` — GDExtension C++ source. See `docs/design.md` §7.1 for module layout.

## Non-negotiable rules

### Rendering path
- Primary path is **`RenderingDevice.draw_list_draw_indirect`** against a compute-written
  vertex buffer, composited via `CompositorEffect`. NOT MultiMesh, NOT GPUParticles3D.
- MultiMesh is a secondary path for transform-only effects and has a known sync bug
  (godot issue #105113) requiring CPU roundtrip to work reliably. Avoid unless necessary.
- Spatial shaders CANNOT bind SSBOs in Godot 4.6. Bridge compute → spatial via
  `Texture2DRD`/`Texture3DRD`. This is not negotiable; do not attempt workarounds.

### Render thread discipline
- EVERY RID lifecycle call, compute/draw list recording, and `buffer_update` MUST run
  inside a `RenderingServer.call_on_render_thread(Callable)` closure.
- Direct calls from the main thread produce "Storage buffer supplied invalid" errors.
- If a GDScript wrapper exists, its C++ implementation is still responsible for the
  render-thread hop. Do not push this responsibility to callers.

### Shader authoring
- Shaders are pure GLSL 450 fed to `RDShaderSource.source_compute` and compiled via
  `shader_compile_spirv_from_source`. Do NOT use Godot's `#[compute] #version` wrapper
  or `RDShaderFile`.
- The annotation preprocessor (`UdonShaderPreprocessor`) is the source of truth for
  `@param`, `@curve`, `@texture`, `@resource` declarations. Editor UI and uniform sets
  are derived from it.
- `std430` layout: `vec3` is padded to 16 bytes. Always pack as `vec4` with w carrying
  scalar data, OR declare `float foo[3]`. Never write a bare `vec3` in a storage struct.

### Resource coupling
- Cross-module communication goes through `UdonResourceRegistry` (name → RID).
- Modules publish by name, particles consume by name via `@resource` annotations.
- Optional resources (`optional=true`) compile with `#ifdef HAS_RES_<name>` stubs when
  absent. This is how fluid sim can ship after tentacles without touching tentacle code.
- Never add a direct C++ dependency between particle system and fluid/SDF/voxelizer modules.

### Editor vs runtime
- Editor-only code (inspector plugins, annotation parser UI, hot-reload) registers at
  `MODULE_INITIALIZATION_LEVEL_EDITOR`. Runtime code never links against it.
- Hot-reload is editor-only. Shipped builds load pre-compiled SPIR-V from cache.

## Godot 4.6 API verification

Always verify against current docs before citing specific signatures. Order of preference:
1. `../../docs/` — local reference
2. `docs.godotengine.org/en/stable/` and `/en/4.6/` — official
3. `github.com/godotengine/godot` at the 4.6 tag — source of truth

Known-present in 4.6 (per design doc §3.1):
- `compute_list_dispatch_indirect`, `draw_list_draw_indirect`
- `Texture2DRD`/`Texture3DRD`, `RenderingServer.call_on_render_thread`
- `multimesh_get_buffer_rd_rid`, `CompositorEffect`/`Compositor`
- `shader_compile_spirv_from_source`, `EditorInspectorPlugin` from GDExtension

Known-absent in 4.6 (workarounds in design doc §8):
- SSBO binding in spatial shaders
- `multimesh_set_buffer_rd` (write-side RD setter)
- Mesh shader exposure (`VK_EXT_mesh_shader`)
- Reliable `RDShaderFile` hot-reload

Verify against your exact 4.6 tag before coding:
- `draw_list_begin` parameter list (changed in 4.6 per third-party summaries)
- Shader Baker interaction with `RDShaderFile`
- D3D12 behavior (4.6 default on Windows) — test push constants and barriers on both backends

## Build

- `scons platform=<linuxbsd|windows|macos> target=template_debug` (or `template_release`)
- Links against pre-compiled `../godot-cpp/`. Do not modify godot-cpp.
- Extension manifest is `udon.gdextension`. Entry point is `src/register_types.cpp`.

## Code style

- GDExtension C++ for performance-critical and RID-owning code.
- GDScript only for gameplay glue and demo scenes.
- RID ownership: the object that creates an RID is responsible for freeing it in its
  destructor/`_exit_tree`. Never transfer RID ownership across class boundaries; pass
  by reference and let the owner free.
- No `GDCLASS` boilerplate in headers that don't need it. Anything Node/Resource-derived
  that's exposed to the editor needs `GDCLASS` and `_bind_methods`.
- Log via `udon::log` wrapper, not `UtilityFunctions::print` directly — gives us a
  category/severity filter.

## What NOT to do

- Do not suggest `GPUParticles3D`, `ParticleProcessMaterial`, or `CPUParticles3D`
  extensions. This project exists because those are insufficient.
- Do not suggest Godot 3.x patterns (`VisualServer`, old shader syntax, etc.).
- Do not rely on `MeshDataTool` for anything per-frame. Direct `surface_get_arrays` /
  `add_surface_from_arrays` on `ArrayMesh` is faster; compute-written vertex buffers
  are faster still and are what we use.
- Do not create materials per-particle on the CPU each frame. All per-instance data
  lives in storage buffers or RD textures.
- Do not use nested Resources where a Node would work. Per project convention, configure
  in the inspector via Nodes (see project-level Godot rules).

## When something's unclear

- Architectural questions → `docs/design.md`
- Housemarque technique questions → design doc §1 and cited Housemarque blog
- Godot API questions → `../../docs/` first, then docs.godotengine.org
- Don't guess at Godot API signatures. Verify or ask.
