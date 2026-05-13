class_name BodyFieldGizmo
extends MeshInstance3D

## Sanity gizmo for B1: shows the rest-pose tet wireframe + a sample of
## render-vert → containing-tet-centroid lines, colored by barycentric
## tet ownership and dimmed by render_influence.
##
## Built once on set_flesh_data() — never rebuilt per-frame. Implemented as
## a child MeshInstance3D + ImmediateMesh (NOT an EditorNode3DGizmoPlugin —
## the plugin path's _redraw drops frames during continuous input, see
## memory `reference_godot_tool_gizmo_redraw.md`).

# Cap render-vert ownership samples so dense meshes (kasumi ~tens of
# thousands of verts) don't drown the gizmo in lines. Even-spaced subsample.
const _MAX_OWNERSHIP_SAMPLES: int = 5000
const _OWNERSHIP_DOWNSAMPLE_THRESHOLD: int = 50000

const _TET_WIRE_COLOR := Color(0.3, 0.8, 0.9, 0.18)

var _flesh_data: FleshData = null
var _material: StandardMaterial3D = null


func _ready() -> void:
	# Single shared unshaded vertex-color material. Allocated once.
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.vertex_color_use_as_albedo = true
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material_override = _material
	if _flesh_data != null:
		_rebuild()


func set_flesh_data(data: FleshData) -> void:
	_flesh_data = data
	if is_inside_tree():
		_rebuild()


func _rebuild() -> void:
	var im := ImmediateMesh.new()
	mesh = im
	if _flesh_data == null:
		return

	# --- Tet wireframe (6 edges per tet, PRIMITIVE_LINES) ----------------
	var tet_cells := _flesh_data.tet_cells
	var tet_verts := _flesh_data.tet_verts
	var n_tets := _flesh_data.n_tet_cells
	if n_tets > 0 and tet_cells.size() >= n_tets * 4 and tet_verts.size() >= _flesh_data.n_tet_verts * 3:
		im.surface_begin(Mesh.PRIMITIVE_LINES)
		var edges := [
			[0, 1], [0, 2], [0, 3],
			[1, 2], [1, 3], [2, 3],
		]
		for t in range(n_tets):
			var base := t * 4
			var i0 := tet_cells[base + 0]
			var i1 := tet_cells[base + 1]
			var i2 := tet_cells[base + 2]
			var i3 := tet_cells[base + 3]
			var corners := [
				_vert(tet_verts, i0),
				_vert(tet_verts, i1),
				_vert(tet_verts, i2),
				_vert(tet_verts, i3),
			]
			im.surface_set_color(_TET_WIRE_COLOR)
			for e in edges:
				im.surface_add_vertex(corners[e[0]])
				im.surface_add_vertex(corners[e[1]])
		im.surface_end()

	# --- Render-vert ownership lines -------------------------------------
	# Line from each (sampled) render vert to its tet's centroid. Color
	# from hash(tet_idx), alpha-weighted by render_influence.
	var nr := _flesh_data.n_render_verts
	var bary_tet_idx := _flesh_data.bary_tet_idx
	var bary_uvw := _flesh_data.bary_uvw
	var influence := _flesh_data.render_influence
	if nr > 0 and bary_tet_idx.size() >= nr and bary_uvw.size() >= nr * 3 and influence.size() >= nr:
		var stride := 1
		var sample_count := nr
		if nr > _OWNERSHIP_DOWNSAMPLE_THRESHOLD:
			stride = max(1, nr / _MAX_OWNERSHIP_SAMPLES)
			sample_count = nr / stride

		# ImmediateMesh.surface_end() errors if no vertices were added.
		# Guard the empty case (e.g. all skipped on bad indices).
		if sample_count > 0:
			im.surface_begin(Mesh.PRIMITIVE_LINES)
			var any_vertex := false
			var i := 0
			while i < nr:
				var ti := bary_tet_idx[i]
				if ti >= 0 and ti < n_tets:
					var c_base := ti * 4
					var v0 := _vert(tet_verts, tet_cells[c_base + 0])
					var v1 := _vert(tet_verts, tet_cells[c_base + 1])
					var v2 := _vert(tet_verts, tet_cells[c_base + 2])
					var v3 := _vert(tet_verts, tet_cells[c_base + 3])
					var u := bary_uvw[i * 3 + 0]
					var v := bary_uvw[i * 3 + 1]
					var w := bary_uvw[i * 3 + 2]
					var x := 1.0 - u - v - w
					var p := v0 * u + v1 * v + v2 * w + v3 * x
					var centroid := (v0 + v1 + v2 + v3) * 0.25

					var h := hash(ti) & 0xFFFFFF
					var r := float((h >> 16) & 0xFF) / 255.0
					var g := float((h >> 8) & 0xFF) / 255.0
					var b := float(h & 0xFF) / 255.0
					var inf := clampf(influence[i], 0.0, 1.0)
					var col := Color(r, g, b, 0.25 + 0.55 * inf)
					# Scale RGB by influence too, so low-influence dims out.
					col.r *= inf
					col.g *= inf
					col.b *= inf

					im.surface_set_color(col)
					im.surface_add_vertex(p)
					im.surface_add_vertex(centroid)
					any_vertex = true
				i += stride

			if any_vertex:
				im.surface_end()
			else:
				# Discard the open surface — no API to cancel cleanly, so
				# add a degenerate vertex pair at origin with zero alpha
				# rather than crashing on empty surface_end.
				im.surface_set_color(Color(0, 0, 0, 0))
				im.surface_add_vertex(Vector3.ZERO)
				im.surface_add_vertex(Vector3.ZERO)
				im.surface_end()


static func _vert(arr: PackedFloat32Array, idx: int) -> Vector3:
	var base := idx * 3
	return Vector3(arr[base], arr[base + 1], arr[base + 2])
