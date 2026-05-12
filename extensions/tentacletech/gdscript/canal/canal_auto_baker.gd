@tool
class_name CanalAutoBaker
extends RefCounted

## Bake-time pass that fills a `Canal` node's substrate from
## authored data per `TentacleTech_Architecture.md` §10.6 steps 6-10:
##
##   6. Catmull spline from `<spline_cp_bone_prefix>_*` skeleton bones.
##   7. Per-cell rest_radius via perpendicular raycasts from the
##      spline to canal interior mesh triangles.
##   8. `tunnel_state` RGBA32F texture allocation + R-channel seed
##      from per-cell rest_radius (GBA = 0, 0, 1.0).
##   9. Centerline particle chain rest positions sampled uniformly in
##      arc-length along the spline + proximal/distal anchor
##      resolution (entry orifice / exit orifice / TerminalPin).
##   10. Per canal interior vert (CUSTOM0.r ≥ 1, matching canal_id+1):
##       bake (s, θ, rest_radius_at_vert) into CUSTOM1.rgb,
##       rest_outward_normal (in canal-local frame) into CUSTOM2.rgb.
##
## **OrificeAutoBaker note (2026-05-12):** the architecture doc §10.4
## describes an OrificeAutoBaker that hasn't been implemented yet.
## This class is a sibling — `CanalAutoBaker` stands alone, no
## inheritance, no shared base. When the OrificeAutoBaker lands
## (verification + ring-table population for rim anchors), a thin
## hero-level `HeroAutoBaker.bake(hero)` can chain both bakers; no
## refactor of this class needed.
##
## **Reimport gotcha** (`reference_godot_import_reimport.md`): step
## 10 writes per-vert custom attributes to the MeshInstance3D's mesh
## in memory. For the values to persist, the user must click
## "Reimport" in the FileSystem dock after the bake runs. The bake
## surfaces a clear print_rich message at completion.

const _AVERAGE_COMBINE_MODE := 0  # CanalConstrictionZone friction_combine default


# ─── Entry point ───────────────────────────────────────────────────

## Run all five bake steps in order against `p_canal`, populating its
## baked substrate fields. Returns true on success, false if a fatal
## prerequisite failed (no CP bones, missing skeleton, etc.) — in
## that case the Canal node is left in whatever partial state the
## bake reached so the gizmo overlay can show what worked.
static func bake(
		p_canal: Canal,
		p_mesh_instance: MeshInstance3D,
		p_skeleton: Skeleton3D,
		p_canal_id: int,
		p_orifices_root: Node = null) -> bool:
	if p_canal == null or p_canal.canal_parameters == null:
		push_error("CanalAutoBaker.bake: canal or canal_parameters is null")
		return false
	if p_skeleton == null:
		push_error("CanalAutoBaker.bake: skeleton is null")
		return false

	p_canal.set_canal_id(p_canal_id)
	var params: CanalParameters = p_canal.canal_parameters

	# Step 6 — Catmull spline from CP bones.
	var spline := build_spline_from_cp_bones(p_skeleton, String(params.spline_cp_bone_prefix))
	if spline == null:
		push_error("CanalAutoBaker.bake: failed to derive spline for canal '%s'" % params.canal_name)
		return false
	p_canal._set_baked_spline(spline)

	# Step 7 — Per-cell rest_radius.
	var rest_radius := compute_per_cell_rest_radius(
			spline, params, p_mesh_instance, p_canal_id)
	p_canal._set_baked_rest_radius_per_cell(rest_radius)

	# Step 8 — tunnel_state RGBA32F texture.
	var tex := allocate_tunnel_state_texture(params, rest_radius)
	p_canal._set_baked_tunnel_state_texture(tex)

	# Step 9 — centerline chain rest positions + anchors.
	var chain := allocate_centerline_chain(
			spline, params, p_skeleton, p_orifices_root)
	p_canal._set_baked_centerline_rest_positions(chain["positions"])
	p_canal._set_baked_anchors(chain["proximal"], chain["distal"])

	# Step 10 — per-vert (s, θ, rest_radius, rest_outward_normal) bake.
	var vert_count := bake_canal_interior_verts(
			p_mesh_instance, p_canal_id, spline)

	print_rich("[color=cyan]CanalAutoBaker[/color] canal='%s' canal_id=%d: "
			% [params.canal_name, p_canal_id]
			+ "spline_cp=%d cells=%d×%d centerline=%d verts_baked=%d. "
			% [spline.get_point_count(),
				params.canal_axial_segments, params.canal_angular_sectors,
				params.centerline_particle_count, vert_count]
			+ "[color=yellow]Click Reimport in FileSystem to persist per-vert CUSTOM1/CUSTOM2.[/color]")
	return true


