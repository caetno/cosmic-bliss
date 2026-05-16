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

## Tikhonov regulariser for the §17.2 Poisson factor `(L + ε·M)`.
## ε small enough that the geodesic-distance shift `(φ -= min φ)` stays
## within `O(ε)` of the true Poisson solution; ε large enough to dominate
## the cotan null space numerically. 1e-4 of typical mass entries is the
## rule-of-thumb starting point.
@export var poisson_epsilon: float = 1.0e-4

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
	if (factor != null
			and factor.mesh_topology_fingerprint == fp
			and factor.chol_kind != &"none"
			and factor.chol_poisson_kind != &"none"):
		# Cache hit — both factors valid.
		return

	var built: Dictionary = _CotanLaplacian.build(_verts, _indices)
	var L: PackedFloat32Array = built["L"]
	var mass: PackedFloat32Array = built["mass_diag"]
	var t: float = heat_t
	if t <= 0.0:
		t = _auto_heat_t()
	# Heat factor: (M + t·L).
	var heat_dict: Dictionary = _CholeskySolver.factorize_heat(L, mass, t)
	# Poisson factor: (L + ε·M). Needed for the §17.2 heat-method
	# geodesic-distance pipeline; absent in §17.1.
	var poisson_dict: Dictionary = _CholeskySolver.factorize_poisson(L, mass, poisson_epsilon)

	if factor == null:
		factor = BodySurfaceFieldFactor.new()
	factor.n_verts = built["n_verts"]
	factor.mesh_topology_fingerprint = fp
	factor.mass_diag = mass
	factor.heat_t = t
	factor.poisson_epsilon = poisson_epsilon
	factor.from_solver_dict(heat_dict)
	factor.from_poisson_solver_dict(poisson_dict)

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


## Geodesic distance via the heat method (Crane et al. 2013, §3).
##
## Recipe:
##   1. Heat-diffuse a delta at `seed_vertices`: `u = solve(M + t·L, M·δ)`.
##   2. For each triangle, evaluate `X = -∇u / |∇u|` — a unit vector
##      field pointing toward the seed.
##   3. Solve the Poisson equation: `(L + ε·M) φ = ∇·X`.
##   4. Shift `φ -= min(φ)` so the closest point sits at distance 0.
##
## Returns per-vertex geodesic distance (length n_verts). Falls back
## to a `push_warning` + empty result when the factor is unbuilt.
func diffuse_geodesic(seed_vertices: PackedInt32Array) -> PackedFloat32Array:
	if factor == null:
		_ensure_factor()
	if factor == null or factor.chol_kind == &"none" or factor.chol_poisson_kind == &"none":
		push_warning("BodySurfaceField.diffuse_geodesic: factor not built; returning empty")
		return PackedFloat32Array()
	if factor.chol_kind == &"stub" or factor.chol_poisson_kind == &"stub":
		push_warning("BodySurfaceField.diffuse_geodesic: factor is stub-kind; returning empty")
		return PackedFloat32Array()

	var n: int = factor.n_verts
	if _verts.size() != n:
		# Lazy reload of the welded geometry — the factor was built
		# from a different ensure_factor invocation that left _verts
		# valid; if a save/reload round trip lost _verts, rebuild.
		_ensure_factor()
		if _verts.size() != n:
			push_error("BodySurfaceField.diffuse_geodesic: _verts size %d != factor.n_verts %d" % [_verts.size(), n])
			return PackedFloat32Array()

	if seed_vertices.is_empty():
		var zero: PackedFloat32Array = PackedFloat32Array()
		zero.resize(n)
		return zero

	# --- Step 1: heat diffusion from a delta at the seeds.
	var u0: PackedFloat32Array = PackedFloat32Array()
	u0.resize(n)
	for i in range(n):
		u0[i] = 0.0
	for s in seed_vertices:
		if s >= 0 and s < n:
			u0[s] = 1.0
	var u: PackedFloat32Array = _CholeskySolver.diffuse(
			factor.to_solver_dict(), factor.mass_diag, u0)
	if u.size() != n:
		push_error("BodySurfaceField.diffuse_geodesic: heat solve returned %d" % u.size())
		return PackedFloat32Array()

	# --- Step 2: unit gradient vector field, negated.
	var grads: PackedVector3Array = _CotanLaplacian.compute_face_gradients(_verts, _indices, u)
	var n_tris: int = grads.size()
	for ti in range(n_tris):
		var g: Vector3 = grads[ti]
		var l: float = g.length()
		if l > 1.0e-12:
			grads[ti] = -g / l
		else:
			grads[ti] = Vector3.ZERO

	# --- Step 3: per-vertex divergence → RHS of the Poisson solve.
	# Sign note: Crane's L_C is negative-semi-definite (Δ ≈ ∇²); the
	# Poisson equation is `L_C φ = ∇·X`. Our `L` is positive-semi-
	# definite (`L = -L_C`), so the equation becomes `L φ = -∇·X`.
	# Pass `-div` as the RHS.
	var div: PackedFloat32Array = _CotanLaplacian.compute_vertex_divergence(_verts, _indices, grads)
	var rhs: PackedFloat32Array = PackedFloat32Array()
	rhs.resize(div.size())
	for i in range(div.size()):
		rhs[i] = -div[i]

	# --- Step 4: Poisson solve.
	var phi: PackedFloat32Array = _CholeskySolver.solve(factor.to_poisson_solver_dict(), rhs)
	if phi.size() != n:
		push_error("BodySurfaceField.diffuse_geodesic: Poisson solve returned %d" % phi.size())
		return PackedFloat32Array()

	# --- Step 5: shift so the closest point is at distance 0.
	var phi_min: float = INF
	for i in range(n):
		if phi[i] < phi_min:
			phi_min = phi[i]
	if is_finite(phi_min):
		for i in range(n):
			phi[i] -= phi_min
	return phi


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
