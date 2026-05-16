@tool
class_name BodyField
extends Node3D

## Per-hero body field node. Owns the tet substrate's runtime state.
##
## v1 = kinematic-only (per Cosmic_Bliss_Update_2026-05-13_body_field_v1_kinematic_only.md):
## one compute pass (`kinematic_targets.glsl`) skins tet vertices from the
## hero's `Skeleton3D` once per physics tick using 4-bone weighted LBS.
## No XPBD; no Stable Neo-Hookean; no surface_transfer; the tet proxy is
## consumed only by TentacleTech contact dispatch (B3+, layered behind
## `LAYER_BODY_PROXY`).
##
## Per-hero opt-in: a hero without a `BodyField` node falls through to the
## existing capsule path. This node itself loads cleanly with no `flesh_data`
## and with no `skeleton` (hard-optional invariant — push_error and skip
## dispatch in both cases).

const _FleshData := preload("res://addons/body_field/runtime/flesh_data.gd")
const _BodyFieldGizmo := preload("res://addons/body_field/debug/body_field_gizmo.gd")
const _BodyFieldLayers := preload("res://addons/body_field/runtime/collision_layers.gd")
const _SHADER_PATH := "res://addons/body_field/shaders/kinematic_targets.glsl"

@export_file("*.bin") var flesh_data_path: String = ""
## Explicit skeleton handle — no scene-magic lookup. Heroes wire this in the
## scene. Loading with null is legal (push_error, skip dispatch); makes the
## node hard-optional per project CLAUDE.md.
@export var skeleton: Skeleton3D = null
@export var show_debug_gizmo: bool = false:
	set(value):
		show_debug_gizmo = value
		_refresh_gizmo()

# Runtime, not exported. Populated in _ready() from `flesh_data_path`.
var flesh_data: FleshData = null

var _gizmo: Node3D = null

# --- GPU state ----------------------------------------------------------
# All RD resources are allocated once in _init_compute() and freed once in
# _exit_tree(). No per-frame allocations; the bone-transforms buffer is
# updated in place via buffer_update.

var _rd: RenderingDevice = null
## When true, _rd was allocated locally (via create_local_rendering_device).
## In that case we own the device and must free our own resources, and the
## device drives submit/sync explicitly — _physics_process does not.
var _rd_is_local: bool = false
var _shader_rid: RID = RID()
var _pipeline_rid: RID = RID()
var _uniform_set_rid: RID = RID()
var _bone_buf: RID = RID()
var _rest_buf: RID = RID()
var _skin_idx_buf: RID = RID()
var _skin_w_buf: RID = RID()
var _tet_pos_buf: RID = RID()

var _compute_ready: bool = false
var _bone_count: int = 0

# --- Collision proxy state (B3) -----------------------------------------
# AnimatableBody3D + ConcavePolygonShape3D occupy LAYER_BODY_PROXY. The
# shape's face buffer is mutated each tick from CPU-side skinned tet
# positions. No re-allocation: `_proxy_faces_packed` is sized once.
#
# Per the 05-14 §3.2 contract, TT's reciprocal path identifies the proxy
# by reading `body_field_owner` meta on the AnimatableBody3D (a WeakRef
# to this BodyField), then calls `receive_external_impulse(...)`.
var _tet_proxy_body: AnimatableBody3D = null
var _tet_proxy_shape: ConcavePolygonShape3D = null
var _proxy_faces_packed: PackedVector3Array = PackedVector3Array()
# Pre-allocated CPU skinning scratch: 1 Vector3 per tet vert, reused tick to
# tick. This is the "CPU-side bone-LBS fallback" path — see PHASE_LOG B3
# for why we don't read the GPU buffer back here.
var _tet_pos_cpu: PackedVector3Array = PackedVector3Array()
# Pre-allocated bone skinning matrix cache: 1 Transform3D per bone.
var _bone_skin_xform: Array[Transform3D] = []