# ─── Step 6 — Catmull spline from CP bones ─────────────────────────

## Scans `skeleton` for bones whose name matches `<prefix>_<int>`
## (e.g. "Vag_CP_0", "Vag_CP_1", ...). Returns a CatmullSpline built
## from their world-space heads in numeric-suffix order. Returns null
## if fewer than 2 matching bones are found.
##
## `prefix` is the authoring prefix from `CanalParameters.spline_cp_bone_prefix`
## (e.g. "Vag_CP"). The bone suffix is whatever follows
## `prefix + "_"`; the trailing characters must parse as an int.
static func build_spline_from_cp_bones(
		p_skeleton: Skeleton3D,
		p_prefix: String) -> RefCounted:
	if p_prefix.is_empty():
		push_error("CanalAutoBaker: spline_cp_bone_prefix is empty")
		return null
	var collected: Array = []
	var prefix_with_sep := p_prefix + "_"
	var bone_count := p_skeleton.get_bone_count()
	for i in bone_count:
		var bone_name := p_skeleton.get_bone_name(i)
		if not bone_name.begins_with(prefix_with_sep):
			continue
		var suffix := bone_name.substr(prefix_with_sep.length())
		if not suffix.is_valid_int():
			continue
		collected.append({"idx": int(suffix), "bone_id": i})
	if collected.size() < 2:
		push_error("CanalAutoBaker: need ≥ 2 CP bones with prefix '%s' (found %d)"
				% [p_prefix, collected.size()])
		return null
	collected.sort_custom(func(a, b): return a["idx"] < b["idx"])

	var points := PackedVector3Array()
	points.resize(collected.size())
	var skel_xform: Transform3D = p_skeleton.global_transform
	for i in collected.size():
		var bone_id: int = collected[i]["bone_id"]
		var bone_pose: Transform3D = p_skeleton.get_bone_global_pose(bone_id)
		points[i] = skel_xform * bone_pose.origin

	if not ClassDB.class_exists("CatmullSpline"):
		push_error("CanalAutoBaker: CatmullSpline class not registered (tentacletech extension not loaded)")
		return null
	var spline: RefCounted = ClassDB.instantiate("CatmullSpline")
	spline.build_from_points(points)
	return spline


# ─── Step 7 — Per-cell rest_radius via perpendicular raycasts ──────

