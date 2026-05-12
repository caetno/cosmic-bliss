# Flesh Deformer — Godot 4 Implementation Plan v2

**Purpose:** A Godot 4 compute-shader system that simulates flesh deformation
on skinned characters using GPU-resident XPBD on a tetrahedral proxy mesh.
Bone colliders drive kinematic classification. Free tet vertices simulate
elastic flesh. Surface deformation is transferred to the render mesh via
precomputed barycentric weights loaded from a `.bin` file produced by the
Blender addon.

---

## Scope

- **Single mesh** (one MeshInstance3D, one `.bin` file, one simulation)
- **Single region** (whole body tet mesh)
- **Coordinates are pre-converted** — the `.bin` file contains Godot Y-up positions
- **Kinematic classification is static** (computed once at load from rest pose)
- **Rigidity is computed at runtime** from bone collider distance (not baked)

---

## References

| Topic | URL |
|---|---|
| XPBD (Macklin et al. 2016) | https://matthias-research.github.io/pages/publications/XPBD.pdf |
| Stable Neo-Hookean (Smith 2018) | https://graphics.pixar.com/library/StableElasticity/paper.pdf |
| IQ Analytic SDF Primitives | https://iquilezles.org/articles/distfunctions/ |
| Godot RenderingDevice | https://docs.godotengine.org/en/stable/tutorials/shaders/compute_shaders.html |
| Godot Skeleton3D | https://docs.godotengine.org/en/stable/classes/class_skeleton3d.html |
| Godot PhysicalBoneSimulator3D | https://docs.godotengine.org/en/stable/classes/class_physicalbonessimulator3d.html |

---

## System Overview

```
SCENE HIERARCHY:
  CharacterRoot
  ├── Skeleton3D
  ├── MeshInstance3D                    ← render mesh
  ├── PhysicalBoneSimulator3D
  │   ├── PhysicalBone3D (hips)
  │   │   └── CollisionShape3D         ← SDF source
  │   ├── PhysicalBone3D (spine)
  │   │   └── CollisionShape3D
  │   └── ...
  └── FleshDeformer                    ← THIS SYSTEM
      (autodetects siblings)
```

```
DATA FLOW (per frame):

  Skeleton3D poses → bone transform buffer
  PhysicalBone3D transforms → collider buffer
                        ↓
  ┌─ GPU Compute ─────────────────────────────────────────────────┐
  │                                                                │
  │  Pass 1: Kinematic Targets                                     │
  │    bone_transforms × rest_pos → kinematic_target_buf (all)     │
  │    bone_transforms × rest_pos → tet_pos_buf (kinematic only)   │
  │                                                                │
  │  ── barrier ──                                                 │
  │                                                                │
  │  Pass 2: XPBD Solver (N substeps)                              │
  │    integrate        ── barrier ──                               │
  │    elasticity (per color group)  ── barrier ──                  │
  │    volume           ── barrier ──                               │
  │    kinematic pin    ── barrier ──                               │
  │    SDF collision    ── barrier ──                               │
  │    LRA tether       ── barrier ──                               │
  │    velocity update  ── barrier ──                               │
  │                                                                │
  │  Pass 3: Surface Transfer                                      │
  │    delta = sim_pos − kinematic_target (via barycentrics)       │
  │    delta *= render_influence                                    │
  │    → render_delta_buf                                          │
  │                                                                │
  └────────────────────────────────────────────────────────────────┘
                        ↓
  Delta applied to skinned mesh (CompositorEffect or texture sample)
```

---

## .bin File Format (read by this system)

Version 2, little-endian. Produced by the Blender addon.
Coordinates are already in Godot Y-up world space — **no axis conversion needed**.

```
[Magic: 'FLSH'] [Version: uint32 = 2]
[name_len: uint32] [mesh_name: utf8]
[n_tet_verts: uint32 Nv] [n_tet_cells: uint32 Nt] [n_render_verts: uint32 Nr]
[tet_verts:         float32 Nv×3]   — rest-pose positions (Godot space)
[tet_cells:         int32   Nt×4]   — 4 vertex indices per tet
[bary_tet_idx:      int32   Nr]     — which tet contains each render vert
[bary_uvw:          float32 Nr×3]   — (u, v, w) barycentric coords
[render_influence:  float32 Nr]     — 0=bone-only, 1=full sim
```

---

## Key Design Decisions

### Rigidity is computed at runtime, not baked

The `.bin` file contains no `tet_rigidity` field. Instead, rigidity is computed
once at `_ready()` in Godot:

1. **Classify kinematic verts:** For each tet vertex, evaluate all bone SDF
   colliders at rest pose. If the vertex is inside or within `skin_offset`
   of any collider → kinematic (assigned to that bone).

2. **Compute rigidity by distance:** BFS/flood-fill outward from kinematic
   verts through the tet connectivity graph. Each tet vertex gets a rigidity
   value that ramps from 0.0 (at kinematic boundary) to the region's
   configured stiffness (at maximum depth). The blend falloff curve and
   radius are exposed as FleshDeformer parameters.

This means the artist never paints internal tet properties. They paint
`flesh_influence` on the visible skin surface (in Blender), and tune
rigidity via numeric parameters in Godot.

### Delta = sim − kinematic target (not sim − rest)

The surface transfer shader computes the per-render-vertex delta as
`sim_pos − kinematic_target_pos`. This ensures the delta is exactly zero
for perfectly bone-tracked vertices, eliminating float-path divergence
between the XPBD bone multiply and Godot's internal LBS skinning.

### render_influence scales the final delta

After barycentric interpolation produces a delta vector, it is multiplied
by `render_influence[vid]` before being applied. This is the artist's
per-vertex control over "how much jiggle reaches the surface."

---

