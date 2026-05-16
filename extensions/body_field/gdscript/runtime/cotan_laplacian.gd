class_name CotanLaplacian

## Cotan-Laplacian + lumped mass matrix builder on a triangle surface mesh.
##
## Per Crane et al. "The Heat Method for Distance Computation" §3.1. The
## returned `L` is the positive-semi-definite discrete Laplace operator:
##
##   L[i,j] = -0.5 * (cot α_ij + cot β_ij)    for i ≠ j
##   L[i,i] = +Σ_{j ≠ i} (0.5 * cot α + 0.5 * cot β)
##
## (i.e. `L = D - W` where `W[i,j]` is the cotan weight and `D` is the
## diagonal row-sum of `W`.) Constant functions are in `L`'s null space —
## the heat method's `(M + t·L)x = M·b` step regularises that null space.
##
## v1 stores `L` as a dense `n × n` `PackedFloat32Array` (row-major). For
## the test sphere (n ≈ 50) this is trivial; for kasumi-class meshes
## (n ≈ 5k) it costs ~100 MB at hero-load only, freed once the Cholesky
## factor is built. Sparse storage is a v1.5+ refinement when consumer
## counts force it.

const _EPS_AREA: float = 1.0e-12


## Build the dense cotan-Laplacian + lumped mass matrix.
##
## Returns:
##   {
##     "n_verts":   int,
##     "L":         PackedFloat32Array,   # length n*n, row-major
##     "mass_diag": PackedFloat32Array,   # length n
##   }
static func build(vertices: PackedVector3Array, indices: PackedInt32Array) -> Dictionary:
	var n: int = vertices.size()
	var L: PackedFloat32Array = PackedFloat32Array()
	L.resize(n * n)
	for i in range(n * n):
		L[i] = 0.0
	var mass: PackedFloat32Array = PackedFloat32Array()
	mass.resize(n)
	for i in range(n):
		mass[i] = 0.0

	var n_tris: int = indices.size() / 3
	for t in range(n_tris):
		var ia: int = indices[t * 3 + 0]
		var ib: int = indices[t * 3 + 1]
		var ic: int = indices[t * 3 + 2]
		var a: Vector3 = vertices[ia]
		var b: Vector3 = vertices[ib]
		var c: Vector3 = vertices[ic]

		var ab: Vector3 = b - a
		var ac: Vector3 = c - a
		var bc: Vector3 = c - b
		var ba: Vector3 = -ab
		var ca: Vector3 = -ac
		var cb: Vector3 = -bc

		var cross_area: Vector3 = ab.cross(ac)
		var two_area: float = cross_area.length()
		if two_area < _EPS_AREA:
			continue
		var area: float = 0.5 * two_area

		# Cotangents of the three interior angles. cot(θ) =
		# dot(u,v) / |cross(u,v)|. For a triangle, |cross(u,v)| at
		# each vertex equals 2*area regardless of which two edges
		# we pick — that's the cheap identity.
		var cot_a: float = ab.dot(ac) / two_area    # angle at a (between ab and ac)
		var cot_b: float = ba.dot(bc) / two_area    # angle at b (between ba and bc)
		var cot_c: float = ca.dot(cb) / two_area    # angle at c (between ca and cb)

		# Each cotan contributes 0.5 to the weight on the edge it
		# opposes. The Laplacian off-diagonal is `-W`; the diagonal
		# is `+Σ W`. Build directly without an intermediate `W`.
		var ha: float = 0.5 * cot_a    # opposite edge (b,c)
		var hb: float = 0.5 * cot_b    # opposite edge (a,c)
		var hc: float = 0.5 * cot_c    # opposite edge (a,b)

		# Edge (b, c):
		L[ib * n + ic] -= ha
		L[ic * n + ib] -= ha
		L[ib * n + ib] += ha
		L[ic * n + ic] += ha
		# Edge (a, c):
		L[ia * n + ic] -= hb
		L[ic * n + ia] -= hb
		L[ia * n + ia] += hb
		L[ic * n + ic] += hb
		# Edge (a, b):
		L[ia * n + ib] -= hc
		L[ib * n + ia] -= hc
		L[ia * n + ia] += hc
		L[ib * n + ib] += hc

		# Barycentric lumped mass — area/3 to each corner.
		var third_area: float = area / 3.0
		mass[ia] += third_area
		mass[ib] += third_area
		mass[ic] += third_area

	return {
		"n_verts": n,
		"L": L,
		"mass_diag": mass,
	}


## Weld coincident vertices. glTF + Godot SphereMesh-style inputs ship
## UV-seam / pole duplicates: same position, different vertex index. The
## cotan-Laplacian treats them as separate verts with no edges between
## them, so each duplicate has zero adjacency, zero mass, and a zero
## diagonal — Cholesky on `M + t·L` fails to be SPD. Welding fixes that.
##
## `tol` is the coordinate-quantization step for bucketing (default
## 1e-5 — generous enough for fbx/glTF round-trips, tight enough that
## near-but-distinct verts on small body parts stay separated).
##
## Returns:
##   {
##     "vertices":  PackedVector3Array,     # deduplicated (length ≤ input)
##     "indices":   PackedInt32Array,        # remapped to deduped vertex IDs
##     "remap":     PackedInt32Array,        # original_idx → welded_idx (length = original)
##   }
static func weld_coincident_vertices(
		vertices: PackedVector3Array,
		indices: PackedInt32Array,
		tol: float = 1.0e-5) -> Dictionary:
	var n_in: int = vertices.size()
	var bucket := {}
	var remap: PackedInt32Array = PackedInt32Array()
	remap.resize(n_in)
	var deduped: PackedVector3Array = PackedVector3Array()
	var inv_tol: float = 1.0 / tol
	for i in range(n_in):
		var v: Vector3 = vertices[i]
		# Quantize into a string key. String key is the cheap option in
		# pure GDScript — int packing would be faster but requires care
		# with negative coords + bit ranges.
		var key: String = "%d_%d_%d" % [
			int(round(v.x * inv_tol)),
			int(round(v.y * inv_tol)),
			int(round(v.z * inv_tol)),
		]
		var existing = bucket.get(key, -1)
		if existing == -1:
			var new_idx: int = deduped.size()
			bucket[key] = new_idx
			deduped.append(v)
			remap[i] = new_idx
		else:
			remap[i] = existing

	var n_in_indices: int = indices.size()
	var new_indices: PackedInt32Array = PackedInt32Array()
	new_indices.resize(n_in_indices)
	for j in range(n_in_indices):
		new_indices[j] = remap[indices[j]]

	return {
		"vertices": deduped,
		"indices": new_indices,
		"remap": remap,
	}


## Topology fingerprint for cache validation. Hashes the index list
## (vertex positions can change without invalidating the cotan-only
## sparsity pattern, but our consumers also care about geometry, so
## the fingerprint includes the vertex byte-array hash too).
static func fingerprint(vertices: PackedVector3Array, indices: PackedInt32Array) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA1)
	ctx.update(indices.to_byte_array())
	ctx.update(vertices.to_byte_array())
	return ctx.finish().hex_encode()