## For each cell (s_k, θ_j) in the (axial × angular) grid, cast a
## ray from the spline at s_k outward in angular direction θ_j and
## record the distance to the canal interior mesh wall. Returns a
## row-major flat array, indexed as `k * angular_sectors + j`.
##
## Ray miss → falls back to `params.rest_radius_profile.sample(s_norm)`
## when set, else 0.05 m. Simple single-ray-per-cell sampling — if
## tessellation noise becomes a problem in production, switch to a
## multi-ray average (per the prompt's "don't over-engineer" note).
static func compute_per_cell_rest_radius(
		p_spline: RefCounted,
		p_params: CanalParameters,
		p_mesh_instance: MeshInstance3D,
		p_canal_id: int) -> PackedFloat32Array:
	var axial: int = p_params.canal_axial_segments
	var sectors: int = p_params.canal_angular_sectors
	var out := PackedFloat32Array()
	out.resize(axial * sectors)

	var canal_tris := _gather_canal_interior_triangles(p_mesh_instance, p_canal_id)
	if canal_tris.is_empty():
		# No tagged canal triangles — fall back to rest_radius_profile for every cell.
		for k in axial:
			var s_norm := float(k) / maxf(float(axial - 1), 1.0)
			var r := _sample_fallback_radius(p_params, s_norm)
			for j in sectors:
				out[k * sectors + j] = r
		return out

	var arc: float = p_spline.get_arc_length()
	var max_ray := 10.0  # generous outward search; canals are <<1 m typically
	for k in axial:
		var s_norm := float(k) / maxf(float(axial - 1), 1.0)
		var s := s_norm * arc
		var t: float = p_spline.distance_to_parameter(s)
		var origin: Vector3 = p_spline.evaluate_position(t)
		var frame: Dictionary = p_spline.evaluate_frame(t)
		var normal_axis: Vector3 = (frame["normal"] as Vector3).normalized()
		var binormal_axis: Vector3 = (frame["binormal"] as Vector3).normalized()

		for j in sectors:
			var theta := TAU * float(j) / float(sectors)
			var outward := normal_axis * cos(theta) + binormal_axis * sin(theta)
			var ray_to := origin + outward * max_ray
			var best_dist := INF
			for tri in canal_tris:
				var hit = Geometry3D.segment_intersects_triangle(
						origin, ray_to, tri[0], tri[1], tri[2])
				if hit != null:
					var d := (hit as Vector3 - origin).length()
					if d < best_dist:
						best_dist = d
			if is_inf(best_dist):
				best_dist = _sample_fallback_radius(p_params, s_norm)
			out[k * sectors + j] = best_dist
	return out


static func _sample_fallback_radius(p_params: CanalParameters, p_s_norm: float) -> float:
	if p_params.rest_radius_profile != null:
		return p_params.rest_radius_profile.sample(p_s_norm)
	return 0.05  # safe default when no profile authored


## Collect canal-interior triangles from `mesh_instance`'s surfaces.
## A triangle is "canal interior" iff ALL THREE of its vertices have
## `CUSTOM0.r == canal_id + 1`. Returned as an Array of
## `[Vector3, Vector3, Vector3]` triples in world space.
##
## Reads the mesh via `surface_get_arrays()`; works for ArrayMesh
## (synthetic test meshes built in GDScript) and for ArrayMesh produced
## by Godot's GLB importer (production-time path). Custom format
## bookkeeping is read off `surface_get_format()` so the helper
## handles RGBA-Float CUSTOMs (4 floats per vert, stride 16 bytes via
## PackedFloat32Array of length n×4).
static func _gather_canal_interior_triangles(
		p_mesh_instance: MeshInstance3D,
		p_canal_id: int) -> Array:
	var result: Array = []
	if p_mesh_instance == null or p_mesh_instance.mesh == null:
		return result
	var mesh: Mesh = p_mesh_instance.mesh
	var xform: Transform3D = p_mesh_instance.global_transform
	var target: float = float(p_canal_id + 1)

	for surface_idx in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(surface_idx)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var c0: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
		if c0.is_empty():
			# Surface doesn't carry CUSTOM0 — not a canal surface.
			continue
		# Determine floats-per-vertex for CUSTOM0 from the surface format.
		var floats_per_vert: int = _custom0_floats_per_vert(mesh, surface_idx, verts.size(), c0.size())
		if floats_per_vert <= 0:
			continue

		var v_count := verts.size()
		var i_count := indices.size()
		# Helper: tri-by-vertex match — all three verts must be tagged.
		if i_count > 0:
			var tri_count := i_count / 3
			for t in tri_count:
				var i0 := indices[t * 3 + 0]
				var i1 := indices[t * 3 + 1]
				var i2 := indices[t * 3 + 2]
				if _vert_in_canal(c0, i0, floats_per_vert, target) \
						and _vert_in_canal(c0, i1, floats_per_vert, target) \
						and _vert_in_canal(c0, i2, floats_per_vert, target):
					result.append([xform * verts[i0], xform * verts[i1], xform * verts[i2]])
		else:
			# Non-indexed: every 3 verts form a tri.
			var tri_count := v_count / 3
			for t in tri_count:
				var i0 := t * 3 + 0
				var i1 := t * 3 + 1
				var i2 := t * 3 + 2
				if _vert_in_canal(c0, i0, floats_per_vert, target) \
						and _vert_in_canal(c0, i1, floats_per_vert, target) \
						and _vert_in_canal(c0, i2, floats_per_vert, target):
					result.append([xform * verts[i0], xform * verts[i1], xform * verts[i2]])
	return result


