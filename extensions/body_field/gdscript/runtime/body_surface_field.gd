@tool
class_name BodySurfaceField
extends Node3D

## Per-hero body surface field. Owns a cotan-Laplacian factor on the
## hero's body surface mesh + a list of `SurfaceAttachment` resources
## whose per-vertex weights are baked from diffusing source signals
## across the surface.
##
## Sibling to `BodyField` inside the body_field extension per §17 (the
## tet substrate is §18). The two share the body mesh source and the
## hero-load bake step; when both ship, they share the cotan-Laplacian
## machinery (this module for §17, future §18 amendment 1 for tets).
##
## §17.1 ships infrastructure only:
##   - Cotan-Laplacian + dense Cholesky factorization.
##   - `BodySurfaceField` node + `SurfaceAttachment` base + 3 empty stub
##     subclasses (`SurfaceJiggleAttachment`, `SurfaceOrificeRimAttachment`,
##     `SurfaceSoftRegionAttachment`).
##   - `bake_all_attachments()` baker invoked via a `trigger_bake` toggle
##     in the inspector.
##   - `diffuse(u0)` heat-method diffusion step.
##   - `diffuse_geodesic(seeds)` — v1 placeholder using 3D Euclidean
##     distance; concrete heat-method-distance pipeline lands at §17.2+.
##   - Sanity gizmo (heat-map of a selected attachment's baked weights).
##
## Consumer-side concrete `bake()` impls migrate the three attachment
## subclasses at §17.5 (Marionette jiggle), TT-side §10.4 (rim
## authoring), and Marionette §16 (soft-region cluster geodesic blend).
## Pre-§17 manual-authoring paths remain live as the no-body_field
## fallback (hard-optional invariant).

const _CotanLaplacian := preload("res://addons/body_field/runtime/cotan_laplacian.gd")
const _CholeskySolver := preload("res://addons/body_field/runtime/cholesky_solver.gd")
const _BodySurfaceFieldGizmo := preload("res://addons/body_field/debug/body_surface_field_gizmo.gd")

@export var source_mesh: Mesh = null:
	set(v):
		source_mesh = v
		# Invalidate factor on mesh change. The fingerprint check in
		# _ensure_factor() handles it lazily, but null'ing here gives
		# editor users an immediate "needs rebake" signal.
		if factor != null and factor.mesh_topology_fingerprint != "":
			factor = null

@export var factor: BodySurfaceFieldFactor = null
@export_file("*.tres") var factor_save_path: String = ""
@export var heat_t: float = -1.0   # < 0 → auto (~ mean_edge_length²)

@export var attachments: Array[SurfaceAttachment] = []

## Inspector one-shot: flipping this to true (re-)runs the bake for
## every attachment. Read by `set` immediately; the value resets to
## false after the bake completes.
@export var trigger_bake: bool = false:
	set(v):
		if v:
			bake_all_attachments()
		trigger_bake = false

@export var show_debug_gizmo: bool = false:
	set(v):
		show_debug_gizmo = v
		_refresh_gizmo()

@export var gizmo_attachment_index: int = 0:
	set(v):
		gizmo_attachment_index = max(0, v)
		_refresh_gizmo()

# Runtime — cached source mesh arrays (unpacked once at factor-build time).
var _verts: PackedVector3Array = PackedVector3Array()
var _indices: PackedInt32Array = PackedInt32Array()
var _gizmo: Node3D = null


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if source_mesh != null:
		_ensure_factor()
	_refresh_gizmo()


# --- Public API --------------------------------------------------------

## Lazy-build the cotan-Laplacian + Cholesky factor on first call (or
## whenever the source mesh topology fingerprint mismatches the cached
## factor). Saves to `factor_save_path` when set.
func _ensure_factor() -> void:
	if source_mesh == null:
		push_error("BodySurfaceField._ensure_factor: source_mesh is null")
		return
	var arrays: Array = source_mesh.surface_get_arrays(0)
	if arrays.is_empty():
		push_error("BodySurfaceField._ensure_factor: source_mesh has no surface 0")
		return
	var raw_verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var raw_indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if raw_indices.is_empty() or raw_verts.is_empty():
		push_error("BodySurfaceField._ensure_factor: source_mesh missing verts/indices")
		return

	# Weld coincident verts. UV-seam / pole duplicates (Godot SphereMesh,
	# glTF imports with split UVs) leave the cotan-Laplacian with
	# disconnected vertices that break SPD-ness. Idempotent on already-
	# welded inputs.
	var welded: Dictionary = _CotanLaplacian.weld_coincident_vertices(raw_verts, raw_indices)
	_verts = welded["vertices"]
	_indices = welded["indices"]

	var fp: String = _CotanLaplacian.fingerprint(_verts, _indices)
	if factor != null and factor.mesh_topology_fingerprint == fp and factor.chol_kind != &"none":
		# Cache hit.
		return

	var built: Dictionary = _CotanLaplacian.build(_verts, _indices)
	var t: float = heat_t
	if t <= 0.0:
		t = _auto_heat_t()
	var factor_dict: Dictionary = _CholeskySolver.factorize(built["L"], built["mass_diag"], t)

	if factor == null:
		factor = BodySurfaceFieldFactor.new()
	factor.n_verts = built["n_verts"]
	factor.mesh_topology_fingerprint = fp
	factor.mass_diag = built["mass_diag"]
	factor.heat_t = t
	factor.from_solver_dict(factor_dict)

	if factor_save_path != "":
		var err: int = ResourceSaver.save(factor, factor_save_path)
		if err != OK:
			push_warning("BodySurfaceField: ResourceSaver.save(%s) returned %d" % [factor_save_path, err])


