extends Node3D
## Phase-2 PBD core visual test scene driver.
##
## Run from repo root:
##   godot --path game res://tests/tentacletech/scenes/test_solver_visual.tscn
##
## Drives the Tentacle's tip target around the anchor in a slow circle so the
## green target arrow tracks visibly and the chain whips between iterations.
## Volume preservation is visible as constraint segments shifting from white to
## red (stretch) and blue (compression) under load.
##
## Controls:
##   F3       toggle debug overlay (action registered here only — not in the
##            project's main input map, per agent contract)
##   Space    toggle target pull on/off
##   G        toggle gravity on/off
##   R        rebuild chain (resets particles to a straight pose)
##   Esc      quit

const TOGGLE_ACTION := &"tentacletech_debug_toggle"
const TARGET_RADIUS := 1.4
const TARGET_HEIGHT_OFFSET := -0.8
const TARGET_HEIGHT_AMPLITUDE := 0.5
const TARGET_PERIOD_S := 4.0
const TARGET_STIFFNESS := 0.15

@onready var tentacle: Node3D = $Tentacle

var _target_on: bool = true
var _gravity_on: bool = true
var _t: float = 0.0


func _ready() -> void:
	_register_toggle_action()
	_apply_target_state()
	_apply_gravity_state()
	_print_legend()


func _print_legend() -> void:
	print("\n[TentacleTech Phase 2 visual]")
	print("  Yellow sphere     anchor (particle 0, inv_mass = 0)")
	print("  Red cross         pinned particle (inv_mass = 0)")
	print("  White cross       free particle (inv_mass = 1)")
	print("  Blue → red line   distance constraint, color by stretch ratio")
	print("                    (blue = compressed, white = rest, red = stretched)")
	print("  Cyan arc          bending constraint between every triple")
	print("  Green arrow + ×   target-pull, line tip is the moving target")
	print("\n  F3 toggle overlay   Space toggle target   G toggle gravity   R rebuild   Esc quit\n")


func _process(delta: float) -> void:
	_t += delta
	if not _target_on or tentacle == null:
		return

	var anchor_pos: Vector3 = tentacle.global_transform.origin
	var phase: float = TAU * _t / TARGET_PERIOD_S
	var target := anchor_pos + Vector3(
		cos(phase) * TARGET_RADIUS,
		TARGET_HEIGHT_OFFSET + sin(phase * 0.5) * TARGET_HEIGHT_AMPLITUDE,
		sin(phase) * TARGET_RADIUS,
	)
	tentacle.set_target(target)


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_ESCAPE:
			get_tree().quit()
		KEY_SPACE:
			_target_on = not _target_on
			_apply_target_state()
		KEY_G:
			_gravity_on = not _gravity_on
			_apply_gravity_state()
		KEY_R:
			tentacle.rebuild_chain()
			_apply_target_state()
			_apply_gravity_state()


func _apply_target_state() -> void:
	if tentacle == null:
		return
	if _target_on:
		var solver: Object = tentacle.get_solver()
		var tip: int = tentacle.get_particle_count() - 1
		solver.set_target(tip, tentacle.global_transform.origin, TARGET_STIFFNESS)
	else:
		tentacle.clear_target()


func _apply_gravity_state() -> void:
	if tentacle == null:
		return
	var g: Vector3 = Vector3(0, -9.8, 0) if _gravity_on else Vector3.ZERO
	tentacle.get_solver().set_gravity(g)


func _register_toggle_action() -> void:
	if InputMap.has_action(TOGGLE_ACTION):
		return
	InputMap.add_action(TOGGLE_ACTION)
	var ev := InputEventKey.new()
	ev.keycode = KEY_F3
	InputMap.action_add_event(TOGGLE_ACTION, ev)