# --- Impulse re-routing (B3) --------------------------------------------
# Set by Marionette at hero-init via `set_bone_body_rids()`. Index = bone
# index. Entries default to invalid RID (RID()) → treated as "no Jolt body
# wired for this bone, skip". Whole table empty → `receive_external_impulse`
# is a no-op.
#
# Why Array[RID] and not PackedInt64Array: RIDs cannot be reconstructed
# from their int id in GDScript — they're opaque handles.
var _bone_body_rids: Array[RID] = []

# Indirect Callable so tests can record calls without touching the global
# PhysicsServer3D. Production callers MUST NOT replace this; the default
# wrapper is the v1 contract. Override pattern:
#   bf._apply_impulse_to_bone = func(rid, imp, pos): _recorder.append([rid, imp, pos])
var _apply_impulse_to_bone: Callable = func(rid: RID, imp: Vector3, pos: Vector3) -> void:
	PhysicsServer3D.body_apply_impulse(rid, imp, pos)


func _init() -> void:
	# Run before TentacleTech in the physics tick — TT reads at substep
	# boundary; the body_field write must precede that read.
	# (Non-negotiable: dispatch ordering must place body_field's write
	# before TT's per-substep probe.)
	process_priority = -100


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if flesh_data_path != "":
		flesh_data = _FleshData.load_bin(flesh_data_path)
		if flesh_data == null:
			push_error("BodyField: failed to load FleshData from %s" % flesh_data_path)
	_refresh_gizmo()
	# Hard-optional: skip compute init when either input is missing. The
	# node still lives in the scene tree and reports cleanly.
	if flesh_data == null:
		return
	if skeleton == null:
		push_error("BodyField: no Skeleton3D wired — skipping compute dispatch")
		return
	_init_compute()
	# B3: register the kinematic tet proxy on LAYER_BODY_PROXY. Only when
	# both flesh_data + skeleton are present (hard-optional invariant —
	# empty shape pollutes the scene otherwise).
	_init_tet_proxy_body()


func _physics_process(_delta: float) -> void:
	# Bone snapshot is taken ONCE here, per tick, before any constraint
	# solve. v1 has no constraint solve, so this is trivially satisfied;
	# the discipline is preserved for v1.5 (XPBD) to inherit.
	if not _compute_ready:
		return
	dispatch_once()


# --- Public API ---------------------------------------------------------

## Test-friendly explicit dispatch. Production calls this once per
## physics tick from `_physics_process`. B3/B5 consumers also call this
## explicitly if they need a fresh tet_pos buffer outside the tick boundary.
func dispatch_once() -> void:
	if not _compute_ready:
		return
	_upload_bone_transforms()
	_dispatch_compute()
	# B3: refresh collision proxy shape from CPU-side skinned tet positions.
	# We could read back _tet_pos_buf via _rd.buffer_get_data, but on the
	# global RD that returns either stale data or forces a sync that costs
	# more than the CPU LBS pass it would replace (Nv < 10⁴ in practice).
	# See PHASE_LOG B3 for the decision.
	if _tet_proxy_shape != null:
		_update_tet_proxy_shape_cpu()


## Returns the GPU buffer RID containing per-tet-vert world positions.
## Future B3/B5 consumers read this at the substep boundary. Returns an
## empty RID when compute isn't initialized.
func get_tet_positions_buffer_rid() -> RID:
	return _tet_pos_buf


## Test-only injection. When set before _ready(), _init_compute() uses
## this RenderingDevice instead of the global one. Used by the headless
## test harness where the global RD's submit/sync timing is awkward and
## a local RD with explicit barrier()/submit()/sync() is the simpler path.
## Production must NOT use this — _rd defaults to RenderingServer.get_rendering_device().
func _set_rendering_device_for_test(rd: RenderingDevice) -> void:
	_rd = rd
	_rd_is_local = true


# --- Compute initialization ---------------------------------------------