## Heat-method one-step diffusion: returns u such that
## `(M + t·L) u = M · u0`. Caller provides u0 (typically a delta at one
## vertex, or a small set of seed values).
func diffuse(u0: PackedFloat32Array) -> PackedFloat32Array:
	if factor == null:
		_ensure_factor()
	if factor == null or factor.chol_kind == &"none":
		push_warning("BodySurfaceField.diffuse: factor not built; returning empty")
		return PackedFloat32Array()
	return _CholeskySolver.diffuse(factor.to_solver_dict(), factor.mass_diag, u0)


## Geodesic-distance approximation. §17.1 ships a 3D Euclidean
## placeholder (which on a sphere is the chord length — not the great-
## circle distance, but monotonic in it). The concrete heat-method
## geodesic-distance pipeline (Crane et al. §3) lands at §17.2+ when
## the first consumer needs precise geodesic falloff.
func diffuse_geodesic(seed_vertices: PackedInt32Array) -> PackedFloat32Array:
	push_warning("BodySurfaceField.diffuse_geodesic: §17.1 placeholder (3D Euclidean); heat-method geodesic-distance lands at §17.2+")
	if _verts.is_empty() and source_mesh != null:
		# Try once.
		_ensure_factor()
	var n: int = _verts.size()
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(n)
	if seed_vertices.is_empty():
		return out

	for vi in range(n):
		var v: Vector3 = _verts[vi]
		var d_min: float = INF
		for si in seed_vertices:
			if si < 0 or si >= n:
				continue
			var d: float = v.distance_to(_verts[si])
			if d < d_min:
				d_min = d
		out[vi] = d_min if d_min != INF else 0.0
	return out


## Bake every attached `SurfaceAttachment`. Idempotent — callers can
## hit it from the inspector toggle, from an EditorScript, or from
## scripted setup. Stale factors are rebuilt on demand.
func bake_all_attachments() -> void:
	if source_mesh == null:
		push_error("BodySurfaceField.bake_all_attachments: source_mesh is null")
		return
	_ensure_factor()
	if factor == null:
		push_error("BodySurfaceField.bake_all_attachments: factor build failed")
		return
	for a in attachments:
		if a == null:
			continue
		var w: PackedFloat32Array = a.bake(self)
		a.baked_weights = w
		a.baked_topology_fingerprint = factor.mesh_topology_fingerprint
	_refresh_gizmo()


# Accessor convenience — gizmo + tests read the cached arrays here
# rather than re-unpacking source_mesh.surface_get_arrays(0).
func get_source_vertices() -> PackedVector3Array:
	return _verts


func get_source_indices() -> PackedInt32Array:
	return _indices


# --- Internals ---------------------------------------------------------

func _auto_heat_t() -> float:
	# t ≈ mean edge length squared, per Crane et al. §3.2.
	var sum_e: float = 0.0
	var n_e: int = 0
	var ni: int = _indices.size()
	for ti in range(0, ni, 3):
		var a: int = _indices[ti + 0]
		var b: int = _indices[ti + 1]
		var c: int = _indices[ti + 2]
		sum_e += _verts[a].distance_to(_verts[b])
		sum_e += _verts[b].distance_to(_verts[c])
		sum_e += _verts[c].distance_to(_verts[a])
		n_e += 3
	if n_e == 0:
		return 1.0e-3
	var h: float = sum_e / float(n_e)
	return h * h


func _refresh_gizmo() -> void:
	if show_debug_gizmo and factor != null and not attachments.is_empty():
		if _gizmo == null:
			_gizmo = _BodySurfaceFieldGizmo.new()
			add_child(_gizmo)
		var idx: int = clampi(gizmo_attachment_index, 0, attachments.size() - 1)
		_gizmo.set_field(self, idx)
	elif _gizmo != null:
		_gizmo.queue_free()
		_gizmo = null
