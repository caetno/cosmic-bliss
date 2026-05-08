extends Node3D

@onready var pupil_slider = $UI/Panel/VBoxContainer/PupilSlider
@onready var pupil_label = $UI/Panel/VBoxContainer/PupilLabel
@onready var debug_button = $UI/Panel/VBoxContainer/DebugButton
@onready var debug_label = $UI/Panel/VBoxContainer/DebugLabel

var eye_material: Material
var eye_mesh: MeshInstance3D

func _ready():
	# Find the eye mesh node (name may vary depending on FBX import)
	var eye_node = $Eye
	if eye_node:
		for child in eye_node.get_children():
			if child is MeshInstance3D:
				eye_mesh = child
				break

	if not eye_mesh:
		push_error("Could not find MeshInstance3D child under Eye node")
		return

	# Apply the eye material if not already set
	eye_material = eye_mesh.get_material_override()
	if not eye_material:
		eye_material = load("res://assets/materials/eye/eye_material.tres")
		if eye_material:
			eye_mesh.set_material_override(eye_material)

	# Signals are already connected via .tscn [connection] blocks; don't reconnect.
	# Initialize with current slider value
	_on_pupil_slider_changed(pupil_slider.value)

func _on_pupil_slider_changed(value: float):
	if not eye_material:
		return

	# Update pupil aperture in shader
	eye_material.set_shader_parameter("pupil_aperture", value)

	# Update label
	pupil_label.text = "Pupil Aperture: %.2f" % value

func _on_debug_button_toggled(button_pressed: bool):
	if not eye_material:
		return

	# Toggle debug visualization (mode 4 = surface mask coloring)
	eye_material.set_shader_parameter("debug_mode", 4 if button_pressed else 0)
	debug_label.text = "Debug Mode: %s" % ("ON" if button_pressed else "OFF")

func _process(_delta):
	# Allow keyboard control
	if Input.is_action_just_pressed("ui_up"):
		pupil_slider.value = min(pupil_slider.value + 0.05, 1.0)
	elif Input.is_action_just_pressed("ui_down"):
		pupil_slider.value = max(pupil_slider.value - 0.05, 0.0)

	# Rotate eye with mouse
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		var mouse_delta = get_viewport().get_mouse_velocity()
		if mouse_delta.length() > 0:
			$Eye.rotate_y(-mouse_delta.x * 0.01)
			$Eye.rotate_x(-mouse_delta.y * 0.01)