## SDF Collider System

### Collider Types

```
Type 0 — Analytic Primitive (sphere, capsule, box)       IMPLEMENTED
Type 1 — Convex Hull (half-space intersection)            IMPLEMENTED
Type 2 — Reserved (voxel SDF)                             FUTURE
Type 3 — Reserved (ONNX neural SDF)                       FUTURE
```

### GPU Collider Struct

Uses explicit vector types to avoid std430 array-of-scalar alignment traps.

```glsl
struct BoneCollider {
    mat4  inv_transform;    // 64 bytes — world → local
    int   shape_type;       //  4 bytes — 0/1/2/3
    int   bone_index;       //  4 bytes
    // 8 bytes implicit padding (vec4 alignment)
    vec4  params_a;         // 16 bytes — shape params [0..3]
    vec2  params_b;         //  8 bytes — shape params [4..5]
    int   _pad[2];          //  8 bytes
};  // Total: 112 bytes

float get_param(BoneCollider c, int i) {
    return (i < 4) ? c.params_a[i] : c.params_b[i - 4];
}
```

Params layout per type:

```
Type 0 (primitive):
  [0] radius
  [1] half_height  ← capsule: (total_height/2 - radius), NOT total/2
  [2] half_x       ← box
  [3] half_y
  [4] half_z
  [5] prim_type    ← 0=sphere, 1=capsule, 2=box

Type 1 (convex):
  [0] face_pool_offset
  [1] face_count
  [2..5] unused
```

### SDF Evaluation

```glsl
float eval_sdf(vec3 world_pos, int ci) {
    BoneCollider c = colliders[ci];
    vec3 lp = (c.inv_transform * vec4(world_pos, 1.0)).xyz;

    if (c.shape_type == 0) {
        int prim = int(get_param(c, 5));
        if (prim == 0) return length(lp) - get_param(c, 0);           // sphere
        if (prim == 1) {                                                // capsule
            float r = get_param(c, 0), h = get_param(c, 1);
            vec2 q = vec2(length(lp.xz), abs(lp.y) - h);
            return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
        }
        if (prim == 2) {                                                // box
            vec3 he = vec3(get_param(c,2), get_param(c,3), get_param(c,4));
            vec3 q = abs(lp) - he;
            return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
        }
    }
    if (c.shape_type == 1) {
        int off = int(get_param(c, 0)), cnt = int(get_param(c, 1));
        float d = -1e10;
        for (int i = 0; i < cnt; i++) {
            vec4 pl = convex_faces[off + i];
            d = max(d, dot(pl.xyz, lp) - pl.w);
        }
        return d;
    }
    return 1e10;
}
```

### SDF Gradients

Analytic for primitives (sphere, capsule, box). Finite-difference fallback
for convex and future types. See v1 plan for full implementation — the
analytic gradient functions are unchanged.

---

## FleshData Resource

### `flesh_data.gd`

Loads and holds the parsed `.bin` data. Pure data container, no GPU state.

```gdscript
class_name FleshData
extends Resource

var mesh_name:        String
var n_tet_verts:      int
var n_tet_cells:      int
var n_render_verts:   int

var tet_verts:        PackedFloat32Array   # Nv × 3
var tet_cells:        PackedInt32Array     # Nt × 4
var bary_tet_idx:     PackedInt32Array     # Nr
var bary_uvw:         PackedFloat32Array   # Nr × 3
var render_influence: PackedFloat32Array   # Nr

static func load_bin(path: String) -> FleshData:
    var f = FileAccess.open(path, FileAccess.READ)
    if not f:
        push_error("FleshData: cannot open %s" % path)
        return null

    var magic = f.get_buffer(4)
    if magic != PackedByteArray([0x46, 0x4C, 0x53, 0x48]):
        push_error("FleshData: bad magic in %s" % path)
        return null

    var version = f.get_32()
    if version != 2:
        push_error("FleshData: unsupported version %d" % version)
        return null

    var d = FleshData.new()
    var name_len  = f.get_32()
    d.mesh_name   = f.get_buffer(name_len).get_string_from_utf8()
    d.n_tet_verts = f.get_32()
    d.n_tet_cells = f.get_32()
    d.n_render_verts = f.get_32()

    d.tet_verts        = _read_f32(f, d.n_tet_verts * 3)
    d.tet_cells        = _read_i32(f, d.n_tet_cells * 4)
    d.bary_tet_idx     = _read_i32(f, d.n_render_verts)
    d.bary_uvw         = _read_f32(f, d.n_render_verts * 3)
    d.render_influence = _read_f32(f, d.n_render_verts)

    f.close()
    return d

static func _read_f32(f: FileAccess, count: int) -> PackedFloat32Array:
    var bytes = f.get_buffer(count * 4)
    var arr = PackedFloat32Array()
    arr.resize(count)
    for i in range(count):
        arr[i] = bytes.decode_float(i * 4)
    return arr

static func _read_i32(f: FileAccess, count: int) -> PackedInt32Array:
    var bytes = f.get_buffer(count * 4)
    var arr = PackedInt32Array()
    arr.resize(count)
    for i in range(count):
        arr[i] = bytes.decode_s32(i * 4)
    return arr
```

---

## BoneCollider Classes

### `bone_sdf_collider.gd`

```gdscript
class_name BoneSdfCollider
extends RefCounted

const TYPE_PRIMITIVE := 0
const TYPE_CONVEX    := 1

var bone_name:       String
var bone_index:      int
var sdf_type:        int
var local_transform: Transform3D

func fill_gpu_params() -> PackedFloat32Array:
    return PackedFloat32Array([0,0,0,0,0,0])
```

### `bone_sdf_primitive.gd`

