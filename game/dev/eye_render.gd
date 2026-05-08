extends SceneTree
# Headless eye-shader iteration tool.
#
# Usage:
#   godot --path game --script dev/eye_render.gd [-- preset]
#
# Loads more_eyes.tscn (the scene the user iterates on — moreEyes.glb mesh +
# blue/orange spotlights + ShaderMaterial) and writes a screenshot to
# game/dev/render_out/<preset>.png.

const SCENE_PATH := "res://assets/materials/eye/more_eyes.tscn"
const OUT_DIR := "res://dev/render_out"
const W := 720
const H := 720

func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var args := OS.get_cmdline_user_args()
	var preset: String = args[0] if args.size() > 0 else "default"

	get_root().size = Vector2i(W, H)

	var scene: PackedScene = load(SCENE_PATH)
	var root := scene.instantiate()
	get_root().add_child(root)

	var cam := Camera3D.new()
	cam.fov = 30.0
	cam.current = true
	# Camera position presets:
	# - "saved": user's last editor viewport state (from .godot/editor/...editstate.cfg)
	# - "side":  off-axis at 0.32,0,0.62 (shows POM parallax)
	# - default: straight-on at 0,0,0.7
	var saved := preset.find("saved") != -1
	var closeup := preset.find("closeup") != -1
	var angled := preset.find("side") != -1
	if saved:
		cam.fov = 70.01
		var look_at := Vector3(0.02466584, 0.043034334, -0.08808918)
		var distance := 0.13608019
		var x_rot := -0.5025812
		var y_rot := 25.651968 - 4.0 * PI  # normalize accumulated rotation
		var basis := Basis.from_euler(Vector3(x_rot, y_rot, 0))
		var cam_pos := look_at + basis * Vector3(0, 0, distance)
		cam.transform = Transform3D(basis, cam_pos)
	elif closeup:
		# Close-up angled shot pointed at the iris area — the iris in moreEyes
		# is at world ≈ (0, 0, 0) with the cornea bulge in +Z. Camera at ~25°
		# off-axis, distance ~0.18, framing the iris large in view.
		cam.fov = 35.0
		var basis := Basis.from_euler(Vector3(-0.15, 0.45, 0))
		var cam_pos := basis * Vector3(0, 0, 0.18)
		cam.transform = Transform3D(basis, cam_pos)
	elif angled:
		cam.transform = Transform3D(Basis.IDENTITY, Vector3(0.32, 0.0, 0.62)).looking_at(Vector3.ZERO, Vector3.UP)
	else:
		cam.transform = Transform3D(Basis.IDENTITY, Vector3(0, 0, 0.7))
	root.add_child(cam)

	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.10, 0.10, 0.12)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.5, 0.5)
	env.ambient_light_energy = 0.3
	# ACES tonemap compresses bright cornea-spec highlights instead of clipping
	# them to pure white — matches what a real camera/eye would do.
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	env.tonemap_white = 6.0
	world_env.environment = env
	root.add_child(world_env)

	var eye_shell := root.find_child("EyeShell", true, false) as MeshInstance3D
	if eye_shell == null:
		push_error("EyeShell not found in " + SCENE_PATH)
		quit(1)
		return
	# Duplicate so set_shader_parameter writes hit a unique instance and
	# can't be subverted by a cached shared resource somewhere.
	var mat: ShaderMaterial = (eye_shell.material_override as ShaderMaterial).duplicate()
	if mat == null:
		push_error("EyeShell has no ShaderMaterial override")
		quit(1)
		return
	eye_shell.material_override = mat

	_apply_preset(mat, preset)
	print("[eye_render] iris_clamp_color = ", mat.get_shader_parameter("iris_clamp_color"))

	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw

	var img := get_root().get_texture().get_image()
	var path := OUT_DIR + "/" + preset + ".png"
	img.save_png(path)
	print("[eye_render] wrote ", path)
	quit()