static func _vert_in_canal(p_c0: PackedFloat32Array, p_vert_idx: int,
		p_floats_per_vert: int, p_target: float) -> bool:
	var base := p_vert_idx * p_floats_per_vert
	if base >= p_c0.size():
		return false
	return absf(p_c0[base] - p_target) < 0.5


# Derive floats-per-vertex for CUSTOM0 by dividing the array length
# by the vertex count. Godot 4.6 packs CUSTOM_RGBA_FLOAT as 4 floats
# per vert; smaller formats (RGB_FLOAT etc.) yield 3 or fewer. We
# infer rather than parse the format bits to keep the helper resilient
# across Godot point releases.
static func _custom0_floats_per_vert(p_mesh: Mesh, p_surface_idx: int,
		p_vert_count: int, p_custom0_total_floats: int) -> int:
	if p_vert_count <= 0:
		return 0
	var fpv := p_custom0_total_floats / p_vert_count
	if fpv < 1 or fpv > 4:
		return 0
	return fpv


# ─── Step 8 — tunnel_state RGBA32F texture allocation ──────────────

## Allocate the (axial × angular) RGBAF image and seed each cell with
## `(rest_radius, 0, 0, 1.0)`. R-channel = dynamic_wall_radius;
## G-channel = plastic_offset; B-channel = damage (or velocity,
## per `fourth_channel_mode`); A-channel intentionally 1.0 as a
## diagnostic constant for the placeholder.
##
## Note on texture coordinate mapping: width = axial_segments (s_k),
## height = angular_sectors (θ_j). Vertex shader sample uses
## `(s_norm, theta_norm)` → texture(t, vec2(s_norm, theta_norm)).
static func allocate_tunnel_state_texture(
		p_params: CanalParameters,
		p_rest_radius_per_cell: PackedFloat32Array) -> ImageTexture:
	var axial: int = p_params.canal_axial_segments
	var sectors: int = p_params.canal_angular_sectors
	var img := Image.create(axial, sectors, false, Image.FORMAT_RGBAF)
	for k in axial:
		for j in sectors:
			var r: float = p_rest_radius_per_cell[k * sectors + j]
			img.set_pixel(k, j, Color(r, 0.0, 0.0, 1.0))
	return ImageTexture.create_from_image(img)


# ─── Step 9 — Centerline chain rest positions + anchor resolution ──

## Allocate the M centerline particle rest positions along the spline
## at uniform arc-length spacing, plus resolve the proximal/distal
## anchor world positions per `CanalParameters`.
##
## Returns a Dictionary { "positions": PackedVector3Array,
##                        "proximal": Vector3,
##                        "distal":   Vector3 }
static func allocate_centerline_chain(
		p_spline: RefCounted,
		p_params: CanalParameters,
		p_skeleton: Skeleton3D,
		p_orifices_root: Node = null) -> Dictionary:
	var m: int = p_params.centerline_particle_count
	if m < 2:
		m = 2
	var positions := PackedVector3Array()
	positions.resize(m)
	var arc: float = p_spline.get_arc_length()
	for i in m:
		var s := arc * float(i) / float(m - 1)
		var t: float = p_spline.distance_to_parameter(s)
		positions[i] = p_spline.evaluate_position(t)

	var proximal := _resolve_proximal_anchor(p_params, p_orifices_root, positions[0])
	var distal := _resolve_distal_anchor(p_params, p_skeleton, p_orifices_root, positions[m - 1])
	return {"positions": positions, "proximal": proximal, "distal": distal}


