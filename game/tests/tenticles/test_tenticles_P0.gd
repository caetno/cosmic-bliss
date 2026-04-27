extends Node3D

# Phase 0 visual test: bind the UdonParticleSystem's compute-written
# Texture2DRD into the quad's ShaderMaterial. The compute dispatch runs
# on the render thread; the texture's RID is populated asynchronously
# but the Texture2DRD reference handed to set_shader_parameter is stable.

@onready var system: UdonParticleSystem = $UdonParticleSystem
@onready var quad: MeshInstance3D = $Quad

func _ready() -> void:
	var mat: ShaderMaterial = quad.material_override as ShaderMaterial
	if mat == null:
		push_error("Quad has no ShaderMaterial in material_override")
		return
	mat.set_shader_parameter("tex", system.get_output_texture())
