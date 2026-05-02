@tool
class_name MarionetteStatusPill
extends PanelContainer

# Top-of-inspector status row for a Marionette. Reports build state
# (ragdoll spawned? how many MarionetteBones + JiggleBones?) and sim
# state (running / stopped). Polled in _process — cheap since Inspector
# only renders the selected node.
#
# Built as a PanelContainer so we get a subtle background distinguishing
# it from the regular property rows. The layout is one HBoxContainer:
# [build icon][build label] | [sim icon][sim label].

var marionette: Marionette = null

var _build_label: Label
var _sim_label: Label
var _build_icon: TextureRect
var _sim_icon: TextureRect


func _init() -> void:
	add_theme_constant_override(&"margin_left", 8)
	add_theme_constant_override(&"margin_right", 8)
	add_theme_constant_override(&"margin_top", 4)
	add_theme_constant_override(&"margin_bottom", 4)
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override(&"separation", 12)
	add_child(hbox)

	_build_icon = TextureRect.new()
	_build_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_build_icon.custom_minimum_size = Vector2(16, 16)
	hbox.add_child(_build_icon)

	_build_label = Label.new()
	_build_label.text = "Not built"
	hbox.add_child(_build_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(spacer)

	_sim_icon = TextureRect.new()
	_sim_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_sim_icon.custom_minimum_size = Vector2(16, 16)
	hbox.add_child(_sim_icon)

	_sim_label = Label.new()
	_sim_label.text = "Sim stopped"
	hbox.add_child(_sim_label)


func _process(_delta: float) -> void:
	# Repoll every frame; cheap (single sim lookup + child count). Skip
	# when the marionette ref went stale (selection moved, scene closed).
	if marionette == null or not is_instance_valid(marionette):
		return
	_refresh()


func _refresh() -> void:
	var sim: PhysicalBoneSimulator3D = marionette._find_simulator()
	var theme := EditorInterface.get_editor_theme() if Engine.is_editor_hint() else null
	if sim == null:
		_build_label.text = "Not built"
		_sim_label.text = "—"
		_set_icon(_build_icon, theme, &"StatusWarning")
		_set_icon(_sim_icon, theme, &"")
		return
	var marionette_count: int = 0
	var jiggle_count: int = 0
	for child: Node in sim.get_children():
		if child is JiggleBone:
			jiggle_count += 1
		elif child is MarionetteBone:
			marionette_count += 1
	_build_label.text = "Built  (%d bones + %d jiggle)" % [marionette_count, jiggle_count]
	_set_icon(_build_icon, theme, &"StatusSuccess")

	# Sim state: PhysicalBoneSimulator3D.is_simulating_physics() reports
	# whether physical_bones_start_simulation has been called and not yet
	# stopped. Falls back to a get-method probe for older Godot 4.x where
	# the API name differed.
	var sim_running: bool = false
	if sim.has_method(&"is_simulating_physics"):
		sim_running = sim.is_simulating_physics()
	if sim_running:
		_sim_label.text = "Sim running"
		_set_icon(_sim_icon, theme, &"PlayStart")
	else:
		_sim_label.text = "Sim stopped"
		_set_icon(_sim_icon, theme, &"Stop")


func _set_icon(rect: TextureRect, theme: Theme, icon_name: StringName) -> void:
	if theme == null or icon_name == &"":
		rect.texture = null
		return
	if not theme.has_icon(icon_name, &"EditorIcons"):
		rect.texture = null
		return
	rect.texture = theme.get_icon(icon_name, &"EditorIcons")
