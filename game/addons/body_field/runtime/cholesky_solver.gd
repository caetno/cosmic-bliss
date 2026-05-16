class_name CholeskySolver

## Dense Cholesky factorization + back-substitution for the heat-method
## diffusion step.
##
## We factorize `A = M + t·L` where `L` is the positive-semi-definite
## cotan-Laplacian and `M` is the lumped diagonal mass. `A` is symmetric
## positive-definite (`M` is positive on a non-degenerate mesh, `L` is
## PSD, sum is SPD), so the standard in-place LLᵀ Cholesky works.
##
## Storage: lower-triangular `L_chol` packed in a `PackedFloat32Array` of
## length `n*n` (row-major, dense). Memory is n² floats — borderline at
## kasumi scale (n≈5k → 100 MB) but trivial for test meshes. v1.5+ may
## swap in a sparse Cholesky.
##
## Heat-method semantics: `diffuse(u0, t)` returns `u` such that
## `(M + t·L) u = M · u0`. Larger `t` → broader diffusion; `t ≈ h²` (mean
## edge length squared) is the rule-of-thumb starting point.

const _CHOL_EPS: float = 1.0e-12


## In-place LLᵀ Cholesky on a dense SPD matrix `A` (row-major n*n).
## Mutates `A` in place — caller passes a buffer they're done with;
## the lower triangle of `A` becomes the Cholesky factor on return.
## Returns true on success; pushes a warning + returns false on
## non-SPD input (degenerate mesh, NaNs, undamped Laplacian null
## space).
static func _llt_in_place(A: PackedFloat32Array, n: int) -> bool:
	for j in range(n):
		var s: float = A[j * n + j]
		for k in range(j):
			s -= A[j * n + k] * A[j * n + k]
		if s <= _CHOL_EPS:
			push_warning("CholeskySolver._llt_in_place: non-SPD at row %d (s=%f)" % [j, s])
			return false
		var d: float = sqrt(s)
		A[j * n + j] = d
		# Below-diagonal column j.
		for i in range(j + 1, n):
			var v: float = A[i * n + j]
			for k in range(j):
				v -= A[i * n + k] * A[j * n + k]
			A[i * n + j] = v / d
		# Zero out above-diagonal column j (cleanliness — never
		# read during solve, but keeps debugging dumps tidy).
		for i in range(j):
			A[i * n + j] = 0.0
	return true


## Factorize a dense SPD matrix `A` (row-major). Heat / Poisson
## builders below call this after assembling their respective `A`.
static func factorize_spd(A: PackedFloat32Array, n: int) -> Dictionary:
	if A.size() != n * n or n <= 0:
		push_error("CholeskySolver.factorize_spd: bad dims (n=%d, |A|=%d)" % [n, A.size()])
		return {"kind": "stub", "n_verts": n}
	if not _llt_in_place(A, n):
		return {"kind": "stub", "n_verts": n}
	return {"kind": "dense_ll", "n_verts": n, "L_chol": A}


## Factorize `A = M + t·L` for the heat-method backward-Euler step.
## `L` is the positive-semi-definite cotan-Laplacian; the addition of
## `M` regularises the constant-function null space.
static func factorize_heat(
		L: PackedFloat32Array,
		mass_diag: PackedFloat32Array,
		t: float
		) -> Dictionary:
	var n: int = mass_diag.size()
	if L.size() != n * n or n <= 0:
		push_error("CholeskySolver.factorize_heat: bad dims (n=%d, |L|=%d)" % [n, L.size()])
		return {"kind": "stub", "n_verts": n}
	var A: PackedFloat32Array = PackedFloat32Array()
	A.resize(n * n)
	for i in range(n):
		for j in range(n):
			A[i * n + j] = t * L[i * n + j]
		A[i * n + i] += mass_diag[i]
	return factorize_spd(A, n)


## Factorize `A = L + ε·M` for the heat-method Poisson step (§17.2).
## `L` alone is rank-deficient (constant functions); the Tikhonov
## regulariser `ε·M` lifts the null space without perturbing the
## solution by more than `O(ε)` so the post-solve shift (`φ -= min φ`)
## stays valid.
static func factorize_poisson(
		L: PackedFloat32Array,
		mass_diag: PackedFloat32Array,
		epsilon: float
		) -> Dictionary:
	var n: int = mass_diag.size()
	if L.size() != n * n or n <= 0:
		push_error("CholeskySolver.factorize_poisson: bad dims (n=%d, |L|=%d)" % [n, L.size()])
		return {"kind": "stub", "n_verts": n}
	var A: PackedFloat32Array = PackedFloat32Array()
	A.resize(n * n)
	for i in range(n):
		for j in range(n):
			A[i * n + j] = L[i * n + j]
		A[i * n + i] += epsilon * mass_diag[i]
	return factorize_spd(A, n)


## Backwards-compat alias for §17.1 callers — `factorize` == heat factor.
static func factorize(
		L: PackedFloat32Array,
		mass_diag: PackedFloat32Array,
		t: float
		) -> Dictionary:
	return factorize_heat(L, mass_diag, t)


## Solve `(L_chol · L_cholᵀ) x = b` via forward + backward substitution.
static func solve(factor: Dictionary, b: PackedFloat32Array) -> PackedFloat32Array:
	var n: int = factor.get("n_verts", 0)
	if n != b.size():
		push_error("CholeskySolver.solve: factor n=%d != |b|=%d" % [n, b.size()])
		return PackedFloat32Array()

	if factor.get("kind", &"stub") == &"stub" or factor.get("kind", "stub") == "stub":
		push_warning("CholeskySolver.solve: stub factor; returning b unchanged")
		return b.duplicate()

	var L_chol: PackedFloat32Array = factor["L_chol"]

	# Forward: solve L y = b.
	var y: PackedFloat32Array = PackedFloat32Array()
	y.resize(n)
	for i in range(n):
		var s: float = b[i]
		for k in range(i):
			s -= L_chol[i * n + k] * y[k]
		y[i] = s / L_chol[i * n + i]

	# Backward: solve Lᵀ x = y.
	var x: PackedFloat32Array = PackedFloat32Array()
	x.resize(n)
	for i in range(n - 1, -1, -1):
		var s2: float = y[i]
		for k in range(i + 1, n):
			s2 -= L_chol[k * n + i] * x[k]
		x[i] = s2 / L_chol[i * n + i]

	return x


## Heat-method one-step diffusion: returns `u` such that
## `(M + t·L) u = M · u0`. Caller supplies `u0` (typically a delta or a
## small set of seed values) and `t` (heat timestep, ≈ h²).
static func diffuse(
		factor: Dictionary,
		mass_diag: PackedFloat32Array,
		u0: PackedFloat32Array
		) -> PackedFloat32Array:
	var n: int = mass_diag.size()
	if u0.size() != n:
		push_error("CholeskySolver.diffuse: |u0|=%d != n=%d" % [u0.size(), n])
		return PackedFloat32Array()
	var rhs: PackedFloat32Array = PackedFloat32Array()
	rhs.resize(n)
	for i in range(n):
		rhs[i] = mass_diag[i] * u0[i]
	return solve(factor, rhs)
