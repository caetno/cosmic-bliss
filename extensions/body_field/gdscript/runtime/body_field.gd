@tool
class_name BodyField
extends Node3D

## Per-hero body field node. Owns the tet substrate's runtime state
## (allocated at B1+: tet mesh + barycentric weights + bone SDF buffer
## + per-tick compute dispatch).
##
## B1 surface: loads a Version-2 `.bin` (FleshData) from `flesh_data_path`
## on _ready(), optional sanity gizmo (tet wireframe + barycentric ownership)
## under `show_debug_gizmo`. B2 grows the compute dispatch.

const _FleshData := preload("res://addons/body_field/runtime/flesh_data.gd")
const _BodyFieldGizmo := preload("res://addons/body_field/debug/body_field_gizmo.gd")

@export_file("*.bin") var flesh_data_path: String = ""
@export var show_debug_gizmo: bool = false:
	set(value):
		show_debug_gizmo = value
		_refresh_gizmo()

# Runtime, not exported. Populated in _ready() from `flesh_data_path`.
var flesh_data: FleshData = null

var _gizmo: Node3D = null


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if flesh_data_path != "":
		flesh_data = _FleshData.load_bin(flesh_data_path)
		if flesh_data == null:
			push_error("BodyField: failed to load FleshData from %s" % flesh_data_path)
	_refresh_gizmo()


## B0 scaffolding — exists purely so the bridge test can verify the
## res:// load + instantiate chain. Will be removed once B2 grows a real
## BodyField method surface that earns the bridge test's place.
func _bridge_test_marker() -> String:
	return "body_field ok"


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