func _init_compute() -> void:
	if _rd == null:
		# Production path: the global RD shared with Godot's renderer.
		_rd = RenderingServer.get_rendering_device()
		_rd_is_local = false
	if _rd == null:
		push_error("BodyField: no RenderingDevice available — skipping compute dispatch")
		return

	_bone_count = skeleton.get_bone_count()
	if _bone_count <= 0:
		push_error("BodyField: skeleton has 0 bones — skipping compute dispatch")
		return

	# --- Compile shader ---------------------------------------------
	var shader_file := load(_SHADER_PATH) as RDShaderFile
	if shader_file == null:
		push_error("BodyField: failed to load shader %s" % _SHADER_PATH)
		return
	var spirv := shader_file.get_spirv()
	_shader_rid = _rd.shader_create_from_spirv(spirv)
	if not _shader_rid.is_valid():
		push_error("BodyField: shader_create_from_spirv failed")
		return

	# --- Allocate buffers -------------------------------------------
	# Static, uploaded once:
	var rest_bytes := flesh_data.tet_verts.to_byte_array()
	_rest_buf = _rd.storage_buffer_create(rest_bytes.size(), rest_bytes)
	var idx_bytes := flesh_data.tet_skin_indices.to_byte_array()
	_skin_idx_buf = _rd.storage_buffer_create(idx_bytes.size(), idx_bytes)
	var w_bytes := flesh_data.tet_skin_weights.to_byte_array()
	_skin_w_buf = _rd.storage_buffer_create(w_bytes.size(), w_bytes)

	# Dynamic, uploaded each tick:
	var bone_bytes_size: int = _bone_count * 16 * 4  # mat4 = 16 floats
	_bone_buf = _rd.storage_buffer_create(bone_bytes_size)

	# Output:
	var pos_bytes_size: int = flesh_data.n_tet_verts * 3 * 4
	_tet_pos_buf = _rd.storage_buffer_create(pos_bytes_size)

	# --- Pipeline + uniform set -------------------------------------
	_pipeline_rid = _rd.compute_pipeline_create(_shader_rid)
	_uniform_set_rid = _rd.uniform_set_create([
		_mk_storage_uniform(0, _bone_buf),
		_mk_storage_uniform(1, _rest_buf),
		_mk_storage_uniform(2, _skin_idx_buf),
		_mk_storage_uniform(3, _skin_w_buf),
		_mk_storage_uniform(4, _tet_pos_buf),
	], _shader_rid, 0)

	_compute_ready = true