```gdscript
class_name BoneSdfPrimitive
extends BoneSdfCollider

const PRIM_SPHERE  := 0
const PRIM_CAPSULE := 1
const PRIM_BOX     := 2

var prim_type:    int
var radius:       float
var half_height:  float     # capsule: (total_height/2 - radius)
var half_extents: Vector3

func _init():
    sdf_type = TYPE_PRIMITIVE

func fill_gpu_params() -> PackedFloat32Array:
    return PackedFloat32Array([
        radius, half_height,
        half_extents.x, half_extents.y, half_extents.z,
        float(prim_type)
    ])

static func from_shape(node: CollisionShape3D, bname: String, bidx: int) -> BoneSdfPrimitive:
    var c = BoneSdfPrimitive.new()
    c.bone_name = bname
    c.bone_index = bidx
    c.local_transform = node.transform
    var s = node.shape
    if s is SphereShape3D:
        c.prim_type = PRIM_SPHERE
        c.radius = s.radius
    elif s is CapsuleShape3D:
        c.prim_type = PRIM_CAPSULE
        c.radius = s.radius
        c.half_height = (s.height * 0.5) - s.radius   # line-segment half-length
    elif s is BoxShape3D:
        c.prim_type = PRIM_BOX
        c.half_extents = s.size * 0.5
    else:
        return null
    return c
```

### `bone_sdf_convex.gd`

```gdscript
class_name BoneSdfConvex
extends BoneSdfCollider

var face_planes:      PackedFloat32Array   # [nx,ny,nz,d, ...]
var face_count:       int
var face_pool_offset: int                  # set by FleshDeformer

func _init():
    sdf_type = TYPE_CONVEX

func fill_gpu_params() -> PackedFloat32Array:
    return PackedFloat32Array([
        float(face_pool_offset), float(face_count),
        0.0, 0.0, 0.0, 0.0
    ])

static func from_shape(node: CollisionShape3D, bname: String, bidx: int) -> BoneSdfConvex:
    var s = node.shape
    if not s is ConvexPolygonShape3D:
        return null
    var c = BoneSdfConvex.new()
    c.bone_name = bname
    c.bone_index = bidx
    c.local_transform = node.transform
    c.face_planes = _extract_faces(s)
    c.face_count = c.face_planes.size() / 4
    return c

static func _extract_faces(shape: ConvexPolygonShape3D) -> PackedFloat32Array:
    # Brute-force O(n^4) hull face extraction — acceptable for <50 point colliders.
    # For larger hulls, use ArrayMesh + SurfaceTool via engine's Quickhull.
    var planes = PackedFloat32Array()
    var points = shape.points
    if points.is_empty(): return planes

    var added = []
    for i in range(points.size()):
        for j in range(i+1, points.size()):
            for k in range(j+1, points.size()):
                var a = points[i]; var b = points[j]; var cp = points[k]
                var n = (b - a).cross(cp - a).normalized()
                if n.length_squared() < 0.0001: continue
                var d = n.dot(a)

                var ok = true
                for p in points:
                    if n.dot(p) - d > 0.001: ok = false; break
                if not ok:
                    n = -n; d = -d; ok = true
                    for p in points:
                        if n.dot(p) - d > 0.001: ok = false; break

                if ok:
                    var dup = false
                    for prev in added:
                        if abs(prev[0]-n.x)<0.001 and abs(prev[1]-n.y)<0.001 and abs(prev[2]-n.z)<0.001:
                            dup = true; break
                    if not dup:
                        added.append([n.x, n.y, n.z, d])
                        planes.append(n.x); planes.append(n.y)
                        planes.append(n.z); planes.append(d)
    return planes
```

---

## FleshDeformer Node

### `flesh_deformer.gd`

