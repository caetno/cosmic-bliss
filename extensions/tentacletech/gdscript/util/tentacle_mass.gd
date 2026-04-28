@tool
class_name TentacleGirthMass
extends RefCounted
## Distributes per-particle inverse mass along a Tentacle chain so that
## segment mass scales as girth^p (default p=2 — cross-sectional area,
## the right exponent for a uniform-length chain). Heavier base + lighter
## tip is what produces snake-strike whip dynamics: the body stores
## momentum during load, the lighter tip accelerates harder on release.
##
## Particle 0 is the anchor and is never written; Tentacle pins it via
## set_anchor() each tick (inv_mass = 0).
##
## Call after `rebuild_chain()`, after assigning a TentacleMesh, or any
## time the girth profile changes. This is config-time, not hot-path.

const _DEFAULT_EXPONENT := 2.0


# Apply girth-derived mass using a caller-supplied sample curve. `samples`
# is any-length array of girth values (typically 256 bins from
# `GirthBaker`/`TentacleMesh.get_baked_girth_samples()`). They're treated
# as covering s ∈ [0, 1] linearly and resampled to the chain's particle
# count. `mass_scale` sets the global mass; `exponent` controls how
# sharply mass tapers (2.0 = area, 3.0 = volume-ish, 1.0 = linear).
static func apply(p_tentacle: Node, p_samples: PackedFloat32Array,
		p_mass_scale: float = 1.0,
		p_exponent: float = _DEFAULT_EXPONENT) -> bool:
	if p_tentacle == null:
		return false
	var solver: Object = p_tentacle.get_solver()
	if solver == null:
		return false
	var n: int = p_tentacle.particle_count
	if n < 2:
		return false
	var have_samples: bool = p_samples.size() > 0
	# Skip particle 0 — it's the anchor, pinned to inv_mass=0 by Tentacle.
	for i in range(1, n):
		var s_norm: float = float(i) / float(n - 1)
		var girth: float = 1.0
		if have_samples:
			girth = _sample_linear(p_samples, s_norm)
		# Floor to avoid divide-by-zero on degenerate profiles. A girth
		# of 0 would model a zero-mass particle, which the PBD solver
		# already supports via inv_mass = INF, but distance constraints
		# misbehave with two infinite-mobility particles in a row, so
		# clamp to a sensible minimum.
		if girth < 0.05:
			girth = 0.05
		var mass: float = p_mass_scale * pow(girth, p_exponent)
		solver.set_particle_inv_mass(i, 1.0 / mass)
	return true


# Convenience: pull samples from the Tentacle's assigned TentacleMesh and
# apply. Returns false (without modifying mass) if no TentacleMesh is
# wired up — caller can fall back to `apply()` with explicit samples.
static func apply_from_mesh(p_tentacle: Node,
		p_mass_scale: float = 1.0,
		p_exponent: float = _DEFAULT_EXPONENT) -> bool:
	if p_tentacle == null:
		return false
	var mesh: Mesh = p_tentacle.get_tentacle_mesh()
	if mesh == null or not mesh.has_method("get_baked_girth_samples"):
		return false
	var samples: PackedFloat32Array = mesh.get_baked_girth_samples()
	return apply(p_tentacle, samples, p_mass_scale, p_exponent)


static func _sample_linear(p_samples: PackedFloat32Array, p_s_norm: float) -> float:
	var n: int = p_samples.size()
	if n == 0:
		return 1.0
	if n == 1:
		return p_samples[0]
	var t: float = clampf(p_s_norm, 0.0, 1.0) * float(n - 1)
	var i0: int = int(floor(t))
	var i1: int = mini(i0 + 1, n - 1)
	var f: float = t - float(i0)
	return lerpf(p_samples[i0], p_samples[i1], f)