func _mk_storage_uniform(binding: int, buf: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(buf)
	return u


# --- Per-tick upload + dispatch -----------------------------------------

func _upload_bone_transforms() -> void:
	# Per-bone skinning matrix: world_now * world_rest_inv. With this,
	# multiplying by a rest-pose tet vertex (in world space, Godot Y-up
	# per .bin v3) yields its current world position. Identity rest →
	# identity pose → identity skinning matrix, which is what the
	# synthetic LBS test relies on.
	var sw := skeleton.global_transform
	var data := PackedFloat32Array()
	data.resize(_bone_count * 16)

	for bi in range(_bone_count):
		var posed := skeleton.get_bone_global_pose(bi)
		var rest_inv := skeleton.get_bone_global_rest(bi).affine_inverse()
		var skinning := sw * posed * rest_inv
		_xform_to_mat4_into(skinning, data, bi * 16)

	var bytes := data.to_byte_array()
	_rd.buffer_update(_bone_buf, 0, bytes.size(), bytes)


# Pack a Godot Transform3D into 16 floats as a column-major mat4 (GLSL
# std430 mat4 layout). Columns 0..2 are basis columns (where unit X/Y/Z
# go); column 3 is the origin (with w=1).
#
# Godot quirk: `Basis.x/y/z` are the basis vectors — i.e. the COLUMNS of
# the transform matrix in standard mathematical notation, even though
# the Basis is stored internally row-major. `get_column(i)` exists in
# C++ but NOT in GDScript (parse error). Use `.x/.y/.z` directly.
func _xform_to_mat4_into(t: Transform3D, out: PackedFloat32Array, off: int) -> void:
	var b := t.basis
	var o := t.origin
	# Column 0 = where unit X goes = b.x
	out[off + 0] = b.x.x;  out[off + 1]  = b.x.y;  out[off + 2]  = b.x.z;  out[off + 3]  = 0.0
	# Column 1 = where unit Y goes = b.y
	out[off + 4] = b.y.x;  out[off + 5]  = b.y.y;  out[off + 6]  = b.y.z;  out[off + 7]  = 0.0
	# Column 2 = where unit Z goes = b.z
	out[off + 8] = b.z.x;  out[off + 9]  = b.z.y;  out[off + 10] = b.z.z;  out[off + 11] = 0.0
	# Column 3 = origin
	out[off + 12] = o.x;   out[off + 13] = o.y;   out[off + 14] = o.z;    out[off + 15] = 1.0


func _dispatch_compute() -> void:
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_rid)
	_rd.compute_list_bind_uniform_set(cl, _uniform_set_rid, 0)
	var pc := PackedInt32Array([flesh_data.n_tet_verts, 0, 0, 0]).to_byte_array()
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	var groups: int = (flesh_data.n_tet_verts + 63) / 64
	_rd.compute_list_dispatch(cl, max(groups, 1), 1, 1)
	_rd.compute_list_end()
	# When using the global RD, submit/sync happen at the render frame
	# boundary — we do NOT call submit() / sync() here. The local-RD test
	# path calls them explicitly via the RD it owns.


# --- Tet collision proxy (B3) -------------------------------------------

func _init_tet_proxy_body() -> void:
	if flesh_data == null:
		return
	if flesh_data.n_outer_faces <= 0:
		# Degenerate tet mesh (no boundary) — nothing to collide against.
		# Hard-optional: don't add an empty body to the scene.
		return
	# Resize scratch buffers once. `_proxy_faces_packed` is the canonical
	# face buffer per ConcavePolygonShape3D's `set_faces` API: a flat
	# PackedVector3Array of triangles (3 verts per triangle).
	_proxy_faces_packed = PackedVector3Array()
	_proxy_faces_packed.resize(flesh_data.n_outer_faces * 3)
	_tet_pos_cpu = PackedVector3Array()
	_tet_pos_cpu.resize(flesh_data.n_tet_verts)
	_bone_skin_xform = []
	_bone_skin_xform.resize(_bone_count)

	# Initial population from rest-pose verts (the proxy starts at rest,
	# then dispatch_once() refreshes per tick).
	for i in range(flesh_data.n_tet_verts):
		_tet_pos_cpu[i] = Vector3(
			flesh_data.tet_verts[i * 3 + 0],
			flesh_data.tet_verts[i * 3 + 1],
			flesh_data.tet_verts[i * 3 + 2])
	_pack_outer_faces_from_tet_pos()

	_tet_proxy_shape = ConcavePolygonShape3D.new()
	_tet_proxy_shape.set_faces(_proxy_faces_packed)

	var cs := CollisionShape3D.new()
	cs.shape = _tet_proxy_shape

	_tet_proxy_body = AnimatableBody3D.new()
	_tet_proxy_body.name = "TetProxyBody"
	_tet_proxy_body.collision_layer = _BodyFieldLayers.LAYER_BODY_PROXY
	_tet_proxy_body.collision_mask = 0  # we're a queryable, not a querier
	# Per 05-14 §3.2: TT's reciprocal path uses this meta to identify the
	# proxy body and route via `receive_external_impulse`. WeakRef avoids
	# keeping the BodyField alive on the body's lifetime.
	_tet_proxy_body.set_meta(&"body_field_owner", weakref(self))
	_tet_proxy_body.add_child(cs)
	add_child(_tet_proxy_body)