```gdscript
class_name FleshDeformer
extends Node

## ── EXPORTS ──────────────────────────────────────────────────────────

@export var flesh_data_path: String = ""   ## Path to .bin file

@export_group("Simulation")
@export var num_substeps:     int   = 4
@export var stiffness:        float = 5000.0
@export var damping:          float = 0.02
@export var gravity:          Vector3 = Vector3(0, -9.8, 0)
@export var skin_sdf_offset:  float = 0.002

@export_group("Rigidity")
@export var rigidity_blend_radius: float = 0.15
## Distance (in world units) over which rigidity ramps from 0 (kinematic)
## to 1 (fully free). Larger values = softer transition, more mush near bones.
## Smaller values = stiffer near bones, jiggle starts further from skeleton.

@export_enum("Linear", "Quadratic", "Smooth") var rigidity_falloff: int = 2
## 0 = linear ramp, 1 = quadratic (faster falloff), 2 = smoothstep

## ── AUTODETECTED ─────────────────────────────────────────────────────

var skeleton:   Skeleton3D
var mesh_inst:  MeshInstance3D
var simulator:  PhysicalBoneSimulator3D

## ── DATA ─────────────────────────────────────────────────────────────

var flesh_data:     FleshData
var bone_colliders: Array[BoneSdfCollider]
var _bone_cache:    Dictionary = {}   # bone_name → PhysicalBone3D

## ── COMPUTED AT LOAD ─────────────────────────────────────────────────

var tet_bone_assignment: PackedInt32Array   # per tet vert: bone_idx or -1
var tet_rigidity:        PackedFloat32Array # per tet vert: 0..1

## ── GPU ──────────────────────────────────────────────────────────────

var rd: RenderingDevice

# Simulation buffers
var tet_pos_buf:             RID
var tet_vel_buf:             RID
var tet_prev_pos_buf:        RID
var tet_rest_buf:            RID   # static
var tet_cells_buf:           RID   # static
var inv_rest_dm_buf:         RID   # static
var rest_vol_buf:            RID   # static
var bone_assign_buf:         RID   # static
var rigidity_buf:            RID   # static
var kinematic_target_buf:    RID

# Barycentric / output
var bary_tet_idx_buf:        RID   # static
var bary_uvw_buf:            RID   # static
var render_influence_buf:    RID   # static
var render_delta_buf:        RID   # output

# Shared
var bone_transforms_buf:     RID
var collider_data_buf:       RID
var convex_faces_buf:        RID

# Color groups
var color_groups_buf:        RID   # static
var color_offsets_buf:       RID   # static
var n_colors:                int

# Shader RIDs
var shader_kinematic:        RID
var shader_integrate:        RID
var shader_elasticity:       RID
var shader_volume:           RID
var shader_kinematic_pin:    RID
var shader_sdf_collision:    RID
var shader_lra_tether:       RID
var shader_vel_update:       RID
var shader_surface_xfer:     RID

# Counts
var Nv: int   # tet verts
var Nt: int   # tet cells
var Nr: int   # render verts

## ── LIFECYCLE ────────────────────────────────────────────────────────

func _ready():
    rd = RenderingServer.get_rendering_device()

    _autodetect_nodes()
    _cache_bone_nodes()
    _load_flesh_data()
    _build_bone_colliders()
    _classify_kinematic_verts()     # uses bone colliders at rest pose
    _compute_rigidity_from_depth()  # BFS from kinematic verts
    _build_color_groups()
    _compile_shaders()
    _allocate_gpu_buffers()
    _upload_static_data()

func _physics_process(delta: float):
    if not flesh_data: return

    _upload_bone_transforms()
    _upload_collider_transforms()

    _dispatch_kinematic_pass()
    rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE)

    var sub_dt = delta / float(num_substeps)
    for _s in range(num_substeps):
        _dispatch_integrate(sub_dt)
        rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE)

        _dispatch_elasticity_and_volume()
        # barriers between color groups inside ^^

        _dispatch_kinematic_pin()
        rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE)

        _dispatch_sdf_collision()
        rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE)

        _dispatch_lra_tether()
        rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE)

        _dispatch_velocity_update(sub_dt)
        rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE)

    _dispatch_surface_transfer()

## ── NODE DETECTION ───────────────────────────────────────────────────

func _autodetect_nodes():
    for child in get_parent().get_children():
        if child is Skeleton3D and not skeleton:     skeleton = child
        elif child is MeshInstance3D and not mesh_inst: mesh_inst = child
        elif child is PhysicalBoneSimulator3D and not simulator: simulator = child
    if not skeleton:  push_error("FleshDeformer: no Skeleton3D sibling")
    if not mesh_inst: push_error("FleshDeformer: no MeshInstance3D sibling")

func _cache_bone_nodes():
    if not simulator: return
    for child in simulator.get_children():
        if child is PhysicalBone3D:
            _bone_cache[child.bone_name] = child

## ── DATA LOADING ─────────────────────────────────────────────────────

func _load_flesh_data():
    if flesh_data_path.is_empty():
        push_error("FleshDeformer: flesh_data_path not set")
        return
    flesh_data = FleshData.load_bin(flesh_data_path)
    if flesh_data:
        Nv = flesh_data.n_tet_verts
        Nt = flesh_data.n_tet_cells
        Nr = flesh_data.n_render_verts
        print("FleshDeformer: loaded %d tet verts, %d tets, %d render verts" %
              [Nv, Nt, Nr])

## ── BONE COLLIDER BUILDING ───────────────────────────────────────────

func _build_bone_colliders():
    if not simulator: return
    bone_colliders.clear()
    var convex_pool = PackedFloat32Array()

    for child in simulator.get_children():
        if not child is PhysicalBone3D: continue
        var bone := child as PhysicalBone3D
        var bidx = skeleton.find_bone(bone.bone_name) if skeleton else -1

        for sc in bone.get_children():
            if not sc is CollisionShape3D: continue
            var sn := sc as CollisionShape3D
            if not sn.shape: continue
            var coll: BoneSdfCollider = null

            if sn.shape is SphereShape3D or sn.shape is CapsuleShape3D or sn.shape is BoxShape3D:
                coll = BoneSdfPrimitive.from_shape(sn, bone.bone_name, bidx)
            elif sn.shape is ConvexPolygonShape3D:
                var cv = BoneSdfConvex.from_shape(sn, bone.bone_name, bidx)
                if cv:
                    cv.face_pool_offset = convex_pool.size() / 4
                    convex_pool.append_array(cv.face_planes)
                    coll = cv

            if coll: bone_colliders.append(coll)

    _convex_pool = convex_pool
    print("FleshDeformer: %d bone colliders" % bone_colliders.size())

var _convex_pool: PackedFloat32Array

## ── KINEMATIC CLASSIFICATION ─────────────────────────────────────────

func _classify_kinematic_verts():
    ## Evaluate each tet vertex against all bone colliders at rest pose.
    ## Inside or within skin_sdf_offset → kinematic (assigned to that bone).
    ## Coordinates are already in Godot world space (baked by Blender addon).
    tet_bone_assignment = PackedInt32Array()
    tet_bone_assignment.resize(Nv)
    tet_bone_assignment.fill(-1)

    for vi in range(Nv):
        var pos = Vector3(
            flesh_data.tet_verts[vi*3],
            flesh_data.tet_verts[vi*3+1],
            flesh_data.tet_verts[vi*3+2]
        )

        for ci in range(bone_colliders.size()):
            var coll = bone_colliders[ci]
            var bone_rest = _get_bone_rest_world(coll.bone_name)
            var shape_world = bone_rest * coll.local_transform
            var local_pos = shape_world.affine_inverse() * pos
            var d = _eval_sdf_cpu(coll, local_pos)

            if d < skin_sdf_offset:
                tet_bone_assignment[vi] = coll.bone_index
                break

    var n_kin = 0
    for v in tet_bone_assignment:
        if v >= 0: n_kin += 1
    print("FleshDeformer: %d kinematic, %d free tet verts" % [n_kin, Nv - n_kin])

func _get_bone_rest_world(bname: String) -> Transform3D:
    if not skeleton: return Transform3D.IDENTITY
    var bi = skeleton.find_bone(bname)
    if bi < 0: return Transform3D.IDENTITY
    return skeleton.global_transform * skeleton.get_bone_global_rest(bi)

func _eval_sdf_cpu(coll: BoneSdfCollider, lp: Vector3) -> float:
    if coll is BoneSdfPrimitive:
        var p := coll as BoneSdfPrimitive
        match p.prim_type:
            BoneSdfPrimitive.PRIM_SPHERE:
                return lp.length() - p.radius
            BoneSdfPrimitive.PRIM_CAPSULE:
                var q = Vector2(Vector2(lp.x, lp.z).length(), abs(lp.y) - p.half_height)
                return Vector2(max(q.x,0), max(q.y,0)).length() + min(max(q.x,q.y), 0.0) - p.radius
            BoneSdfPrimitive.PRIM_BOX:
                var q = Vector3(abs(lp.x)-p.half_extents.x, abs(lp.y)-p.half_extents.y, abs(lp.z)-p.half_extents.z)
                return Vector3(max(q.x,0),max(q.y,0),max(q.z,0)).length() + min(max(q.x,max(q.y,q.z)),0.0)
    elif coll is BoneSdfConvex:
        var cv := coll as BoneSdfConvex
        var d = -1e10
        for i in range(cv.face_count):
            var n = Vector3(cv.face_planes[i*4], cv.face_planes[i*4+1], cv.face_planes[i*4+2])
            d = max(d, n.dot(lp) - cv.face_planes[i*4+3])
        return d
    return 1e10

## ── DEPTH-BASED RIGIDITY ─────────────────────────────────────────────

func _compute_rigidity_from_depth():
    ## BFS from kinematic verts outward through tet connectivity.
    ## Rigidity ramps from 0.0 (at kinematic boundary) to 1.0 (at max depth).
    ## The blend is controlled by rigidity_blend_radius and rigidity_falloff.

    # Build tet vertex adjacency (which verts are connected via shared tets)
    var adjacency: Array[PackedInt32Array] = []
    adjacency.resize(Nv)
    for vi in range(Nv):
        adjacency[vi] = PackedInt32Array()

    for ti in range(Nt):
        var v0 = flesh_data.tet_cells[ti*4]
        var v1 = flesh_data.tet_cells[ti*4+1]
        var v2 = flesh_data.tet_cells[ti*4+2]
        var v3 = flesh_data.tet_cells[ti*4+3]
        var quad = [v0, v1, v2, v3]
        for a in range(4):
            for b in range(a+1, 4):
                adjacency[quad[a]].append(quad[b])
                adjacency[quad[b]].append(quad[a])

    # Dijkstra-like distance computation from kinematic verts
    var dist = PackedFloat32Array()
    dist.resize(Nv)
    dist.fill(1e10)

    # Seed: kinematic verts at distance 0
    var queue: Array[int] = []
    for vi in range(Nv):
        if tet_bone_assignment[vi] >= 0:
            dist[vi] = 0.0
            queue.append(vi)

    # BFS with Euclidean edge weights
    var head = 0
    while head < queue.size():
        var vi = queue[head]
        head += 1
        var pos_i = Vector3(
            flesh_data.tet_verts[vi*3],
            flesh_data.tet_verts[vi*3+1],
            flesh_data.tet_verts[vi*3+2]
        )
        for ni in adjacency[vi]:
            var pos_n = Vector3(
                flesh_data.tet_verts[ni*3],
                flesh_data.tet_verts[ni*3+1],
                flesh_data.tet_verts[ni*3+2]
            )
            var edge_len = pos_i.distance_to(pos_n)
            var new_dist = dist[vi] + edge_len
            if new_dist < dist[ni]:
                dist[ni] = new_dist
                queue.append(ni)

    # Convert distance to rigidity via falloff curve
    tet_rigidity = PackedFloat32Array()
    tet_rigidity.resize(Nv)

    for vi in range(Nv):
        if tet_bone_assignment[vi] >= 0:
            tet_rigidity[vi] = 0.0   # kinematic: zero rigidity
        else:
            var t = clampf(dist[vi] / rigidity_blend_radius, 0.0, 1.0)
            match rigidity_falloff:
                0: tet_rigidity[vi] = t                        # linear
                1: tet_rigidity[vi] = t * t                    # quadratic
                2: tet_rigidity[vi] = t * t * (3.0 - 2.0 * t) # smoothstep
                _: tet_rigidity[vi] = t

    print("FleshDeformer: rigidity range [%.3f .. %.3f]" %
          [tet_rigidity.min(), tet_rigidity.max()])

## ── COLOR GROUPS ─────────────────────────────────────────────────────

func _build_color_groups():
    ## Greedy graph coloring: partition tets into groups where no two tets
    ## in the same group share a vertex. Tets in a group can be solved
    ## in parallel without write conflicts.

    var vert_to_tets: Dictionary = {}
    for ti in range(Nt):
        for k in range(4):
            var vi = flesh_data.tet_cells[ti*4+k]
            if not vert_to_tets.has(vi): vert_to_tets[vi] = []
            vert_to_tets[vi].append(ti)

    var tet_color = PackedInt32Array()
    tet_color.resize(Nt)
    tet_color.fill(-1)

    for ti in range(Nt):
        var used = {}
        for k in range(4):
            var vi = flesh_data.tet_cells[ti*4+k]
            for nti in vert_to_tets.get(vi, []):
                if nti != ti and tet_color[nti] >= 0:
                    used[tet_color[nti]] = true
        var c = 0
        while used.has(c): c += 1
        tet_color[ti] = c

    n_colors = tet_color.max() + 1

    var counts = PackedInt32Array()
    counts.resize(n_colors); counts.fill(0)
    for ti in range(Nt): counts[tet_color[ti]] += 1

    var offsets = PackedInt32Array()
    offsets.resize(n_colors + 1); offsets[0] = 0
    for c in range(n_colors):
        offsets[c+1] = offsets[c] + counts[c]

    var groups = PackedInt32Array()
    groups.resize(Nt)
    var fill = offsets.duplicate()
    for ti in range(Nt):
        var c = tet_color[ti]
        groups[fill[c]] = ti
        fill[c] += 1

    _color_groups_data = groups
    _color_offsets_data = offsets
    print("FleshDeformer: %d color groups" % n_colors)

var _color_groups_data: PackedInt32Array
var _color_offsets_data: PackedInt32Array

## ── TRANSFORM HELPERS ────────────────────────────────────────────────

static func _xform_to_mat4(xf: Transform3D) -> PackedFloat32Array:
    ## Column-major mat4 for GLSL
    var b = xf.basis; var o = xf.origin
    return PackedFloat32Array([
        b.x.x, b.x.y, b.x.z, 0.0,
        b.y.x, b.y.y, b.y.z, 0.0,
        b.z.x, b.z.y, b.z.z, 0.0,
        o.x,   o.y,   o.z,   1.0,
    ])

## ── GPU ALLOCATION ───────────────────────────────────────────────────

func _allocate_gpu_buffers():
    var n_bones = skeleton.get_bone_count() if skeleton else 0
    var n_coll  = bone_colliders.size()

    # Bone transforms
    bone_transforms_buf = rd.storage_buffer_create(max(n_bones,1) * 64)

    # Colliders (112 bytes per struct)
    collider_data_buf = rd.storage_buffer_create(max(n_coll,1) * 112)

    # Convex face pool
    var fp_size = max(_convex_pool.size(), 4) * 4
    convex_faces_buf = rd.storage_buffer_create(fp_size)
    if not _convex_pool.is_empty():
        rd.buffer_update(convex_faces_buf, 0, _convex_pool.to_byte_array())

    # Tet simulation state
    tet_pos_buf          = rd.storage_buffer_create(Nv * 12)
    tet_vel_buf          = rd.storage_buffer_create(Nv * 12)
    tet_prev_pos_buf     = rd.storage_buffer_create(Nv * 12)
    kinematic_target_buf = rd.storage_buffer_create(Nv * 12)

    # Tet static data
    tet_rest_buf     = rd.storage_buffer_create(Nv * 12)
    tet_cells_buf    = rd.storage_buffer_create(Nt * 16)
    inv_rest_dm_buf  = rd.storage_buffer_create(Nt * 36)
    rest_vol_buf     = rd.storage_buffer_create(Nt * 4)
    bone_assign_buf  = rd.storage_buffer_create(Nv * 4)
    rigidity_buf     = rd.storage_buffer_create(Nv * 4)

    # Color groups
    color_groups_buf  = rd.storage_buffer_create(_color_groups_data.size() * 4)
    color_offsets_buf = rd.storage_buffer_create(_color_offsets_data.size() * 4)

    # Barycentric / output
    bary_tet_idx_buf     = rd.storage_buffer_create(Nr * 4)
    bary_uvw_buf         = rd.storage_buffer_create(Nr * 12)
    render_influence_buf = rd.storage_buffer_create(Nr * 4)
    render_delta_buf     = rd.storage_buffer_create(Nr * 12)

## ── STATIC UPLOAD ────────────────────────────────────────────────────

func _upload_static_data():
    # Tet rest positions (Godot space, no conversion needed)
    rd.buffer_update(tet_rest_buf, 0, flesh_data.tet_verts.to_byte_array())
    rd.buffer_update(tet_pos_buf,  0, flesh_data.tet_verts.to_byte_array())

    # Tet cells
    rd.buffer_update(tet_cells_buf, 0, flesh_data.tet_cells.to_byte_array())

    # Precomputed inverse rest DM + volumes
    _upload_rest_matrices()

    # Classification + rigidity (computed at load, uploaded once)
    rd.buffer_update(bone_assign_buf, 0, tet_bone_assignment.to_byte_array())
    rd.buffer_update(rigidity_buf,    0, tet_rigidity.to_byte_array())

    # Color groups
    rd.buffer_update(color_groups_buf,  0, _color_groups_data.to_byte_array())
    rd.buffer_update(color_offsets_buf, 0, _color_offsets_data.to_byte_array())

    # Barycentrics + influence
    rd.buffer_update(bary_tet_idx_buf,     0, flesh_data.bary_tet_idx.to_byte_array())
    rd.buffer_update(bary_uvw_buf,         0, flesh_data.bary_uvw.to_byte_array())
    rd.buffer_update(render_influence_buf, 0, flesh_data.render_influence.to_byte_array())

func _upload_rest_matrices():
    var inv_dm = PackedFloat32Array(); inv_dm.resize(Nt * 9)
    var vols   = PackedFloat32Array(); vols.resize(Nt)

    for ti in range(Nt):
        var ids = [
            flesh_data.tet_cells[ti*4], flesh_data.tet_cells[ti*4+1],
            flesh_data.tet_cells[ti*4+2], flesh_data.tet_cells[ti*4+3]
        ]
        var p = []
        for idx in ids:
            p.append(Vector3(flesh_data.tet_verts[idx*3],
                             flesh_data.tet_verts[idx*3+1],
                             flesh_data.tet_verts[idx*3+2]))

        var DM = Basis(p[1]-p[0], p[2]-p[0], p[3]-p[0])
        vols[ti] = DM.determinant() / 6.0
        var inv = DM.inverse()

        # Column-major mat3 for GLSL
        for col in range(3):
            for row in range(3):
                inv_dm[ti*9 + col*3 + row] = inv[col][row]

    rd.buffer_update(inv_rest_dm_buf, 0, inv_dm.to_byte_array())
    rd.buffer_update(rest_vol_buf,    0, vols.to_byte_array())

## ── PER-FRAME UPLOADS ────────────────────────────────────────────────

func _upload_bone_transforms():
    if not skeleton: return
    var n = skeleton.get_bone_count()
    var data = PackedFloat32Array(); data.resize(n * 16)
    var sw = skeleton.global_transform

    for bi in range(n):
        var posed    = skeleton.get_bone_global_pose(bi)
        var rest_inv = skeleton.get_bone_global_rest(bi).affine_inverse()
        var skinning = sw * posed * rest_inv
        var m = _xform_to_mat4(skinning)
        for fi in range(16):
            data[bi*16 + fi] = m[fi]

    rd.buffer_update(bone_transforms_buf, 0, data.to_byte_array())

func _upload_collider_transforms():
    var struct_sz = 112
    var data = PackedByteArray()
    data.resize(max(bone_colliders.size(), 1) * struct_sz)
    data.fill(0)

    for ci in range(bone_colliders.size()):
        var coll = bone_colliders[ci]
        var base = ci * struct_sz

        var bw = Transform3D.IDENTITY
        if coll.bone_index >= 0:
            var pb = _bone_cache.get(coll.bone_name)
            if pb: bw = pb.global_transform

        var inv = (bw * coll.local_transform).affine_inverse()
        var m = _xform_to_mat4(inv)
        for fi in range(16):
            data.encode_float(base + fi*4, m[fi])

        data.encode_s32(base + 64, coll.sdf_type)
        data.encode_s32(base + 68, coll.bone_index)
        # 72–79: implicit padding (zeroed)

        var params = coll.fill_gpu_params()
        for pi in range(4): data.encode_float(base + 80 + pi*4, params[pi])
        for pi in range(2): data.encode_float(base + 96 + pi*4, params[4+pi])

    rd.buffer_update(collider_data_buf, 0, data)

## ── COMPUTE DISPATCH ─────────────────────────────────────────────────

func _dispatch_kinematic_pass():
    var wg = ceili(Nv / 64.0)
    _dispatch_shader(shader_kinematic, wg, [
        bone_transforms_buf, tet_pos_buf, tet_rest_buf,
        bone_assign_buf, kinematic_target_buf
    ])

func _dispatch_elasticity_and_volume():
    for c in range(n_colors):
        var count = _color_offsets_data[c+1] - _color_offsets_data[c]
        if count == 0: continue
        var wg = ceili(count / 64.0)
        _dispatch_shader_color(shader_elasticity, wg, c)
        rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE)
        _dispatch_shader_color(shader_volume, wg, c)
        rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE)

func _dispatch_surface_transfer():
    var wg = ceili(Nr / 64.0)
    _dispatch_shader(shader_surface_xfer, wg, [
        tet_pos_buf, kinematic_target_buf, flesh_data.tet_cells,
        bary_tet_idx_buf, bary_uvw_buf, render_influence_buf,
        render_delta_buf
    ])

## ── SHADER COMPILATION ───────────────────────────────────────────────

func _compile_shaders():
    var base = "res://flesh_deformer/shaders/"
    shader_kinematic     = _load_shader(base + "kinematic_targets.glsl")
    shader_integrate     = _load_shader(base + "integrate.glsl")
    shader_elasticity    = _load_shader(base + "solve_elasticity.glsl")
    shader_volume        = _load_shader(base + "solve_volume.glsl")
    shader_kinematic_pin = _load_shader(base + "solve_kinematic_pin.glsl")
    shader_sdf_collision = _load_shader(base + "solve_sdf_collision.glsl")
    shader_lra_tether    = _load_shader(base + "solve_lra_tether.glsl")
    shader_vel_update    = _load_shader(base + "update_velocity.glsl")
    shader_surface_xfer  = _load_shader(base + "surface_transfer.glsl")

func _load_shader(path: String) -> RID:
    return rd.shader_create_from_spirv((load(path) as RDShaderFile).get_spirv())
```

