extends SceneTree

# Headless-ish screenshot of more_eyes.tscn. Run with:
#   godot --path game --rendering-driver vulkan --quit-after 8 \
#       --script res://dev/eye_screenshot.gd
#
# Saves to res://assets/materials/eye/debug/auto_more_eyes.png. Needs a display
# server because Godot's renderer can't run truly headless; X/Wayland is fine.

const SCENE := "res://assets/materials/eye/more_eyes.tscn"
const OUT := "res://assets/materials/eye/debug/auto_more_eyes.png"

# Camera node name in more_eyes.tscn. "Front" or "Side" — the user placed
# both with carefully chosen angles, so we activate one of theirs instead
# of building a new camera here.
const CAMERA := "Side"

# 0=normal, 1=position, 2=iris UV, 3=sclera UV, 4=surface mask, 5=lambert.
@warning_ignore("unused_parameter")
const DEBUG_MODE := 0

var _frames := 0
var _saved := false


func _init() -> void:
	var packed := ResourceLoader.load(SCENE) as PackedScene
	if packed == null:
		push_error("[FAIL] cannot load %s" % SCENE)
		quit(1)
		return
	var inst := packed.instantiate()
	root.add_child(inst)
	# Override debug_mode on the eye material if requested.
	var mat := load("res://assets/materials/eye/eye_material.tres") as ShaderMaterial
	if mat != null:
		if DEBUG_MODE != 0:
			mat.set_shader_parameter("debug_mode", DEBUG_MODE)
		# Optional per-run overrides via OS env so we can reproduce specific
		# test cases without editing the .tres.
		var pupil_override := OS.get_environment("EYE_PUPIL_RADIUS")
		if pupil_override != "":
			mat.set_shader_parameter("pupil_radius", float(pupil_override))
		var iris_override := OS.get_environment("EYE_IRIS_RADIUS")
		if iris_override != "":
			mat.set_shader_parameter("iris_radius", float(iris_override))
	# Activate one of the user-placed scene cameras instead of building a
	# fresh one — the Front/Side angles are tuned by hand and we should
	# render through those.
	var cam := inst.find_child(CAMERA, true, false) as Camera3D
	if cam == null:
		push_error("[FAIL] camera '%s' not found under scene root" % CAMERA)
		quit(1)
		return
	cam.current = true
	process_frame.connect(_on_frame)


func _on_frame() -> void:
	_frames += 1
	if _frames < 4 or _saved:
		return
	var img := root.get_texture().get_image()
	if img == null:
		push_error("[FAIL] viewport image is null")
		quit(1)
		return
	var err := img.save_png(OUT)
	if err != OK:
		push_error("[FAIL] save_png: %s" % err)
		quit(1)
		return
	print("[PASS] saved %s (%dx%d)" % [OUT, img.get_width(), img.get_height()])
	_saved = true
	quit(0)