func _update_tet_proxy_shape_cpu() -> void:
	# Mirror the GLSL skinning: skin[b] = sw * posed[b] * rest_inv[b].
	# Cache once per tick into _bone_skin_xform; reuse for all Nv verts.
	var sw := skeleton.global_transform
	for bi in range(_bone_count):
		var posed := skeleton.get_bone_global_pose(bi)
		var rest_inv := skeleton.get_bone_global_rest(bi).affine_inverse()
		_bone_skin_xform[bi] = sw * posed * rest_inv

	# 4-bone weighted LBS per tet vert. Matches the shader exactly so any
	# B6-time GPU↔CPU drift surfaces as a same-tick test, not a real-time
	# bug.
	for v in range(flesh_data.n_tet_verts):
		var rest_v := Vector3(
			flesh_data.tet_verts[v * 3 + 0],
			flesh_data.tet_verts[v * 3 + 1],
			flesh_data.tet_verts[v * 3 + 2])
		var sum := Vector3.ZERO
		for k in range(4):
			var bi: int = flesh_data.tet_skin_indices[v * 4 + k]
			var w: float = flesh_data.tet_skin_weights[v * 4 + k]
			if w == 0.0:
				continue
			sum += w * (_bone_skin_xform[bi] * rest_v)
		_tet_pos_cpu[v] = sum

	_pack_outer_faces_from_tet_pos()
	# ConcavePolygonShape3D's set_faces fully replaces the shape's
	# triangle data each call. We do NOT reallocate the shape; the
	# Vector3 array is reused.
	_tet_proxy_shape.set_faces(_proxy_faces_packed)


func _pack_outer_faces_from_tet_pos() -> void:
	# Index _tet_pos_cpu by outer_faces into the pre-allocated face buffer.
	var of := flesh_data.outer_faces
	for fi in range(flesh_data.n_outer_faces):
		_proxy_faces_packed[fi * 3 + 0] = _tet_pos_cpu[of[fi * 3 + 0]]
		_proxy_faces_packed[fi * 3 + 1] = _tet_pos_cpu[of[fi * 3 + 1]]
		_proxy_faces_packed[fi * 3 + 2] = _tet_pos_cpu[of[fi * 3 + 2]]


# --- Impulse re-routing (B3) --------------------------------------------

## Set by Marionette at hero-init (slice coordinated via inbox). Index =
## bone index in `skeleton`. Entries that map to no Jolt body should be
## RID() (invalid); they're skipped at impulse time.
func set_bone_body_rids(rids: Array[RID]) -> void:
	_bone_body_rids = rids


## Public API per 05-14 §3.2. Called by TentacleTech's reciprocal path
## when the hit body's `body_field_owner` meta identifies this node.
## Looks up the nearest tet vertex to `world_point`, samples its 4 bone
## weights, and distributes the impulse as `impulse * w_b` to each
## skin-weighted bone's Jolt body.
##
## `ps` is reserved (TT contract); unused in v1.
func receive_external_impulse(world_point: Vector3, impulse: Vector3, ps: PhysicsDirectBodyState3D) -> void:
	# Hard-optional shortcuts:
	if flesh_data == null:
		return
	if _bone_body_rids.is_empty():
		return
	# Quick check: at least one valid RID?
	var has_any_valid := false
	for rid in _bone_body_rids:
		if rid.is_valid():
			has_any_valid = true
			break
	if not has_any_valid:
		return

	# Nearest-tet-vertex lookup against rest-pose positions (v1 simplification —
	# see PHASE_LOG B3: avoids a GPU readback or live CPU mirror; the rest-
	# pose error is bounded and v1.5 can refine if needed).
	var nv := flesh_data.n_tet_verts
	if nv <= 0:
		return
	var best_idx: int = 0
	var best_d2: float = INF
	for v in range(nv):
		var dx: float = flesh_data.tet_verts[v * 3 + 0] - world_point.x
		var dy: float = flesh_data.tet_verts[v * 3 + 1] - world_point.y
		var dz: float = flesh_data.tet_verts[v * 3 + 2] - world_point.z
		var d2: float = dx * dx + dy * dy + dz * dz
		if d2 < best_d2:
			best_d2 = d2
			best_idx = v

	# Distribute impulse across the 4 skin-weighted bones. v1 simplification:
	# `position` arg to body_apply_impulse is Vector3.ZERO (body-local origin)
	# — this drops torque from off-center hits. See PHASE_LOG B3 for the
	# fidelity-reduction note and v1.5 refinement plan.
	for k in range(4):
		var bi: int = flesh_data.tet_skin_indices[best_idx * 4 + k]
		var w: float = flesh_data.tet_skin_weights[best_idx * 4 + k]
		if w <= 1e-4:
			continue
		if bi < 0 or bi >= _bone_body_rids.size():
			continue
		var rid: RID = _bone_body_rids[bi]
		if not rid.is_valid():
			continue
		_apply_impulse_to_bone.call(rid, impulse * w, Vector3.ZERO)


