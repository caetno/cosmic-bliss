# Engine Constraints

## Hardware target

**GTX 970 / 4 GB VRAM.** The realism budget is shaped by this:

- **Fragment-shader work is expensive.** Don't spend the budget on full-screen post effects, screen-space subsurface scattering, volumetric fog, parallax-occluded suckers, etc. Subsurface is approximated with cheaper material settings; lighting is forward-plus with care.
- **VRAM is small.** Texture atlases + careful re-use; don't ship multi-megabyte normal maps per minor asset. Decal accumulator is a single body-space target.
- **GPU compute is not free.** Going GPU for PBD would tax CPU↔GPU sync; not worth it at our particle count.

Realism comes from CPU physics + clever vertex-shader deformation. If a realism idea requires a fragment-stage technique, push back on it before agreeing — usually there's a physics or vertex-shader path that lands the same thing more cheaply.

## Engine: Godot 4.6

godot-cpp tracks `master` (4.6 branch not yet published). The submodule is pinned to a specific commit; do not run `git submodule update --remote` without intent — master moves and can silently break the build.

When godot-cpp publishes a `4.6` branch:
```
git submodule set-branch -b 4.6 godot-cpp
cd godot-cpp && git fetch && git checkout 4.6 && git pull
```

## Performance non-negotiables

Project-wide rules in `CLAUDE.md`:

- **No `MeshDataTool` in hot paths.**
- **No per-frame `ArrayMesh` rebuilds.** Vertex shader deformation only.
- **No per-frame `ShaderMaterial` allocation.** One per instance, mutate uniforms.
- **Each tentacle gets a unique `ShaderMaterial`**; the `.gdshader` file is shared.
- **RGBA32F data textures** for spline data — SSBOs are not available in spatial shaders in Godot 4.6.
- **Don't query `PhysicalBone3D.global_transform` during PBD iterations.** Snapshot once per tick.
- **Don't use `SoftBody3D`.** Unsuitable for what we need.
- **Don't use `MultiMesh`** for tentacle instancing (each needs a unique deforming mesh).

## Engine quirks (the user has hit these)

These live in the user's portable Godot gotchas doc; relevant here as "things to know when reasoning":

- **`SoftBody3D` unsuitable** — known limitations; don't suggest it as a solution.
- **`MultiMesh` sync bug #105113** — affects per-instance updates; avoid when each instance needs unique state.
- **Editor gizmo redraw stutter #71979** — `EditorNode3DGizmoPlugin._redraw` drops frames during continuous input. Visibility-flicker coalesced per-frame is a partial fix; `Skeleton3DEditor` uses a custom `ImmediateMesh` for similar reasons.
- **`PhysicalBone3D` Jolt unit quirk** — `6DOF angular_limit` property hint says `radians_as_degrees`, but the Jolt path consumes the stored number AS DEGREES at runtime. Easy to be off by 57×.
- **Jolt HINGE X-axis sign flip** — joint orientation conventions differ from default.
- **`AABB(position, size)` not `AABB(min, max)`** — common mistake.
- **`PrimitiveMesh` `custom_aabb`** required when the procedural mesh extends past the inferred AABB — culling otherwise hides the mesh.
- **Godot import dialog requires Reimport** — subresource assignments live in memory only until clicked.
- **`BoneMap` property serialization key is `bone_map/`** with underscore.
- **`.so` doesn't hot-reload** — full editor restart needed after any GDExtension rebuild.
- **GDScript class cache must refresh** with `--editor --quit` after adding any new `class_name`, otherwise tests using the new class fail at parse time.
- **GDScript `--script` mode parse-time fails on GDExtension classes** — registration runs at `MODULE_INITIALIZATION_LEVEL_SCENE`, after the parser. Tests use `ClassDB.instantiate("ClassName")` instead of `ClassName.new()`.
- **Eager `static var = build()` lazy-init bug in `@tool`** — eager static var can run before class_name dependencies resolve. Use `_ensure_x()` lazy pattern.
- **`top_level=true` after tree entry** doesn't take effect — set before `_ready` (in `_init`).
- **Property setters before tree entry** can run on partially-initialized objects.
- **`ImmediateMesh` empty-surface error** — calling `surface_end()` on a surface with zero vertices throws; defer `surface_begin` until the first vertex is ready.
- **`Basis.get_column()` GDScript-vs-C++** — column index conventions differ between the script and native API.

## Physics backend

**Jolt** is the active physics backend (replacing Godot Physics 3D). Used for ragdoll bones via `PhysicalBone3D`.

PBD is **separate from Jolt** — TentacleTech runs its own integrator on its own particles, then routes reciprocal impulses to Jolt-managed bodies via `PhysicsServer3D::body_apply_impulse`. The two simulation domains communicate per-tick through that impulse path + the per-particle sphere queries the probe issues.

The PBD↔Jolt coupling is currently the active design problem (see `08_current_state.md`). Substep coordination between the two is on the table.

## C++ / GDScript split

C++ (in `extensions/<name>/src/`) for:
- Code that runs at physics-tick rate (60+ Hz) with nontrivial cost
- Math-heavy inner loops (PBD iterations, collision, spline)
- Direct `RenderingDevice` interaction

GDScript (in `extensions/<name>/gdscript/`, deployed to `game/addons/<name>/scripts/`) for:
- Behaviour drivers, AI, scenarios
- Authoring helpers, gizmos, editor tooling
- Stimulus consumption, control plumbing
- Procedural mesh generation (TentacleMesh)
- Anything that doesn't profile as hot

The compile-edit cycle is real cost. The C++ surface stays small.

## Build

```
cd extensions/<extension>
scons -j$(nproc) target=template_debug
```

Output: `game/addons/<extension>/bin/lib<extension>.<platform>.<target>.<arch>.<ext>`. GDScript and shaders are copied alongside by `tools/build.sh <extension>` (the convenience wrapper). `tools/build_all.sh` builds all extensions.

## Testing

Headless tests: `godot --path game --headless --script res://tests/<extension>/test_<name>.gd`. Pattern: `extends SceneTree`, assertions in `_init()` or deferred to `_process()`, `quit(0)` on pass / `quit(2)` on fail. No gdUnit4 dependency.
