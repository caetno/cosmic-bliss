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
