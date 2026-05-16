@tool
extends MeshInstance3D
## Phase 6 stimulus-bus overlay (minimum slice).
##
## Pulls `StimulusBus.get_recent_events(time_window)` per frame and draws
## a small CMY-palette marker at each event's `world_position`. No label
## text yet — Label3D pool is deferred (see PHASE_LOG). Subscribers like
## Sonance still see exact `world_position`; the gizmo is a developer
## sanity-check that the bus is firing.
##
## Color mapping:
##   - PenetrationStart    — magenta
##   - GripEngaged         — cyan
##   - RingTransitStart    — green
##   - OrificeDamaged      — red
##   - KnotEngulfed        — yellow-ish (orange-yellow is reserved for
##     Godot's default skeleton gizmo; we use a lime-yellow blend)
##   - other event types   — neutral grey
##
## Per the gizmo color rule (CMY + RGB hierarchy, avoiding orange-yellow).

const _Colors := preload("res://addons/tentacletech/scripts/debug/colors.gd")

const MARKER_RADIUS := 0.025
const FADE_SECONDS := 1.0
const TIME_WINDOW := 2.0

@export var enabled: bool = true

var _imesh: ImmediateMesh
var _material: StandardMaterial3D
var _bus: Object = null


func _ready() -> void:
	_imesh = ImmediateMesh.new()
	mesh = _imesh

	_material = StandardMaterial3D.new()
	_material.vertex_color_use_as_albedo = true
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.no_depth_test = true
	_material.disable_receive_shadows = true
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.render_priority = RenderingServer.MATERIAL_RENDER_PRIORITY_MAX
	material_override = _material


func _color_for_event_type(p_type: int) -> Color:
	# Avoid hard-coding StimulusBus enum values — look them up at runtime
	# via ClassDB so a renumber in C++ doesn't desync.
	if not ClassDB.class_exists("StimulusBus"):
		return Color(0.7, 0.7, 0.7, 0.85)
	if p_type == ClassDB.class_get_integer_constant("StimulusBus", "EVENT_PenetrationStart"):
		return Color(1.0, 0.3, 0.95, 0.95)  # magenta
	if p_type == ClassDB.class_get_integer_constant("StimulusBus", "EVENT_GripEngaged"):
		return Color(0.3, 0.95, 1.0, 0.95)  # cyan
	if p_type == ClassDB.class_get_integer_constant("StimulusBus", "EVENT_RingTransitStart"):
		return Color(0.3, 1.0, 0.4, 0.95)  # green
	if p_type == ClassDB.class_get_integer_constant("StimulusBus", "EVENT_OrificeDamaged"):
		return Color(1.0, 0.3, 0.3, 0.95)  # red
	if p_type == ClassDB.class_get_integer_constant("StimulusBus", "EVENT_KnotEngulfed"):
		return Color(0.85, 1.0, 0.3, 0.95)  # lime-yellow
	return Color(0.7, 0.7, 0.7, 0.85)


func update_from_bus(p_bus: Object) -> void:
	_imesh.clear_surfaces()
	if not enabled or p_bus == null:
		return
	if not p_bus.has_method(&"get_recent_events"):
		return
	var events: Array = p_bus.call(&"get_recent_events", TIME_WINDOW, -1)
	if events.is_empty():
		return

	var inv: Transform3D = global_transform.affine_inverse()
	var any_vertex: bool = false
	for entry in events:
		if not (entry is Dictionary):
			continue
		var wp: Vector3 = entry.get("world_position", Vector3.ZERO)
		var local: Vector3 = inv * wp
		var t: int = entry.get("type", -1)
		var ts: float = entry.get("timestamp", 0.0)
		# Fade alpha by age relative to the bus's "now" — approximated
		# from the latest timestamp in the snapshot. Avoids reading the
		# bus's monotonic clock setter directly.
		var newest_ts: float = events[events.size() - 1].get("timestamp", 0.0)
		var age: float = newest_ts - ts
		var alpha: float = clamp(1.0 - age / FADE_SECONDS, 0.0, 1.0)
		if alpha <= 0.0:
			continue
		var color: Color = _color_for_event_type(t)
		color.a *= alpha

		if not any_vertex:
			_imesh.surface_begin(Mesh.PRIMITIVE_LINES)
			any_vertex = true
		# 3-axis cross at the event position.
		var r: float = MARKER_RADIUS
		_imesh.surface_set_color(color)
		_imesh.surface_add_vertex(local + Vector3(-r, 0, 0))
		_imesh.surface_set_color(color)
		_imesh.surface_add_vertex(local + Vector3(r, 0, 0))
		_imesh.surface_set_color(color)
		_imesh.surface_add_vertex(local + Vector3(0, -r, 0))
		_imesh.surface_set_color(color)
		_imesh.surface_add_vertex(local + Vector3(0, r, 0))
		_imesh.surface_set_color(color)
		_imesh.surface_add_vertex(local + Vector3(0, 0, -r))
		_imesh.surface_set_color(color)
		_imesh.surface_add_vertex(local + Vector3(0, 0, r))

	if any_vertex:
		_imesh.surface_end()