---

## Key Compute Shaders

### `shaders/kinematic_targets.glsl`

```glsl
#version 450
layout(local_size_x = 64) in;

layout(std430, binding = 0) readonly  buffer BT  { mat4  bone_transforms[]; };
layout(std430, binding = 1)           buffer TP  { float tet_pos[]; };
layout(std430, binding = 2) readonly  buffer TR  { float tet_rest[]; };
layout(std430, binding = 3) readonly  buffer BA  { int   bone_assign[]; };
layout(std430, binding = 4) writeonly buffer KT  { float kinematic_target[]; };

layout(push_constant) uniform PC { uint n_verts; } pc;

void main() {
    uint vi = gl_GlobalInvocationID.x;
    if (vi >= pc.n_verts) return;

    int bi = bone_assign[vi];
    vec3 rest = vec3(tet_rest[vi*3], tet_rest[vi*3+1], tet_rest[vi*3+2]);

    // Compute target for all verts (kinematic get their bone, free get root)
    int target_bone = (bi >= 0) ? bi : 0;
    vec4 posed = bone_transforms[target_bone] * vec4(rest, 1.0);

    kinematic_target[vi*3+0] = posed.x;
    kinematic_target[vi*3+1] = posed.y;
    kinematic_target[vi*3+2] = posed.z;

    if (bi >= 0) {
        tet_pos[vi*3+0] = posed.x;
        tet_pos[vi*3+1] = posed.y;
        tet_pos[vi*3+2] = posed.z;
    }
}
```

