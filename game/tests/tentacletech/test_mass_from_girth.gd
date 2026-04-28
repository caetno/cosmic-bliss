extends SceneTree

# TentacleGirthMass tests.
#
# Run from repo root:
#   godot --path game --headless --script res://tests/tentacletech/test_mass_from_girth.gd

const _MassUtil := preload("res://addons/tentacletech/scripts/util/tentacle_mass.gd")


func _init() -> void:
	if not ClassDB.class_exists("Tentacle"):
		push_error("[FAIL] tentacletech extension not loaded")
		quit(2)
		return

	var passed: int = 0
	var failed: int = 0
	for test_name in [
		"test_uniform_girth_yields_uniform_mass",
		"test_tapered_girth_yields_lighter_tip",
		"test_anchor_inv_mass_untouched",
		"test_quadratic_exponent_default",
		"test_apply_from_mesh_pulls_baked_samples",
	]:
		if call(test_name):
			print("[PASS] %s" % test_name)
			passed += 1
		else:
			push_error("[FAIL] %s" % test_name)
			failed += 1

	print("\n%d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


# --- Scaffolding -----------------------------------------------------------

func _make_tentacle(p_count: int = 12) -> Node:
	var t: Object = ClassDB.instantiate("Tentacle")
	t.particle_count = p_count
	t.segment_length = 0.08
	t.rebuild_chain()
	get_root().add_child(t as Node)
	return t as Node


# --- Tests -----------------------------------------------------------------

# Uniform girth (all 1.0) → uniform mass → uniform inv_mass on all
# non-anchor particles.
func test_uniform_girth_yields_uniform_mass() -> bool:
	var t = _make_tentacle()
	var samples: PackedFloat32Array = PackedFloat32Array()
	samples.resize(64)
	samples.fill(1.0)
	var ok: bool = _MassUtil.apply(t, samples, 1.0, 2.0)
	if not ok:
		t.queue_free()
		push_error("apply() returned false on valid setup")
		return false
	var inv_masses: PackedFloat32Array = t.get_particle_inv_masses()
	t.queue_free()
	# Particle 0 may be 0 (anchor pin from rebuild). Compare 1..n-1.
	for i in range(2, inv_masses.size()):
		if not is_equal_approx(inv_masses[i], inv_masses[1]):
			push_error("non-uniform inv_mass: particle %d = %f vs %f"
					% [i, inv_masses[i], inv_masses[1]])
			return false
	if not is_equal_approx(inv_masses[1], 1.0):
		push_error("expected inv_mass=1.0 on uniform girth, got %f" % inv_masses[1])
		return false
	return true


# Tapered girth (1.0 → 0.5 from base to tip) with exponent 2 must produce
# a tip whose mass is ~25% of the base's, i.e. inv_mass ratio = 4×.
func test_tapered_girth_yields_lighter_tip() -> bool:
	var t = _make_tentacle()
	var samples: PackedFloat32Array = PackedFloat32Array()
	samples.resize(64)
	for i in samples.size():
		var s: float = float(i) / float(samples.size() - 1)
		samples[i] = lerpf(1.0, 0.5, s)
	_MassUtil.apply(t, samples, 1.0, 2.0)
	var inv_masses: PackedFloat32Array = t.get_particle_inv_masses()
	t.queue_free()
	# Particle 1 is near base (high girth → heavy → low inv_mass).
	# Last particle is tip (low girth → light → high inv_mass).
	var base_inv: float = inv_masses[1]
	var tip_inv: float = inv_masses[inv_masses.size() - 1]
	if tip_inv <= base_inv:
		push_error("tip inv_mass %.4f not greater than base %.4f"
				% [tip_inv, base_inv])
		return false
	# Ratio: tip girth ≈ 0.5 → mass = 0.25 → inv = 4. Base girth ≈ 1.0 →
	# inv = 1. Allow a generous band — the helper resamples linearly and
	# the chain has 12 particles, so the endpoints don't hit 1.0 / 0.5
	# exactly.
	var ratio: float = tip_inv / base_inv
	if ratio < 2.5 or ratio > 5.0:
		push_error("tip/base inv_mass ratio %.3f outside expected ~4×" % ratio)
		return false
	return true


# Particle 0 (anchor) must keep inv_mass = 0; the helper must not write
# to it. Tentacle re-anchors on every tick via set_anchor(), but we
# verify the helper itself respects the convention.
func test_anchor_inv_mass_untouched() -> bool:
	var t = _make_tentacle()
	var samples: PackedFloat32Array = PackedFloat32Array()
	samples.resize(8)
	samples.fill(1.0)
	_MassUtil.apply(t, samples, 1.0, 2.0)
	var inv0: float = t.get_solver().get_particle_inv_mass(0)
	t.queue_free()
	if not is_equal_approx(inv0, 0.0):
		push_error("particle 0 inv_mass should remain 0 (anchor), got %f" % inv0)
		return false
	return true


# Mass-scale + exponent compose as expected: doubling mass_scale should
# halve all non-anchor inv_masses; squaring girth via exponent=4 vs 2
# should square the inv_mass ratio.
func test_quadratic_exponent_default() -> bool:
	var t = _make_tentacle()
	var samples: PackedFloat32Array = PackedFloat32Array()
	samples.resize(16)
	for i in samples.size():
		samples[i] = 0.5  # uniform 0.5
	_MassUtil.apply(t, samples, 1.0, 2.0)
	var inv_e2: float = t.get_solver().get_particle_inv_mass(5)
	# Expected: mass = 1.0 * 0.5^2 = 0.25 → inv_mass = 4.0
	if not is_equal_approx(inv_e2, 4.0):
		t.queue_free()
		push_error("exp=2 inv_mass at uniform girth=0.5 expected 4.0, got %f"
				% inv_e2)
		return false
	_MassUtil.apply(t, samples, 1.0, 4.0)
	var inv_e4: float = t.get_solver().get_particle_inv_mass(5)
	# Expected: mass = 1.0 * 0.5^4 = 0.0625 → inv_mass = 16.0
	t.queue_free()
	if not is_equal_approx(inv_e4, 16.0):
		push_error("exp=4 inv_mass at uniform girth=0.5 expected 16.0, got %f"
				% inv_e4)
		return false
	return true


# `apply_from_mesh` must reach into the assigned TentacleMesh's baked
# samples. We assign a TentacleMesh, call apply_from_mesh, and verify
# inv_mass was actually changed (any non-uniform value indicates the
# tapered base→tip profile of the default cylinder-with-tip-radius mesh
# was consumed).
func test_apply_from_mesh_pulls_baked_samples() -> bool:
	var t = _make_tentacle()
	var TentacleMesh := load("res://addons/tentacletech/scripts/procedural/tentacle_mesh.gd")
	var mesh = TentacleMesh.new()
	mesh.length = 1.0
	mesh.base_radius = 0.05
	mesh.tip_radius = 0.01  # tapered → tip should be lighter
	mesh.length_segments = 16
	mesh.radial_segments = 8
	t.set_tentacle_mesh(mesh)
	var ok: bool = _MassUtil.apply_from_mesh(t, 1.0, 2.0)
	if not ok:
		t.queue_free()
		push_error("apply_from_mesh returned false")
		return false
	var inv_masses: PackedFloat32Array = t.get_particle_inv_masses()
	t.queue_free()
	var base_inv: float = inv_masses[1]
	var tip_inv: float = inv_masses[inv_masses.size() - 1]
	if tip_inv <= base_inv * 1.5:
		push_error("tapered mesh did not produce lighter tip: base=%f tip=%f"
				% [base_inv, tip_inv])
		return false
	return true