# Proximal anchor: entry orifice's Center frame world origin if
# resolvable; otherwise the spline's start position (fallback when
# `entry_orifice_path` is empty — useful for closed-terminal sacs
# that have no entry orifice authored).
static func _resolve_proximal_anchor(
		p_params: CanalParameters,
		p_orifices_root: Node,
		p_fallback: Vector3) -> Vector3:
	if p_orifices_root == null or p_params.entry_orifice_path.is_empty():
		return p_fallback
	var entry: Node = p_orifices_root.get_node_or_null(p_params.entry_orifice_path)
	if entry == null:
		return p_fallback
	# Orifices expose `get_center_frame_world()` per slice 5B; use it
	# when available, otherwise fall back to the orifice's own global
	# transform origin.
	if entry.has_method("get_center_frame_world"):
		var xf: Transform3D = entry.call("get_center_frame_world")
		return xf.origin
	if entry is Node3D:
		return (entry as Node3D).global_position
	return p_fallback


# Distal anchor (§6.12.11 + brief):
#   open canals    → exit_orifice_path's Center frame
#   closed sacs    → <canal_name>_TerminalPin bone, if it resolves
#                  → fall back to terminal_position_in_host_frame
#   if all fail    → error visibly + return spline endpoint
static func _resolve_distal_anchor(
		p_params: CanalParameters,
		p_skeleton: Skeleton3D,
		p_orifices_root: Node,
		p_fallback: Vector3) -> Vector3:
	if not p_params.closed_terminal:
		if p_orifices_root != null and not p_params.exit_orifice_path.is_empty():
			var exit: Node = p_orifices_root.get_node_or_null(p_params.exit_orifice_path)
			if exit != null:
				if exit.has_method("get_center_frame_world"):
					var xf: Transform3D = exit.call("get_center_frame_world")
					return xf.origin
				if exit is Node3D:
					return (exit as Node3D).global_position
		push_warning("CanalAutoBaker: open canal '%s' has no resolvable exit_orifice_path; using spline endpoint as distal anchor"
				% String(p_params.canal_name))
		return p_fallback

	# Closed terminal — try TerminalPin bone first.
	if not p_params.terminal_pin_bone.is_empty() and p_skeleton != null:
		var bone_idx := p_skeleton.find_bone(String(p_params.terminal_pin_bone))
		if bone_idx >= 0:
			var pose: Transform3D = p_skeleton.get_bone_global_pose(bone_idx)
			return p_skeleton.global_transform * pose.origin
	# Fall back to host-frame position.
	if p_skeleton != null:
		return p_skeleton.global_transform * p_params.terminal_position_in_host_frame
	return p_params.terminal_position_in_host_frame


# ─── Step 10 — Per-vert (s, θ, rest_radius, rest_outward_normal) ────