### `shaders/surface_transfer.glsl`

```glsl
#version 450
layout(local_size_x = 64) in;

layout(std430, binding = 0) readonly  buffer TP   { float tet_pos[]; };
layout(std430, binding = 1) readonly  buffer KT   { float kinematic_target[]; };
layout(std430, binding = 2) readonly  buffer TC   { int   tet_cells[]; };
layout(std430, binding = 3) readonly  buffer BTI  { int   bary_tet_idx[]; };
layout(std430, binding = 4) readonly  buffer BUVW { float bary_uvw[]; };
layout(std430, binding = 5) readonly  buffer RI   { float render_influence[]; };
layout(std430, binding = 6) writeonly buffer RD   { float render_delta[]; };

layout(push_constant) uniform PC { uint n_render_verts; } pc;

void main() {
    uint vid = gl_GlobalInvocationID.x;
    if (vid >= pc.n_render_verts) return;

    int ti = bary_tet_idx[vid];

    // Vertex not mapped to any tet — zero delta
    if (ti < 0) {
        render_delta[vid*3+0] = 0.0;
        render_delta[vid*3+1] = 0.0;
        render_delta[vid*3+2] = 0.0;
        return;
    }

    float u  = bary_uvw[vid*3+0];
    float v  = bary_uvw[vid*3+1];
    float w  = bary_uvw[vid*3+2];
    float w0 = 1.0 - u - v - w;

    int i0 = tet_cells[ti*4+0], i1 = tet_cells[ti*4+1];
    int i2 = tet_cells[ti*4+2], i3 = tet_cells[ti*4+3];

    // Simulated position (tet deformed)
    vec3 sim = w0 * vec3(tet_pos[i0*3], tet_pos[i0*3+1], tet_pos[i0*3+2])
             + u  * vec3(tet_pos[i1*3], tet_pos[i1*3+1], tet_pos[i1*3+2])
             + v  * vec3(tet_pos[i2*3], tet_pos[i2*3+1], tet_pos[i2*3+2])
             + w  * vec3(tet_pos[i3*3], tet_pos[i3*3+1], tet_pos[i3*3+2]);

    // Kinematic target (what bone-only LBS would produce)
    vec3 tgt = w0 * vec3(kinematic_target[i0*3], kinematic_target[i0*3+1], kinematic_target[i0*3+2])
             + u  * vec3(kinematic_target[i1*3], kinematic_target[i1*3+1], kinematic_target[i1*3+2])
             + v  * vec3(kinematic_target[i2*3], kinematic_target[i2*3+1], kinematic_target[i2*3+2])
             + w  * vec3(kinematic_target[i3*3], kinematic_target[i3*3+1], kinematic_target[i3*3+2]);

    // Delta scaled by artist-painted influence
    vec3 delta = (sim - tgt) * render_influence[vid];

    render_delta[vid*3+0] = delta.x;
    render_delta[vid*3+1] = delta.y;
    render_delta[vid*3+2] = delta.z;
}
```