func _apply_preset(mat: ShaderMaterial, preset: String) -> void:
	if preset == "default":
		return
	if preset == "debug5":
		mat.set_shader_parameter("debug_mode", 5)
		return
	if preset == "iris_uv":
		mat.set_shader_parameter("debug_mode", 2)
		return
	if preset == "surface_mask":
		mat.set_shader_parameter("debug_mode", 4)
		return
	if preset == "pos_n":
		mat.set_shader_parameter("debug_mode", 1)
		return
	if preset == "side_oob_debug":
		mat.set_shader_parameter("debug_mode", 6)
		return
	if preset == "closeup_high_depth":
		# Iris depth cranked high so the lens parallax / OOB rim stand out.
		mat.set_shader_parameter("iris_apparent_depth", 0.012)
		mat.set_shader_parameter("sclera_sss_strength", 0.0)
		mat.set_shader_parameter("iris_sss_strength", 0.0)
		return
	if preset == "closeup_default":
		# Default depth, no SSS — what the user sees with default settings.
		mat.set_shader_parameter("sclera_sss_strength", 0.0)
		mat.set_shader_parameter("iris_sss_strength", 0.0)
		return
	if preset == "saved_no_sss":
		mat.set_shader_parameter("sclera_sss_strength", 0.0)
		mat.set_shader_parameter("iris_sss_strength", 0.0)
		return
	if preset == "closeup_high_depth_matte":
		mat.set_shader_parameter("iris_apparent_depth", 0.012)
		mat.set_shader_parameter("sclera_sss_strength", 0.0)
		mat.set_shader_parameter("iris_sss_strength", 0.0)
		mat.set_shader_parameter("cornea_smoothness", 0.0)
		mat.set_shader_parameter("sclera_smoothness", 0.0)
		return
	if preset == "closeup_oob_debug":
		mat.set_shader_parameter("iris_apparent_depth", 0.012)
		mat.set_shader_parameter("debug_mode", 6)
		return
	if preset == "closeup_surface_mask":
		mat.set_shader_parameter("iris_apparent_depth", 0.012)
		mat.set_shader_parameter("debug_mode", 4)
		return
	if preset == "no_limbal":
		mat.set_shader_parameter("limbal_ring_intensity", 0.0)
		return
	if preset == "limbal_2":
		mat.set_shader_parameter("limbal_ring_intensity", 2.0)
		return
	if preset == "saved_limbal_crank":
		mat.set_shader_parameter("limbal_ring_size_iris", 0.7)
		mat.set_shader_parameter("limbal_ring_intensity", 2.0)
		return
	if preset == "saved_clamp_red" or preset == "side_clamp_red":
		mat.set_shader_parameter("iris_clamp_color", Color(1, 0, 0, 1))
		return
	if preset == "side_limbal_crank":
		mat.set_shader_parameter("limbal_ring_size_iris", 0.7)
		mat.set_shader_parameter("limbal_ring_intensity", 2.0)
		return
	if preset.begins_with("iris_norm_"):
		var v := preset.trim_prefix("iris_norm_").to_float()
		mat.set_shader_parameter("iris_normal_strength", v)
		return
	# pom_<N> or side_pom_<N>
	var p := preset.trim_prefix("side_") if preset.begins_with("side_") else preset
	if p.begins_with("pom_"):
		var v := p.trim_prefix("pom_").to_float()
		mat.set_shader_parameter("iris_pom_depth", v)
		return
	if preset == "side":
		return  # angled camera, default material
	if preset.begins_with("limbal_sclera_"):
		var v := preset.trim_prefix("limbal_sclera_").to_float()
		mat.set_shader_parameter("limbal_ring_size_sclera", v)
		return
	if preset.begins_with("pupil_"):
		var v := preset.trim_prefix("pupil_").to_float()
		mat.set_shader_parameter("pupil_aperture", v)
		return
	push_warning("unknown preset: " + preset)