## Walks every canal-interior vert in `mesh_instance` (where
## `CUSTOM0.r == canal_id + 1`), projects each onto the rest spline,
## and writes the resulting (s, θ, rest_radius_at_vert) into CUSTOM1.rgb
## + the rest-canal-local outward normal into CUSTOM2.rgb. Returns the
## total vert count baked.
##
## Projection: brute-force sample the spline at N coarse t values to
## find the nearest neighbourhood, then refine via 3 golden-section
## iterations. Sub-millisecond per vert at typical mesh density.
##
## Normal decomposition: vert normal in WORLD space, mapped through
## the spline frame inverse (= transpose for orthonormal frame) to
## canal-local coords. The shader uses this in §6.12.5's
## `deformed_basis * inverse(rest_basis_at_s) * rest_normal`.
##
## CUSTOM2.a is left untouched (the optional rim-blend factor from
## §10.4 step 12; not authored by AutoBaker).
static func bake_canal_interior_verts(
		p_mesh_instance: MeshInstance3D,
		p_canal_id: int,
		p_spline: RefCounted) -> int:
	if p_mesh_instance == null or p_mesh_instance.mesh == null:
		return 0
	var mesh: Mesh = p_mesh_instance.mesh
	if not (mesh is ArrayMesh):
		push_warning("CanalAutoBaker.step10: mesh is not ArrayMesh — write-back skipped. "
				+ "Reimport with 'Save Imported as ArrayMesh' or convert at scene init.")
		return 0
	var array_mesh: ArrayMesh = mesh
	var xform: Transform3D = p_mesh_instance.global_transform
	var inv_xform: Transform3D = xform.affine_inverse()
	var target: float = float(p_canal_id + 1)
	var total_baked := 0

	# Two-pass rebuild: first pass reads + mutates all surfaces into a
	# stash, second pass clear_surfaces() once + re-adds all. The
	# single-pass clear-and-readd inside the loop drops surfaces 1..N-1
	# on the first iter's clear_surfaces(); the snapshot of
	# surface_count then walks past the truncated end and the remaining
	# canal verts on later surfaces vanish (multi-surface hero meshes
	# per §10.4 have skin + N mucosa surfaces, so this matters).
	var surface_count := array_mesh.get_surface_count()
	var collected: Array = []
	for surface_idx in surface_count:
		var arrays: Array = array_mesh.surface_get_arrays(surface_idx)
		var fmt: int = array_mesh.surface_get_format(surface_idx)
		var primitive := array_mesh.surface_get_primitive_type(surface_idx)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var c0: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
		var c1: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM1]
		var c2: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM2]
		var surface_baked := 0

		# Surfaces without CUSTOM0 (skin / exterior) pass through unmodified;
		# we still need to re-add them so the surface list survives the
		# clear_surfaces() in the second pass.
		var fpv: int = 0
		if not c0.is_empty():
			fpv = _custom0_floats_per_vert(array_mesh, surface_idx, verts.size(), c0.size())

		if fpv > 0:
			# Ensure CUSTOM1 + CUSTOM2 exist at RGBA-float layout (4 floats per vert).
			var fpv1 := 4
			if c1.is_empty():
				c1 = PackedFloat32Array()
				c1.resize(verts.size() * fpv1)
			else:
				# trust existing layout; same fpv assumption as CUSTOM0 derivation
				fpv1 = c1.size() / verts.size()
			var fpv2 := 4
			if c2.is_empty():
				c2 = PackedFloat32Array()
				c2.resize(verts.size() * fpv2)
			else:
				fpv2 = c2.size() / verts.size()

			for v_idx in verts.size():
				if not _vert_in_canal(c0, v_idx, fpv, target):
					continue
				# vert in world space (for projection consistency with step 7's rays)
				var v_world: Vector3 = xform * verts[v_idx]
				var n_world: Vector3
				if v_idx < normals.size():
					n_world = (xform.basis * normals[v_idx]).normalized()
				else:
					n_world = Vector3.UP
				var proj := _project_onto_spline(p_spline, v_world)
				var s: float = proj["s"]
				var theta: float = proj["theta"]
				var rest_r: float = proj["rest_radius"]
				var rest_basis: Basis = proj["rest_basis"]
				# rest_outward_normal in canal-local frame = transpose(basis) × world_normal
				var canal_local_n: Vector3 = rest_basis.transposed() * n_world
				c1[v_idx * fpv1 + 0] = s
				c1[v_idx * fpv1 + 1] = theta
				c1[v_idx * fpv1 + 2] = rest_r
				# leave CUSTOM1.a free for future use
				c2[v_idx * fpv2 + 0] = canal_local_n.x
				c2[v_idx * fpv2 + 1] = canal_local_n.y
				c2[v_idx * fpv2 + 2] = canal_local_n.z
				# CUSTOM2.a intentionally untouched — rim-blend factor (§10.4 step 12)
				surface_baked += 1

			arrays[Mesh.ARRAY_CUSTOM1] = c1
			arrays[Mesh.ARRAY_CUSTOM2] = c2

		collected.append({
			"arrays": arrays,
			"fmt": fmt,
			"primitive": primitive,
			"baked": surface_baked,
		})

	# Second pass: clear once, re-add all surfaces in their original
	# index order. add_surface_from_arrays takes the original format
	# flags as the fifth 'compress_flags' arg in Godot 4.6.
	array_mesh.clear_surfaces()
	for entry in collected:
		array_mesh.add_surface_from_arrays(
				entry["primitive"], entry["arrays"], [], {}, entry["fmt"])
		total_baked += entry["baked"]

	return total_baked