# --- Surface-tag accessors (4S.3, B3) -----------------------------------

## `face_idx` is an outer-face index in [0, n_outer_faces). Returns 0
## ("no tag") when the optional v3 trailer was not authored or `face_idx`
## is out of range — that's the per-region material fallback.
func get_face_region_id(face_idx: int) -> int:
	if flesh_data == null:
		return 0
	var t := flesh_data.tet_face_region_id
	if face_idx < 0 or face_idx >= t.size():
		return 0
	return t[face_idx]


## Returns {"friction": μ, "compliance": c, "contact_stiffness": k} or {}.
## Schema (B3 freeze, see PHASE_LOG): `region_material_table` is a flat
## PackedFloat32Array of length 3*n_regions, packed [μ_0, comp_0, stiff_0,
## μ_1, comp_1, stiff_1, …]. Returns {} when the table is absent or
## region_id is out of range — TT then composes against tentacle defaults.
func get_region_material(region_id: int) -> Dictionary:
	if flesh_data == null:
		return {}
	var t := flesh_data.region_material_table
	var base: int = region_id * 3
	if region_id < 0 or base + 2 >= t.size():
		return {}
	return {
		"friction": t[base + 0],
		"compliance": t[base + 1],
		"contact_stiffness": t[base + 2],
	}


# --- Teardown -----------------------------------------------------------

func _exit_tree() -> void:
	_free_compute_resources()


func _free_compute_resources() -> void:
	if _rd == null:
		return
	if _uniform_set_rid.is_valid():
		_rd.free_rid(_uniform_set_rid)
		_uniform_set_rid = RID()
	if _pipeline_rid.is_valid():
		_rd.free_rid(_pipeline_rid)
		_pipeline_rid = RID()
	if _shader_rid.is_valid():
		_rd.free_rid(_shader_rid)
		_shader_rid = RID()
	for buf in [_bone_buf, _rest_buf, _skin_idx_buf, _skin_w_buf, _tet_pos_buf]:
		if buf.is_valid():
			_rd.free_rid(buf)
	_bone_buf = RID()
	_rest_buf = RID()
	_skin_idx_buf = RID()
	_skin_w_buf = RID()
	_tet_pos_buf = RID()
	_compute_ready = false


# --- Debug gizmo --------------------------------------------------------

func _refresh_gizmo() -> void:
	# Editor hot-toggle: build on demand, free on disable.
	if show_debug_gizmo and flesh_data != null:
		if _gizmo == null:
			_gizmo = _BodyFieldGizmo.new()
			add_child(_gizmo)
		_gizmo.set_flesh_data(flesh_data)
	elif _gizmo != null:
		_gizmo.queue_free()
		_gizmo = null
