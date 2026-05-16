@tool
class_name BodySurfaceFieldFactor
extends Resource

## Cached cotan-Laplacian + Cholesky factor for a body surface mesh.
##
## Built by `BodySurfaceField._ensure_factor()` and (when `factor_save_path`
## is set on the node) saved to disk so subsequent hero loads skip the
## factorization step. The fingerprint locks the factor to a specific
## mesh topology + vertex set — attachment-only edits don't trigger a
## refactor; only body mesh changes do.
##
## Storage: dense (n*n floats for `l_chol`). v1.5+ may swap to sparse.

@export var n_verts: int = 0
@export var mesh_topology_fingerprint: String = ""

## Lumped diagonal mass matrix (length n).
@export var mass_diag: PackedFloat32Array = PackedFloat32Array()

## Heat-method timestep `t` baked into the factor. `(M + t·L)` is
## what `l_chol` is the Cholesky of. Recomputing the factor with a
## different `t` requires invalidating this resource.
@export var heat_t: float = 0.0

## Cholesky factor kind:
##   "dense_ll" — `l_chol` holds the lower-triangular n*n factor.
##   "stub"     — factorization failed; consumers should `push_warning`
##                and either skip the diffuse step or fall back to b.
@export var chol_kind: StringName = &"none"

## Dense lower-triangular Cholesky factor of `M + t·L`. Length n*n
## when `chol_kind == "dense_ll"`; empty for stub kind.
@export var l_chol: PackedFloat32Array = PackedFloat32Array()


func to_solver_dict() -> Dictionary:
	# Adapter for CholeskySolver.solve / diffuse, which want a dict.
	return {
		"kind": chol_kind,
		"n_verts": n_verts,
		"L_chol": l_chol,
	}


func from_solver_dict(d: Dictionary) -> void:
	chol_kind = StringName(d.get("kind", "stub"))
	n_verts = d.get("n_verts", 0)
	l_chol = d.get("L_chol", PackedFloat32Array())
