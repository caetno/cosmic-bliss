@tool
extends MeshInstance3D
## Slice 5H — feature silhouette debug overlay. Pulls (s, θ) samples
## from `Tentacle.sample_feature_silhouette` and draws short radial
## lines around each rim particle of the body, color-coded:
##   green  — outward perturbation (warts, knots, fins)
##   magenta — inward perturbation (sucker pits, ribs)
##
## Toggleable via the parent overlay's `show_feature_silhouette` flag.
## Pull-from-snapshot — the C++ Tentacle does not know this overlay
## exists.

# How many particles along the chain to sample. Capped to particle count.
const AXIAL_SAMPLES := 16
# How many θ samples around each particle. Should be ≤ angular resolution
# (16) of the silhouette image so we don't blur features.
const ANGULAR_SAMPLES := 16
# Bar length scale: 0.5 means a 1 cm perturbation draws as a 0.5 cm
# visible line. Tweak per scenario.
const BAR_SCALE := 0.5
# Threshold below which we skip drawing — keeps a clean smooth-girth
# tentacle from drawing noise lines.
const VISIBLE_THRESHOLD := 0.0005

const POSITIVE_COLOR := Color(0.4, 1.0, 0.4, 0.95)
const NEGATIVE_COLOR := Color(1.0, 0.3, 1.0, 0.95)

var _imesh: ImmediateMesh
var _material: StandardMaterial3D


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


func update_from(p_tentacle: Node3D) -> void:
	_imesh.clear_surfaces()
	if p_tentacle == null:
		return
	# Cheap probe: skip if the tentacle has no silhouette texture set.
	if not p_tentacle.has_method("get_feature_silhouette"):
		return
	var sil: Variant = p_tentacle.call(&"get_feature_silhouette")
	if sil == null:
		return
	# Convert world-space tentacle particle positions to layer-local.
	var inv: Transform3D = global_transform.affine_inverse()
	var positions: PackedVector3Array = p_tentacle.call(&"get_particle_positions")
	var n: int = positions.size()
	if n < 2:
		return
	# Total chain rest length for s-normalization.
	var total: float = 0.0
	if p_tentacle.has_method("get_total_chain_arc_length"):
		total = float(p_tentacle.call(&"get_total_chain_arc_length"))
	if total <= 1e-6:
		return

	_imesh.surface_begin(Mesh.PRIMITIVE_LINES)
	var step: int = max(1, int(round(float(n) / float(AXIAL_SAMPLES))))
	for i in range(0, n, step):
		var p_world: Vector3 = positions[i]
		var p_local: Vector3 = inv * p_world
		var s_norm: float = float(i) / float(n - 1)
		# Tangent estimate at this particle (for the orthonormal basis
		# we draw radial lines around).
		var tangent: Vector3
		if i + 1 < n:
			tangent = positions[i + 1] - positions[i]
		else:
			tangent = positions[i] - positions[i - 1]
		if tangent.length_squared() < 1e-10:
			continue
		tangent = tangent.normalized()
		# Stable bitangent: project +X perpendicular to tangent; fall
		# back to +Y if tangent ‖ +X.
		var ref_x := Vector3(1, 0, 0)
		if absf(tangent.dot(ref_x)) > 0.9:
			ref_x = Vector3(0, 1, 0)
		var bitangent: Vector3 = (ref_x - tangent * ref_x.dot(tangent)).normalized()
		var binormal: Vector3 = tangent.cross(bitangent).normalized()
		for j in ANGULAR_SAMPLES:
			var theta: float = TAU * float(j) / float(ANGULAR_SAMPLES)
			var perturbation: float = float(p_tentacle.call(
					&"sample_feature_silhouette", s_norm, theta))
			if absf(perturbation) < VISIBLE_THRESHOLD:
				continue
			var radial: Vector3 = bitangent * cos(theta) + binormal * sin(theta)
			var bar_len: float = perturbation * BAR_SCALE
			var color: Color = POSITIVE_COLOR if perturbation > 0.0 else NEGATIVE_COLOR
			# Convert world-space radial endpoint to layer-local.
			var end_world: Vector3 = p_world + radial * bar_len
			_imesh.surface_set_color(color)
			_imesh.surface_add_vertex(p_local)
			_imesh.surface_set_color(color)
			_imesh.surface_add_vertex(inv * end_world)
	_imesh.surface_end()