---

## Delta Application

Two approaches, same as v1. **CompositorEffect is recommended.**

**Approach A — CompositorEffect:** A compute pass after Godot's LBS skinning
reads the delta buffer and applies it to the mesh vertex buffer via
RenderingServer. Works with any material.

**Approach B — Texture buffer in vertex shader:** Encode deltas into a float
texture, sample in a custom spatial shader via `texelFetch(delta_tex, VERTEX_ID)`.
Requires a custom shader on the character.

Both are documented in the v1 Godot plan. The core interface is unchanged:
the `render_delta_buf` (written by `surface_transfer.glsl`) is the input
to whichever application method is used.

---

## Implementation Sequence

0. **Delta application prototype** — Verify CompositorEffect or texture-buffer
   approach works with a hardcoded trivial delta. Highest-risk integration point.

1. **FleshData .bin loader** — Parse file, print counts.

2. **Bone collider classes** — Parse PhysicalBoneSimulator3D, CPU SDF evaluation
   on sample points.

3. **Kinematic classification** — Evaluate rest-pose, print counts. Debug draw
   kinematic (red) vs free (green) verts.

4. **Depth-based rigidity** — BFS, print min/max rigidity. Debug draw gradient.

5. **GPU buffer allocation + static upload** — Verify no allocation errors.

6. **Kinematic targets shader** — Read back, verify kinematic verts follow bones.

7. **Surface transfer shader** — Static tet positions, verify render mesh follows.

8. **XPBD integrate + velocity** — Gravity only, mesh should fall.

9. **Elasticity + volume constraints** — Mesh resists deformation.

10. **Kinematic pins** — Flesh stays attached to skeleton.

11. **SDF collision** — Flesh pushed out of bone colliders.

12. **LRA tether** — Skin boundary drift constrained.

13. **Full integration** — Running character with jiggle.

---

## Exported Parameters Summary

```
FleshDeformer (Node):
  flesh_data_path:        String     — path to .bin file

  Simulation:
    num_substeps:         int = 4    — quality vs. cost (biggest perf lever)
    stiffness:            float = 5000
    damping:              float = 0.02
    gravity:              Vector3
    skin_sdf_offset:      float = 0.002

  Rigidity:
    rigidity_blend_radius: float = 0.15  — world units
    rigidity_falloff:      enum = Smooth  — Linear / Quadratic / Smooth
```

The artist controls per-vertex surface influence via `flesh_influence` painted
in Blender. Everything else is tuned numerically in the Godot inspector.
