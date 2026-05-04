@tool
class_name TentacleDebugOverlay
extends Node3D
## TentacleTech debug gizmo overlay (Phase 2).
##
## Spec: docs/architecture/TentacleTech_Architecture.md §15.
##
## Hosts per-layer MeshInstance3D children that pull snapshots from a Tentacle
## node and rebuild ImmediateMesh geometry per _process. The C++ solver does
## not know this overlay exists — pull, never push.
##
## Add this node as a sibling/child of a Tentacle and assign `tentacle`. Toggle
## visibility with the input action `tentacletech_debug_toggle` (F3 by default;
## the test scene registers the action — the main project does not, so the
## overlay stays silent there).

@export var tentacle: Node3D
@export var orifice: Node3D
@export var enabled: bool = true
@export var show_particles: bool = true
@export var show_constraints: bool = true
@export var show_bending: bool = true
@export var show_environment: bool = true
@export var show_orifice: bool = true
@export_range(0.0, 0.2, 0.001) var particle_gizmo_size: float = 0.02
@export var toggle_action: StringName = &"tentacletech_debug_toggle"

const _ParticlesLayer := preload("res://addons/tentacletech/scripts/debug/gizmo_layers/particles_layer.gd")
const _ConstraintsLayer := preload("res://addons/tentacletech/scripts/debug/gizmo_layers/constraints_layer.gd")
const _EnvironmentLayer := preload("res://addons/tentacletech/scripts/debug/gizmo_layers/environment_layer.gd")
const _OrificeLayer := preload("res://addons/tentacletech/scripts/debug/gizmo_layers/orifice_layer.gd")

var _particles_layer: Node3D
var _constraints_layer: Node3D
var _environment_layer: Node3D
var _orifice_layer: Node3D


func _ready() -> void:
	# INTERNAL_MODE_FRONT keeps the layer nodes out of the editor scene tree
	# and out of the .tscn — important when @tool causes _ready() to fire at
	# edit time, since regular add_child would persist these on save.
	_particles_layer = _ParticlesLayer.new()
	_particles_layer.name = "ParticlesLayer"
	add_child(_particles_layer, false, Node.INTERNAL_MODE_FRONT)

	_constraints_layer = _ConstraintsLayer.new()
	_constraints_layer.name = "ConstraintsLayer"
	add_child(_constraints_layer, false, Node.INTERNAL_MODE_FRONT)

	_environment_layer = _EnvironmentLayer.new()
	_environment_layer.name = "EnvironmentLayer"
	add_child(_environment_layer, false, Node.INTERNAL_MODE_FRONT)

	_orifice_layer = _OrificeLayer.new()
	_orifice_layer.name = "OrificeLayer"
	add_child(_orifice_layer, false, Node.INTERNAL_MODE_FRONT)


func _process(_delta: float) -> void:
	# F3 toggle is runtime-only — input polling is meaningless at edit time.
	if not Engine.is_editor_hint():
		if InputMap.has_action(toggle_action) and Input.is_action_just_pressed(toggle_action):
			enabled = not enabled

	# Zero cost when disabled — short-circuit the per-frame rebuild.
	var has_target: bool = tentacle != null or orifice != null
	var should_draw: bool = enabled and has_target
	visible = should_draw
	if not should_draw:
		return

	_particles_layer.visible = show_particles and tentacle != null
	_constraints_layer.visible = show_constraints and tentacle != null
	_environment_layer.visible = show_environment and tentacle != null
	_orifice_layer.visible = show_orifice and orifice != null

	if tentacle != null:
		if show_particles:
			_particles_layer.update_from(tentacle, particle_gizmo_size)
		if show_constraints:
			_constraints_layer.update_from(tentacle, show_bending)
		if show_environment:
			_environment_layer.update_from(tentacle)
	if orifice != null and show_orifice:
		_orifice_layer.update_from(orifice)