## Project a world-space point onto the rest spline. Returns:
##   { "s": arc length of nearest projection,
##     "theta": angular position around spline tangent at s (radians),
##     "rest_radius": perpendicular distance from spline axis,
##     "rest_basis": the spline frame (tangent, normal, binormal)
##                   as a Basis at the projection point }
##
## Strategy: coarse scan (N=64) for nearest sample, then 3 rounds of
## golden-section refinement over the bracket. Adequate for bake-time;
## not run per-frame.
static func _project_onto_spline(p_spline: RefCounted, p_world: Vector3) -> Dictionary:
	var arc: float = p_spline.get_arc_length()
	var n_samples := 64
	var best_t := 0.0
	var best_d2 := INF
	for i in n_samples:
		var t := float(i) / float(n_samples - 1)
		var p: Vector3 = p_spline.evaluate_position(t)
		var d2 := (p - p_world).length_squared()
		if d2 < best_d2:
			best_d2 = d2
			best_t = t
	# Golden-section over [best_t - h, best_t + h]
	var h := 1.0 / float(n_samples - 1)
	var lo := maxf(0.0, best_t - h)
	var hi := minf(1.0, best_t + h)
	var golden := 0.6180339887
	for iter in 12:
		var m1 := hi - golden * (hi - lo)
		var m2 := lo + golden * (hi - lo)
		var d1 := (p_spline.evaluate_position(m1) as Vector3 - p_world).length_squared()
		var d2_g := (p_spline.evaluate_position(m2) as Vector3 - p_world).length_squared()
		if d1 < d2_g:
			hi = m2
		else:
			lo = m1
	var t_final := (lo + hi) * 0.5
	var origin: Vector3 = p_spline.evaluate_position(t_final)
	var frame: Dictionary = p_spline.evaluate_frame(t_final)
	var tangent: Vector3 = (frame["tangent"] as Vector3).normalized()
	var normal: Vector3 = (frame["normal"] as Vector3).normalized()
	var binormal: Vector3 = (frame["binormal"] as Vector3).normalized()
	# rest_radius = perpendicular distance from p_world to the spline axis at t_final
	var offset := p_world - origin
	# Decompose offset into the (normal, binormal) plane
	var x := offset.dot(normal)
	var y := offset.dot(binormal)
	var theta := atan2(y, x)
	var rest_radius := sqrt(x * x + y * y)
	var s: float = p_spline.parameter_to_distance(t_final)
	# Build Basis with columns (tangent, normal, binormal) — Godot's
	# Basis(x, y, z) takes column vectors.
	var basis := Basis(tangent, normal, binormal)
	return {
		"s": s,
		"theta": theta,
		"rest_radius": rest_radius,
		"rest_basis": basis,
	}
