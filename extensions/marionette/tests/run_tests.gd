extends SceneTree


const HUMANOID_PROFILE_PATH := "res://addons/marionette/scripts/data/marionette_humanoid_profile.tres"


func _init() -> void:
	var passed: int = 0
	var failed: int = 0

	for test_callable: Callable in [
		_test_smoke,
		_test_marionette_core_bridge,
		_test_spd_error_quaternion,
		_test_spd_quaternion_to_axis_angle,
		_test_spd_compute_torque,
		_test_spd_compute_gains,
		_test_marionette_bone_spd_zero_at_target,
		_test_marionette_bone_spd_nonzero_on_error,
		_test_marionette_bone_spd_sign_flip,
		_test_marionette_bone_state_flips_custom_integrator,
		_test_marionette_bone_strength_override_takes_precedence_over_entry,
		_test_marionette_bone_strength_clear_falls_back_to_entry,
		_test_marionette_bone_spd_zero_at_zero_strength,
		_test_marionette_gravity_scale_propagates_to_bones,
		_test_marionette_hip_nudge_only_on_root,
		_test_marionette_global_strength_factor_smooth,
		_test_marionette_strength_ramp_smooths_increase,
		_test_marionette_strength_drop_is_instantaneous,
		_test_marionette_per_bone_strength_ramp_smooths_increase,
		_test_validator_promotes_kinematic_ancestor_of_powered_to_unpowered,
		_test_validator_leaves_unpowered_ancestor_alone,
		_test_validator_leaves_pure_kinematic_chain_alone,
		_test_signed_axis_to_vector3,
		_test_signed_axis_sign_and_index,
		_test_signed_axis_inverse,
		_test_signed_axis_from_components_round_trip,
		_test_bone_archetype_enum,
		_test_bone_archetype_name_round_trip,
		_test_bone_entry_defaults,
		_test_bone_entry_basis_round_trip,
		_test_bone_profile_defaults,
		_test_bone_profile_dict_typing,
		_test_humanoid_archetype_map_complete,
		_test_humanoid_archetype_map_known_assignments,
		_test_muscle_frame_humanoid,
		_test_muscle_frame_orthonormal,
		_test_muscle_frame_world_rests_topology,
		_test_solver_dispatch_orthonormal_for_all_archetypes,
		_test_ball_solver_t_pose_left_arm,
		_test_hinge_solver_bent_knee,
		_test_hinge_solver_a_pose_elbow,
		_test_saddle_solver_bent_wrist,
		_test_clavicle_solver_flex_axis_is_up,
		_test_spine_solver_along_is_up,
		_test_permutation_matcher_candidate_count,
		_test_permutation_matcher_identity,
		_test_permutation_matcher_known_swap,
		_test_permutation_matcher_known_roll,
		_test_permutation_matcher_pathological,
		_test_permutation_matcher_negative_axes,
		_test_permutation_matcher_with_rest_rotation,
		_test_permutation_matcher_writes_into_entry,
		_test_rom_defaults_shoulder_vs_hip,
		_test_rom_defaults_elbow_vs_knee,
		_test_rom_defaults_wrist_vs_ankle,
		_test_rom_defaults_phalanx_fallback,
		_test_rom_defaults_zero_for_root_and_fixed,
		_test_bone_profile_generator_humanoid_counts,
		_test_bone_profile_generator_archetypes_match_defaults,
		_test_bone_profile_generator_handedness,
		_test_bone_profile_generator_rom_spot_checks,
		_test_bone_profile_generator_root_and_fixed_left_at_defaults,
		_test_bone_profile_generator_idempotent,
		_test_bone_profile_generator_preserves_missing_rig_bones,
		_test_bone_profile_generator_null_skeleton_profile_errors,
		_test_generator_template_upper_arm_joint_frame,
		_test_generator_template_upper_leg_joint_frame,
		_test_bone_state_profile_humanoid_defaults,
		_test_bone_state_profile_get_state_fallback,
		_test_collision_exclusion_parent_child_defaults,
		_test_collision_exclusion_siblings,
		_test_collision_exclusion_disabled_bones,
		_test_marionette_bone_extends_physical_bone3d,
		_test_build_ragdoll_synthetic_structure,
		_test_build_ragdoll_joint_rotation_baking,
		_test_bone_entry_anatomical_basis_branches_on_flag,
		_test_build_ragdoll_bakes_calculated_frame_when_flag_set,
		_test_build_ragdoll_rom_round_trip,
		_test_build_ragdoll_idempotent,
		_test_build_ragdoll_skips_unknown_bones,
		_test_anatomical_pose_zero_yields_identity,
		_test_anatomical_pose_single_axis_flex_default_permutation,
		_test_anatomical_pose_permuted_flex_axis,
		_test_anatomical_pose_negative_axis,
		_test_anatomical_pose_compose_order,
		_test_muscle_slider_applies_pose,
		_test_muscle_slider_restores_rest_on_exit_tree,
		_test_muscle_slider_reset_button,
		_test_muscle_slider_kinematic_write_gated_in_ragdoll_test,
		_test_muscle_test_dock_enter_ragdoll_test_zeros_gravity,
		_test_muscle_test_dock_exit_restores_gravity_and_rest,
		_test_bone_region_humanoid_total_84,
		_test_bone_region_left_right_balance,
		_test_bone_region_per_region_counts,
		_test_bone_region_unknown_falls_back_to_other,
		_test_bone_region_label_for_each,
		_test_macro_arms_flex_ext_covers_arm_bones,
		_test_macro_legs_med_lat_axis_only,
		_test_macro_all_covers_every_mapped_bone,
		_test_macro_hands_excludes_arms,
		_test_macro_body_covers_spine_and_head_neck,
		_test_macro_group_keys_partition_anatomical_set,
		_test_validator_template_profile_all_ok,
		_test_validator_flips_sign_error,
		_test_validator_swaps_axis_misassignment,
		_test_motion_validator_template_profile_no_wrongs,
		_test_canonical_directions_humanoid_coverage,
		_test_canonical_directions_handedness,
		_test_t_pose_basis_solver_orthonormal_humanoid,
		_test_t_pose_basis_solver_along_matches_table,
		_test_t_pose_basis_solver_motion_alignment,
		_test_bone_profile_generator_method_parity_template,
		_test_rest_offset_hinge_collinear_is_zero,
		_test_rest_offset_hinge_a_pose_elbow_bend,
		_test_rest_offset_root_fixed_pivot_returns_zero,
		_test_rest_offset_ball_shoulder_t_pose_abd_offset,
		_test_rest_offset_ball_hip_aligned_returns_zero,
		_test_rest_offset_saddle_foot_horizontal_returns_zero,
		_test_anatomical_pose_subtracts_rest_offset,
		_test_anatomical_pose_canonical_zero_at_offset,
		_test_build_ragdoll_rom_shifted_by_rest_offset,
		_test_normalizer_arp_examples,
		_test_normalizer_mixamo_examples,
		_test_normalizer_rigify_examples,
		_test_normalizer_godot_arp_examples,
		_test_normalizer_side_compatibility,
		_test_dictionary_all_slots_have_some_entry,
		_test_dictionary_left_right_mirror_consistent,
		_test_dictionary_no_collisions_within_convention,
		_test_auto_filler_arp_glb,
		_test_auto_filler_godot_arp_glb,
		_test_auto_filler_mixamo_glb,
		_test_auto_filler_rigify_glb,
		_test_auto_filler_preserves_existing_entries,
	]:
		if test_callable.call():
			passed += 1
		else:
			failed += 1

	print("\n%d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


# ---------- harness helpers ----------

func _ok(name: String) -> bool:
	print("[PASS] %s" % name)
	return true


func _fail(name: String, msg: String) -> bool:
	push_error("[FAIL] %s: %s" % [name, msg])
	return false


# ---------- smoke ----------

func _test_smoke() -> bool:
	if 1 + 1 != 2:
		return _fail("test_smoke", "1 + 1 != 2")
	return _ok("test_smoke")


# ---------- C++ bridge (P2.0) ----------

func _test_marionette_core_bridge() -> bool:
	if not ClassDB.class_exists("MarionetteCore"):
		return _fail("test_marionette_core_bridge", "MarionetteCore class not registered (GDExtension not loaded?)")
	var core: Object = ClassDB.instantiate("MarionetteCore")
	if core == null:
		return _fail("test_marionette_core_bridge", "ClassDB.instantiate returned null")
	var greeting: Variant = core.call("hello")
	if greeting != "marionette_core ok":
		core.free()
		return _fail("test_marionette_core_bridge", "hello() returned %s" % str(greeting))
	core.call("tick", 0.016)
	core.free()
	return _ok("test_marionette_core_bridge")


# ---------- SPDMath / SPDGainConverter (P5.1, P5.2) ----------

const _SPD_EPS_IDENTITY := 1.0e-6
const _SPD_EPS_HAND := 1.0e-4


static func _quat_near(a: Quaternion, b: Quaternion, eps: float) -> bool:
	# Allow antipodal equivalence: q and -q represent the same rotation.
	var d_pos: float = maxf(maxf(absf(a.x - b.x), absf(a.y - b.y)),
			maxf(absf(a.z - b.z), absf(a.w - b.w)))
	var d_neg: float = maxf(maxf(absf(a.x + b.x), absf(a.y + b.y)),
			maxf(absf(a.z + b.z), absf(a.w + b.w)))
	return minf(d_pos, d_neg) < eps


static func _vec_near(a: Vector3, b: Vector3, eps: float) -> bool:
	return maxf(maxf(absf(a.x - b.x), absf(a.y - b.y)), absf(a.z - b.z)) < eps


func _test_spd_error_quaternion() -> bool:
	if not ClassDB.class_exists("SPDMath"):
		return _fail("test_spd_error_quaternion", "SPDMath not registered")

	var ident := Quaternion.IDENTITY
	var q_x_pos := Quaternion(Vector3.RIGHT, PI / 2.0)
	var q_x_neg := Quaternion(Vector3.RIGHT, -PI / 2.0)

	# identity → identity ⇒ identity
	var r1: Quaternion = ClassDB.class_call_static("SPDMath", "error_quaternion", ident, ident)
	if not _quat_near(r1, ident, _SPD_EPS_IDENTITY):
		return _fail("test_spd_error_quaternion", "identity→identity expected IDENTITY, got %s" % str(r1))

	# +90°X → identity ⇒ −90°X  (rotation that takes current to target)
	var r2: Quaternion = ClassDB.class_call_static("SPDMath", "error_quaternion", q_x_pos, ident)
	if not _quat_near(r2, q_x_neg, _SPD_EPS_HAND):
		return _fail("test_spd_error_quaternion", "+90°X→ident expected −90°X, got %s" % str(r2))

	# identity → +90°X ⇒ +90°X
	var r3: Quaternion = ClassDB.class_call_static("SPDMath", "error_quaternion", ident, q_x_pos)
	if not _quat_near(r3, q_x_pos, _SPD_EPS_HAND):
		return _fail("test_spd_error_quaternion", "ident→+90°X expected +90°X, got %s" % str(r3))

	# Composition: error(a, b) * a == b   (since result is the rotation R with R * current = target)
	var a := Quaternion(Vector3(0.3, -0.5, 0.2).normalized(), 0.7)
	var b := Quaternion(Vector3(-0.1, 0.8, 0.4).normalized(), 1.3)
	var err_ab: Quaternion = ClassDB.class_call_static("SPDMath", "error_quaternion", a, b)
	var reconstructed: Quaternion = err_ab * a
	if not _quat_near(reconstructed, b, _SPD_EPS_HAND):
		return _fail("test_spd_error_quaternion",
				"err(a,b)*a expected b=%s, got %s" % [str(b), str(reconstructed)])

	# Shortest-arc: w must be >= 0
	if err_ab.w < 0.0:
		return _fail("test_spd_error_quaternion", "shortest-arc broken: w=%f < 0" % err_ab.w)

	return _ok("test_spd_error_quaternion")


func _test_spd_quaternion_to_axis_angle() -> bool:
	if not ClassDB.class_exists("SPDMath"):
		return _fail("test_spd_quaternion_to_axis_angle", "SPDMath not registered")

	# identity → zero
	var v0: Vector3 = ClassDB.class_call_static("SPDMath", "quaternion_to_axis_angle", Quaternion.IDENTITY)
	if not _vec_near(v0, Vector3.ZERO, _SPD_EPS_IDENTITY):
		return _fail("test_spd_quaternion_to_axis_angle", "identity expected ZERO, got %s" % str(v0))

	# +90°X → (π/2, 0, 0)
	var v1: Vector3 = ClassDB.class_call_static("SPDMath", "quaternion_to_axis_angle",
			Quaternion(Vector3.RIGHT, PI / 2.0))
	if not _vec_near(v1, Vector3(PI / 2.0, 0.0, 0.0), _SPD_EPS_HAND):
		return _fail("test_spd_quaternion_to_axis_angle",
				"+90°X expected (π/2,0,0), got %s" % str(v1))

	# −90°X → (−π/2, 0, 0)
	var v2: Vector3 = ClassDB.class_call_static("SPDMath", "quaternion_to_axis_angle",
			Quaternion(Vector3.RIGHT, -PI / 2.0))
	if not _vec_near(v2, Vector3(-PI / 2.0, 0.0, 0.0), _SPD_EPS_HAND):
		return _fail("test_spd_quaternion_to_axis_angle",
				"−90°X expected (−π/2,0,0), got %s" % str(v2))

	# 30° about (1,1,0).normalized() → axis * angle of same axis × 30°
	var axis := Vector3(1.0, 1.0, 0.0).normalized()
	var angle: float = deg_to_rad(30.0)
	var v3: Vector3 = ClassDB.class_call_static("SPDMath", "quaternion_to_axis_angle",
			Quaternion(axis, angle))
	var expected := axis * angle
	if not _vec_near(v3, expected, _SPD_EPS_HAND):
		return _fail("test_spd_quaternion_to_axis_angle",
				"tilted 30° expected %s, got %s" % [str(expected), str(v3)])

	return _ok("test_spd_quaternion_to_axis_angle")


func _test_spd_compute_torque() -> bool:
	if not ClassDB.class_exists("SPDMath"):
		return _fail("test_spd_compute_torque", "SPDMath not registered")

	# Hand-computed reference: error=(π/2,0,0), omega=0, kp=10, kd=1, dt=1/60
	# denom = 1 + 1/60 = 61/60
	# kp_stable = 10 * 60/61 = 600/61 ≈ 9.83606557
	# kd_stable = (1/6 + 1) * 60/61 = 70/61 ≈ 1.14754098
	# τ = 9.83606557 * π/2 = 15.45161...
	var expected_kp_stable := 600.0 / 61.0
	var expected_tau_x := expected_kp_stable * (PI / 2.0)
	var tau1: Vector3 = ClassDB.class_call_static("SPDMath", "compute_torque",
			Vector3(PI / 2.0, 0.0, 0.0), Vector3.ZERO, 10.0, 1.0, 1.0 / 60.0)
	var expected_tau1 := Vector3(expected_tau_x, 0.0, 0.0)
	if not _vec_near(tau1, expected_tau1, _SPD_EPS_HAND):
		return _fail("test_spd_compute_torque",
				"hand-computed expected %s, got %s (Δ=%.6e)" %
				[str(expected_tau1), str(tau1), (tau1 - expected_tau1).length()])

	# Zero error + zero omega → zero
	var tau2: Vector3 = ClassDB.class_call_static("SPDMath", "compute_torque",
			Vector3.ZERO, Vector3.ZERO, 10.0, 1.0, 1.0 / 60.0)
	if not _vec_near(tau2, Vector3.ZERO, _SPD_EPS_IDENTITY):
		return _fail("test_spd_compute_torque", "zero/zero expected ZERO, got %s" % str(tau2))

	# Pure damping: error=0, omega=(1,0,0), kp=10, kd=2, dt=1/60
	# denom = 1 + 2/60 = 62/60
	# kd_stable = (10/60 + 2) * 60/62 = (130/60) * (60/62) = 130/62 ≈ 2.0967742
	# τ_x = -2.0967742
	var expected_kd_stable := (10.0 / 60.0 + 2.0) / (1.0 + 2.0 / 60.0)
	var tau3: Vector3 = ClassDB.class_call_static("SPDMath", "compute_torque",
			Vector3.ZERO, Vector3(1.0, 0.0, 0.0), 10.0, 2.0, 1.0 / 60.0)
	var expected_tau3 := Vector3(-expected_kd_stable, 0.0, 0.0)
	if not _vec_near(tau3, expected_tau3, _SPD_EPS_HAND):
		return _fail("test_spd_compute_torque",
				"counter-torque expected %s, got %s" % [str(expected_tau3), str(tau3)])
	if tau3.x >= 0.0:
		return _fail("test_spd_compute_torque", "counter-torque sign wrong: %s" % str(tau3))

	return _ok("test_spd_compute_torque")


func _test_spd_compute_gains() -> bool:
	if not ClassDB.class_exists("SPDGainConverter"):
		return _fail("test_spd_compute_gains", "SPDGainConverter not registered")

	# alpha=4, damping=1.0, mass=1.0, dt=1/60 → ω_n=15 ⇒ kp=225, kd=30
	var g1: Vector2 = ClassDB.class_call_static("SPDGainConverter", "compute_gains",
			4.0, 1.0, 1.0, 1.0 / 60.0)
	if absf(g1.x - 225.0) > _SPD_EPS_HAND or absf(g1.y - 30.0) > _SPD_EPS_HAND:
		return _fail("test_spd_compute_gains",
				"α=4 ζ=1 m=1 expected (225,30), got %s" % str(g1))

	# alpha=4, damping=0.7, mass=2.0, dt=1/60 → ω_n=15 ⇒ kp=450, kd=42
	var g2: Vector2 = ClassDB.class_call_static("SPDGainConverter", "compute_gains",
			4.0, 0.7, 2.0, 1.0 / 60.0)
	if absf(g2.x - 450.0) > _SPD_EPS_HAND or absf(g2.y - 42.0) > _SPD_EPS_HAND:
		return _fail("test_spd_compute_gains",
				"α=4 ζ=0.7 m=2 expected (450,42), got %s" % str(g2))

	# alpha=10, damping=1.0, mass=1.0, dt=1/60 → ω_n=6 ⇒ kp=36, kd=12
	var g3: Vector2 = ClassDB.class_call_static("SPDGainConverter", "compute_gains",
			10.0, 1.0, 1.0, 1.0 / 60.0)
	if absf(g3.x - 36.0) > _SPD_EPS_HAND or absf(g3.y - 12.0) > _SPD_EPS_HAND:
		return _fail("test_spd_compute_gains",
				"α=10 ζ=1 m=1 expected (36,12), got %s" % str(g3))

	return _ok("test_spd_compute_gains")


# ---------- MarionetteBone SPD (P5 slice 3b) ----------
# Probes compute_spd_torque_for_test directly so the unit tests don't need a
# live SceneTree / physics step. The same code path runs in _integrate_forces;
# the test seam exists because spinning up a PhysicalBoneSimulator3D headless
# (with a PhysicsDirectBodyState3D pre-populated) is harder than the value
# the test adds.

const _SPD_TORQUE_EPS := 1.0e-4


func _make_spd_bone() -> MarionetteBone:
	# Powered, BALL-archetype, left-side, identity anatomical basis, alpha/damping
	# from the SPD gains test for cross-reference.
	var bone: MarionetteBone = ClassDB.instantiate("MarionetteBone")
	bone.current_state = MarionetteBone.STATE_POWERED
	bone.alpha = 4.0
	bone.damping_ratio = 1.0
	bone.strength = 1.0
	bone.archetype = int(BoneArchetype.Type.BALL)
	bone.is_left_side = true
	bone.mirror_abd = false
	bone.rest_anatomical_offset = Vector3.ZERO
	bone.anatomical_basis = Basis.IDENTITY
	return bone


func _test_marionette_bone_spd_zero_at_target() -> bool:
	if not ClassDB.class_exists("MarionetteBone"):
		return _fail("marionette_bone_spd_zero_at_target", "MarionetteBone not registered")
	var bone := _make_spd_bone()
	# Current rotation matches target → axis-angle error is zero → torque zero
	# (omega also zero). 30° flex around X for both current and target.
	var thirty := deg_to_rad(30.0)
	var anatomical := Vector3(thirty, 0.0, 0.0)
	var current := Quaternion(Vector3(1, 0, 0), thirty)
	var torque: Vector3 = bone.compute_spd_torque_for_test(
			current, anatomical, Vector3.ZERO, Basis.IDENTITY,
			1.0, 1.0 / 60.0, 1.0)
	bone.free()
	if torque.length() > _SPD_TORQUE_EPS:
		return _fail("marionette_bone_spd_zero_at_target",
				"torque=%s expected ~ZERO" % str(torque))
	return _ok("marionette_bone_spd_zero_at_target")


func _test_marionette_bone_spd_nonzero_on_error() -> bool:
	if not ClassDB.class_exists("MarionetteBone"):
		return _fail("marionette_bone_spd_nonzero_on_error", "MarionetteBone not registered")
	var bone := _make_spd_bone()
	# 45° flex error around X with identity current. SPD should fire +X torque.
	# Identity parent basis → world torque equals parent-local torque equals
	# pure +X.
	var target := Vector3(deg_to_rad(45.0), 0.0, 0.0)
	var torque: Vector3 = bone.compute_spd_torque_for_test(
			Quaternion.IDENTITY, target, Vector3.ZERO, Basis.IDENTITY,
			1.0, 1.0 / 60.0, 1.0)
	bone.free()
	if torque.length() < _SPD_TORQUE_EPS:
		return _fail("marionette_bone_spd_nonzero_on_error",
				"torque=%s expected magnitude > eps" % str(torque))
	if torque.x <= 0.0:
		return _fail("marionette_bone_spd_nonzero_on_error",
				"torque.x=%f expected > 0 for +flex target" % torque.x)
	# Cross-axis bleed: Y and Z should be ~0 for a pure-X error on an identity
	# basis. Catches an accidental basis-swap regression.
	if absf(torque.y) > _SPD_TORQUE_EPS or absf(torque.z) > _SPD_TORQUE_EPS:
		return _fail("marionette_bone_spd_nonzero_on_error",
				"cross-axis bleed: %s" % str(torque))
	return _ok("marionette_bone_spd_nonzero_on_error")


func _test_marionette_bone_spd_sign_flip() -> bool:
	if not ClassDB.class_exists("MarionetteBone"):
		return _fail("marionette_bone_spd_sign_flip", "MarionetteBone not registered")
	var bone := _make_spd_bone()
	var pos_target := Vector3(deg_to_rad(45.0), 0.0, 0.0)
	var neg_target := Vector3(-deg_to_rad(45.0), 0.0, 0.0)
	var tau_pos: Vector3 = bone.compute_spd_torque_for_test(
			Quaternion.IDENTITY, pos_target, Vector3.ZERO, Basis.IDENTITY,
			1.0, 1.0 / 60.0, 1.0)
	var tau_neg: Vector3 = bone.compute_spd_torque_for_test(
			Quaternion.IDENTITY, neg_target, Vector3.ZERO, Basis.IDENTITY,
			1.0, 1.0 / 60.0, 1.0)
	bone.free()
	if tau_pos.x <= 0.0 or tau_neg.x >= 0.0:
		return _fail("marionette_bone_spd_sign_flip",
				"+target.x=%f, -target.x=%f; expected opposite signs" %
				[tau_pos.x, tau_neg.x])
	# Magnitudes should match within float epsilon (anti-symmetry of SPD).
	if absf(tau_pos.x + tau_neg.x) > _SPD_TORQUE_EPS:
		return _fail("marionette_bone_spd_sign_flip",
				"asymmetric magnitudes: +%f / %f" % [tau_pos.x, tau_neg.x])
	return _ok("marionette_bone_spd_sign_flip")


func _test_marionette_bone_state_flips_custom_integrator() -> bool:
	# State setter must drive custom_integrator: POWERED → true, others →
	# false. Without this, KINEMATIC bones would have Jolt's gravity disabled
	# (silent breakage), and UNPOWERED bones would lose the default integrator.
	if not ClassDB.class_exists("MarionetteBone"):
		return _fail("marionette_bone_state_flips_custom_integrator",
				"MarionetteBone not registered")
	var bone: MarionetteBone = ClassDB.instantiate("MarionetteBone")
	bone.current_state = MarionetteBone.STATE_POWERED
	if not bone.custom_integrator:
		bone.free()
		return _fail("marionette_bone_state_flips_custom_integrator",
				"POWERED expected custom_integrator=true")
	bone.current_state = MarionetteBone.STATE_KINEMATIC
	if bone.custom_integrator:
		bone.free()
		return _fail("marionette_bone_state_flips_custom_integrator",
				"KINEMATIC expected custom_integrator=false")
	bone.current_state = MarionetteBone.STATE_UNPOWERED
	if bone.custom_integrator:
		bone.free()
		return _fail("marionette_bone_state_flips_custom_integrator",
				"UNPOWERED expected custom_integrator=false")
	bone.free()
	return _ok("marionette_bone_state_flips_custom_integrator")


# ---------- Strength API (P5 slice 4r) ----------
# `MarionetteCore` owns the per-bone strength override map; the bone's cached
# `strength` is the entry default. `_integrate_forces` resolves the effective
# gain via core->get_bone_strength(name, default) once per tick.

func _test_marionette_bone_strength_override_takes_precedence_over_entry() -> bool:
	if not ClassDB.class_exists("MarionetteBone"):
		return _fail("marionette_bone_strength_override_takes_precedence_over_entry",
				"MarionetteBone not registered")
	if not ClassDB.class_exists("MarionetteCore"):
		return _fail("marionette_bone_strength_override_takes_precedence_over_entry",
				"MarionetteCore not registered")
	# Same SPD setup as _make_spd_bone, but driven through the _ex seam so we
	# can inject an effective bone strength (what _integrate_forces does after
	# consulting the core's override map). Cached strength=1.0; override=0.25
	# → torque should scale by 0.25 vs the default-path baseline.
	var bone := _make_spd_bone()
	var target := Vector3(deg_to_rad(45.0), 0.0, 0.0)
	var tau_default: Vector3 = bone.compute_spd_torque_for_test(
			Quaternion.IDENTITY, target, Vector3.ZERO, Basis.IDENTITY,
			1.0, 1.0 / 60.0, 1.0)
	# Now exercise the core path. Set an override of 0.25 and read it back
	# the way the integrator does: core.get_bone_strength(name, default).
	var core: Object = ClassDB.instantiate("MarionetteCore")
	core.call(&"set_bone_strength", &"TestBone", 0.25)
	var resolved: float = core.call(&"get_bone_strength", &"TestBone", 1.0)
	if absf(resolved - 0.25) > 1.0e-6:
		core.free()
		bone.free()
		return _fail("marionette_bone_strength_override_takes_precedence_over_entry",
				"override read back as %f, expected 0.25" % resolved)
	var tau_override: Vector3 = bone.compute_spd_torque_for_test_ex(
			Quaternion.IDENTITY, target, Vector3.ZERO, Basis.IDENTITY,
			1.0, 1.0 / 60.0, resolved, 1.0)
	core.free()
	bone.free()
	# SPD's Tan/Liu/Turk implicit integration adds a `1 + kd*dt` denominator,
	# so torque is not strictly linear in scale — but it IS strictly monotonic
	# and the override (0.25) must produce noticeably less torque than the
	# entry default (1.0). The contract is "override scales down", not "scales
	# by exactly the multiplier".
	if tau_default.length() < _SPD_TORQUE_EPS:
		return _fail("marionette_bone_strength_override_takes_precedence_over_entry",
				"baseline torque too small to compare against")
	if tau_override.x <= 0.0 or tau_override.x >= tau_default.x:
		return _fail("marionette_bone_strength_override_takes_precedence_over_entry",
				"override torque %f should be in (0, default=%f)" %
				[tau_override.x, tau_default.x])
	return _ok("marionette_bone_strength_override_takes_precedence_over_entry")


func _test_marionette_bone_strength_clear_falls_back_to_entry() -> bool:
	if not ClassDB.class_exists("MarionetteCore"):
		return _fail("marionette_bone_strength_clear_falls_back_to_entry",
				"MarionetteCore not registered")
	var core: Object = ClassDB.instantiate("MarionetteCore")
	core.call(&"set_bone_strength", &"TestBone", 0.4)
	if not core.call(&"has_bone_strength_override", &"TestBone"):
		core.free()
		return _fail("marionette_bone_strength_clear_falls_back_to_entry",
				"override didn't register")
	core.call(&"clear_bone_strength", &"TestBone")
	if core.call(&"has_bone_strength_override", &"TestBone"):
		core.free()
		return _fail("marionette_bone_strength_clear_falls_back_to_entry",
				"override still present after clear")
	# Falls back to the caller-supplied default (the SPD path passes the
	# bone's cached `strength`). 0.75 here stands in for the cached entry value.
	var resolved: float = core.call(&"get_bone_strength", &"TestBone", 0.75)
	core.free()
	if absf(resolved - 0.75) > 1.0e-6:
		return _fail("marionette_bone_strength_clear_falls_back_to_entry",
				"post-clear resolved=%f, expected 0.75 (caller default)" % resolved)
	return _ok("marionette_bone_strength_clear_falls_back_to_entry")


func _test_marionette_gravity_scale_propagates_to_bones() -> bool:
	# `MarionetteCore::set_gravity_scale` must walk every registered bone and
	# write `RigidBody3D::gravity_scale`. Without this, the global zero-g
	# Ragdoll Test mode (P5.8) wouldn't actually disable gravity.
	if not ClassDB.class_exists("MarionetteCore") or not ClassDB.class_exists("MarionetteBone"):
		return _fail("marionette_gravity_scale_propagates_to_bones",
				"GDExtension classes not registered")
	var core: Object = ClassDB.instantiate("MarionetteCore")
	var b1: MarionetteBone = ClassDB.instantiate("MarionetteBone")
	var b2: MarionetteBone = ClassDB.instantiate("MarionetteBone")
	# Register each bone with the core (set_core wires the registry).
	b1.set_core(core)
	b2.set_core(core)
	# Dial gravity down; both bones should follow.
	core.call(&"set_gravity_scale", 0.0)
	if absf(b1.gravity_scale) > 1.0e-6 or absf(b2.gravity_scale) > 1.0e-6:
		b1.free(); b2.free(); core.free()
		return _fail("marionette_gravity_scale_propagates_to_bones",
				"after set_gravity_scale(0): b1=%f b2=%f" % [b1.gravity_scale, b2.gravity_scale])
	# Dial back to 0.5 and re-check.
	core.call(&"set_gravity_scale", 0.5)
	var ok: bool = absf(b1.gravity_scale - 0.5) < 1.0e-6 and absf(b2.gravity_scale - 0.5) < 1.0e-6
	b1.free(); b2.free(); core.free()
	if not ok:
		return _fail("marionette_gravity_scale_propagates_to_bones",
				"after set_gravity_scale(0.5): expected 0.5 on both")
	return _ok("marionette_gravity_scale_propagates_to_bones")


func _test_marionette_hip_nudge_only_on_root() -> bool:
	# `is_root` flag drives whether `_integrate_forces` applies the upward
	# nudge. Verified at the math seam: the core's `hip_upward_nudge` and
	# strength factor produce the expected force only on root-flagged bones.
	if not ClassDB.class_exists("MarionetteCore") or not ClassDB.class_exists("MarionetteBone"):
		return _fail("marionette_hip_nudge_only_on_root",
				"GDExtension classes not registered")
	var core: Object = ClassDB.instantiate("MarionetteCore")
	core.call(&"set_hip_upward_nudge", 100.0)
	core.call(&"set_global_strength", 1.0)
	if absf(core.call(&"get_global_strength_factor") - 1.0) > 1.0e-6:
		core.free()
		return _fail("marionette_hip_nudge_only_on_root",
				"factor=%f at full strength, expected 1.0" % core.call(&"get_global_strength_factor"))
	# Root bone: would receive nudge * factor.
	var root: MarionetteBone = ClassDB.instantiate("MarionetteBone")
	root.is_root = true
	root.set_core(core)
	if not root.is_root:
		root.free(); core.free()
		return _fail("marionette_hip_nudge_only_on_root", "root.is_root not set")
	if core.call(&"get_root_bone") == null:
		root.free(); core.free()
		return _fail("marionette_hip_nudge_only_on_root",
				"core did not cache root pointer after is_root=true + set_core")
	# Non-root bone: same wiring, but is_root stays false.
	var arm: MarionetteBone = ClassDB.instantiate("MarionetteBone")
	arm.set_core(core)
	if arm.is_root:
		root.free(); arm.free(); core.free()
		return _fail("marionette_hip_nudge_only_on_root", "non-root bone defaulted to is_root=true")
	root.free(); arm.free(); core.free()
	return _ok("marionette_hip_nudge_only_on_root")


func _test_marionette_global_strength_factor_smooth() -> bool:
	# Linear ramp from 0 (at global_strength=0) to 1.0 (at threshold). Caps
	# at 1.0 above threshold. Prevents nudge from lifting a limp character.
	if not ClassDB.class_exists("MarionetteCore"):
		return _fail("marionette_global_strength_factor_smooth",
				"MarionetteCore not registered")
	var core: Object = ClassDB.instantiate("MarionetteCore")
	core.call(&"set_hip_nudge_strength_threshold", 0.5)
	# At 1.0 (above threshold): factor = 1.
	core.call(&"set_global_strength", 1.0)
	if absf(core.call(&"get_global_strength_factor") - 1.0) > 1.0e-6:
		core.free()
		return _fail("marionette_global_strength_factor_smooth",
				"at global=1.0, threshold=0.5: factor expected 1.0")
	# At threshold (0.5): factor = 1.
	core.call(&"set_global_strength", 0.5)
	if absf(core.call(&"get_global_strength_factor") - 1.0) > 1.0e-6:
		core.free()
		return _fail("marionette_global_strength_factor_smooth",
				"at global=threshold: factor expected 1.0")
	# At 0.25 (half-way down ramp): factor = 0.5.
	core.call(&"set_global_strength", 0.25)
	if absf(core.call(&"get_global_strength_factor") - 0.5) > 1.0e-6:
		core.free()
		return _fail("marionette_global_strength_factor_smooth",
				"at global=0.25, threshold=0.5: factor expected 0.5")
	# At 0.0: factor = 0.
	core.call(&"set_global_strength", 0.0)
	if absf(core.call(&"get_global_strength_factor")) > 1.0e-6:
		core.free()
		return _fail("marionette_global_strength_factor_smooth",
				"at global=0: factor expected 0")
	core.free()
	return _ok("marionette_global_strength_factor_smooth")


func _test_marionette_strength_ramp_smooths_increase() -> bool:
	# Global strength 0 → 1 ramps over `strength_ramp_duration`. Calling
	# `step_strength_ramps(dt)` in a loop walks `effective` toward
	# `requested` monotonically, never overshooting. Drop from 1 → 0 is
	# instantaneous (covered separately).
	if not ClassDB.class_exists("MarionetteCore"):
		return _fail("marionette_strength_ramp_smooths_increase",
				"MarionetteCore not registered")
	var core: Object = ClassDB.instantiate("MarionetteCore")
	core.call(&"set_strength_ramp_duration", 0.5)
	# Start at 0 (drop from default 1 is instant).
	core.call(&"set_global_strength", 0.0)
	if absf(core.call(&"get_global_strength")) > 1.0e-6:
		core.free()
		return _fail("marionette_strength_ramp_smooths_increase",
				"effective should snap to 0 on drop")
	# Now request 1.0 — ramp begins. effective stays at 0 until step.
	core.call(&"set_global_strength", 1.0)
	if absf(core.call(&"get_global_strength")) > 1.0e-6:
		core.free()
		return _fail("marionette_strength_ramp_smooths_increase",
				"effective should still be 0 immediately after request — got %f"
				% core.call(&"get_global_strength"))
	if absf(core.call(&"get_requested_global_strength") - 1.0) > 1.0e-6:
		core.free()
		return _fail("marionette_strength_ramp_smooths_increase",
				"requested should be 1.0")
	# Step in 0.1s increments. After 5 × 0.1 = 0.5 s the ramp should
	# saturate at 1.0; values should grow monotonically and stay in [0,1].
	var prev: float = 0.0
	for i in range(5):
		core.call(&"step_strength_ramps", 0.1)
		var v: float = core.call(&"get_global_strength")
		if v < prev - 1.0e-6:
			core.free()
			return _fail("marionette_strength_ramp_smooths_increase",
					"effective dropped: %f after %f" % [v, prev])
		if v > 1.0 + 1.0e-6:
			core.free()
			return _fail("marionette_strength_ramp_smooths_increase",
					"effective overshot 1.0: %f" % v)
		prev = v
	# At t=0.5s the ramp should be saturated.
	if absf(core.call(&"get_global_strength") - 1.0) > 1.0e-4:
		core.free()
		return _fail("marionette_strength_ramp_smooths_increase",
				"ramp didn't saturate at 1.0 after duration; got %f"
				% core.call(&"get_global_strength"))
	core.free()
	return _ok("marionette_strength_ramp_smooths_increase")


func _test_marionette_strength_drop_is_instantaneous() -> bool:
	# Drops snap to the requested value within one set call — no waiting.
	# Critical for post-orgasm / surrender / shock paths in CLAUDE.md §12.
	if not ClassDB.class_exists("MarionetteCore"):
		return _fail("marionette_strength_drop_is_instantaneous",
				"MarionetteCore not registered")
	var core: Object = ClassDB.instantiate("MarionetteCore")
	core.call(&"set_strength_ramp_duration", 0.5)
	# Ramp up to 1.0 first.
	core.call(&"set_global_strength", 0.0)
	core.call(&"set_global_strength", 1.0)
	for i in range(10):
		core.call(&"step_strength_ramps", 0.1)
	# Now drop to 0.
	core.call(&"set_global_strength", 0.0)
	if absf(core.call(&"get_global_strength")) > 1.0e-6:
		core.free()
		return _fail("marionette_strength_drop_is_instantaneous",
				"effective=%f, expected 0 immediately after drop"
				% core.call(&"get_global_strength"))
	core.free()
	return _ok("marionette_strength_drop_is_instantaneous")


func _test_marionette_per_bone_strength_ramp_smooths_increase() -> bool:
	# Same ramp model applies to per-bone overrides. Each entry tracks its
	# own (requested, effective) pair; ramp step advances them in parallel.
	if not ClassDB.class_exists("MarionetteCore"):
		return _fail("marionette_per_bone_strength_ramp_smooths_increase",
				"MarionetteCore not registered")
	var core: Object = ClassDB.instantiate("MarionetteCore")
	core.call(&"set_strength_ramp_duration", 0.5)
	# Start LimpBone at 0 (first set seeds effective = 0).
	core.call(&"set_bone_strength", &"LimpBone", 0.0)
	if absf(core.call(&"get_bone_strength", &"LimpBone", 1.0)) > 1.0e-6:
		core.free()
		return _fail("marionette_per_bone_strength_ramp_smooths_increase",
				"first-set seeding produced %f, expected 0"
				% core.call(&"get_bone_strength", &"LimpBone", 1.0))
	# Re-engage: request 1.0.
	core.call(&"set_bone_strength", &"LimpBone", 1.0)
	if absf(core.call(&"get_bone_strength", &"LimpBone", 1.0)) > 1.0e-6:
		core.free()
		return _fail("marionette_per_bone_strength_ramp_smooths_increase",
				"effective should still be 0 right after re-engage; got %f"
				% core.call(&"get_bone_strength", &"LimpBone", 1.0))
	# Step a few times — effective should climb monotonically and saturate.
	for i in range(6):
		core.call(&"step_strength_ramps", 0.1)
	if absf(core.call(&"get_bone_strength", &"LimpBone", 1.0) - 1.0) > 1.0e-4:
		core.free()
		return _fail("marionette_per_bone_strength_ramp_smooths_increase",
				"effective didn't saturate at 1.0; got %f"
				% core.call(&"get_bone_strength", &"LimpBone", 1.0))
	# Drop is instant.
	core.call(&"set_bone_strength", &"LimpBone", 0.2)
	if absf(core.call(&"get_bone_strength", &"LimpBone", 1.0) - 0.2) > 1.0e-6:
		core.free()
		return _fail("marionette_per_bone_strength_ramp_smooths_increase",
				"drop should snap; got %f, expected 0.2"
				% core.call(&"get_bone_strength", &"LimpBone", 1.0))
	core.free()
	return _ok("marionette_per_bone_strength_ramp_smooths_increase")


# ---------- BoneStateValidator (P5 slice 7) ----------
# Synthetic 3-bone chain (root → child → grandchild). No skeleton needed:
# the validator operates on a `parents` Dictionary keyed by profile bone
# name so unit tests can probe it directly.

static func _validator_states(initial: Dictionary[StringName, int]) -> BoneStateProfile:
	var sp := BoneStateProfile.new()
	for k: StringName in initial.keys():
		sp.states[k] = initial[k]
	return sp


func _test_validator_promotes_kinematic_ancestor_of_powered_to_unpowered() -> bool:
	# root Kinematic, child Kinematic, grandchild Powered.
	# Expected: both ancestors promoted to Unpowered; grandchild stays Powered.
	var states: BoneStateProfile = _validator_states({
		&"Root": BoneStateProfile.State.KINEMATIC,
		&"Child": BoneStateProfile.State.KINEMATIC,
		&"Grand": BoneStateProfile.State.POWERED,
	})
	var parents: Dictionary[StringName, StringName] = {
		&"Child": &"Root",
		&"Grand": &"Child",
	}
	var warnings: Array[String] = []
	var corrected: Dictionary[StringName, int] = BoneStateValidator.validate(states, parents, warnings)
	if corrected[&"Root"] != BoneStateProfile.State.UNPOWERED:
		return _fail("validator_promotes_kinematic_ancestor_of_powered_to_unpowered",
				"Root expected UNPOWERED, got %d" % corrected[&"Root"])
	if corrected[&"Child"] != BoneStateProfile.State.UNPOWERED:
		return _fail("validator_promotes_kinematic_ancestor_of_powered_to_unpowered",
				"Child expected UNPOWERED, got %d" % corrected[&"Child"])
	if corrected[&"Grand"] != BoneStateProfile.State.POWERED:
		return _fail("validator_promotes_kinematic_ancestor_of_powered_to_unpowered",
				"Grand expected POWERED (unchanged), got %d" % corrected[&"Grand"])
	if warnings.size() != 2:
		return _fail("validator_promotes_kinematic_ancestor_of_powered_to_unpowered",
				"expected 2 warnings (root + child), got %d" % warnings.size())
	# Original profile must not be mutated — this is the "in-memory only"
	# guarantee from the slice spec.
	if states.states[&"Root"] != BoneStateProfile.State.KINEMATIC:
		return _fail("validator_promotes_kinematic_ancestor_of_powered_to_unpowered",
				"validator mutated saved profile — Root is now %d on the resource" %
				states.states[&"Root"])
	return _ok("validator_promotes_kinematic_ancestor_of_powered_to_unpowered")


func _test_validator_leaves_unpowered_ancestor_alone() -> bool:
	# An Unpowered ancestor of a Powered bone is fine — that's the "limp arm
	# with active hand" case. Validator should not touch it.
	var states: BoneStateProfile = _validator_states({
		&"Root": BoneStateProfile.State.UNPOWERED,
		&"Child": BoneStateProfile.State.UNPOWERED,
		&"Grand": BoneStateProfile.State.POWERED,
	})
	var parents: Dictionary[StringName, StringName] = {
		&"Child": &"Root",
		&"Grand": &"Child",
	}
	var warnings: Array[String] = []
	var corrected: Dictionary[StringName, int] = BoneStateValidator.validate(states, parents, warnings)
	if corrected[&"Root"] != BoneStateProfile.State.UNPOWERED:
		return _fail("validator_leaves_unpowered_ancestor_alone",
				"Root changed: %d" % corrected[&"Root"])
	if corrected[&"Child"] != BoneStateProfile.State.UNPOWERED:
		return _fail("validator_leaves_unpowered_ancestor_alone",
				"Child changed: %d" % corrected[&"Child"])
	if warnings.size() != 0:
		return _fail("validator_leaves_unpowered_ancestor_alone",
				"unexpected warnings: %s" % str(warnings))
	return _ok("validator_leaves_unpowered_ancestor_alone")


func _test_validator_leaves_pure_kinematic_chain_alone() -> bool:
	# No Powered descendant anywhere — Kinematic is fine (jaw chain, etc.).
	# Validator should not promote anything.
	var states: BoneStateProfile = _validator_states({
		&"Root": BoneStateProfile.State.KINEMATIC,
		&"Child": BoneStateProfile.State.KINEMATIC,
		&"Grand": BoneStateProfile.State.KINEMATIC,
	})
	var parents: Dictionary[StringName, StringName] = {
		&"Child": &"Root",
		&"Grand": &"Child",
	}
	var warnings: Array[String] = []
	var corrected: Dictionary[StringName, int] = BoneStateValidator.validate(states, parents, warnings)
	for k: StringName in [&"Root", &"Child", &"Grand"]:
		if corrected[k] != BoneStateProfile.State.KINEMATIC:
			return _fail("validator_leaves_pure_kinematic_chain_alone",
					"%s changed to %d" % [k, corrected[k]])
	if warnings.size() != 0:
		return _fail("validator_leaves_pure_kinematic_chain_alone",
				"unexpected warnings: %s" % str(warnings))
	return _ok("validator_leaves_pure_kinematic_chain_alone")


func _test_marionette_bone_spd_zero_at_zero_strength() -> bool:
	# CLAUDE.md §12 contract: strength=0 → zero torque even with a non-zero
	# target. Functionally equivalent to UNPOWERED but driven by the strength
	# dial instead of the state enum.
	if not ClassDB.class_exists("MarionetteBone"):
		return _fail("marionette_bone_spd_zero_at_zero_strength",
				"MarionetteBone not registered")
	var bone := _make_spd_bone()
	# Big error, but bone strength zero → kp = kd = 0 → torque zero.
	var target := Vector3(deg_to_rad(45.0), 0.0, 0.0)
	var torque: Vector3 = bone.compute_spd_torque_for_test_ex(
			Quaternion.IDENTITY, target, Vector3.ZERO, Basis.IDENTITY,
			1.0, 1.0 / 60.0, 0.0, 1.0)
	bone.free()
	if torque.length() > _SPD_TORQUE_EPS:
		return _fail("marionette_bone_spd_zero_at_zero_strength",
				"torque=%s expected ~ZERO at strength=0" % str(torque))
	return _ok("marionette_bone_spd_zero_at_zero_strength")


# ---------- SignedAxis ----------

func _test_signed_axis_to_vector3() -> bool:
	var expected := {
		SignedAxis.Axis.PLUS_X: Vector3(1, 0, 0),
		SignedAxis.Axis.MINUS_X: Vector3(-1, 0, 0),
		SignedAxis.Axis.PLUS_Y: Vector3(0, 1, 0),
		SignedAxis.Axis.MINUS_Y: Vector3(0, -1, 0),
		SignedAxis.Axis.PLUS_Z: Vector3(0, 0, 1),
		SignedAxis.Axis.MINUS_Z: Vector3(0, 0, -1),
	}
	for axis_value: SignedAxis.Axis in expected:
		var got := SignedAxis.to_vector3(axis_value)
		if got != expected[axis_value]:
			return _fail("signed_axis_to_vector3",
				"axis %d -> %s, expected %s" % [int(axis_value), got, expected[axis_value]])
	return _ok("signed_axis_to_vector3")


func _test_signed_axis_sign_and_index() -> bool:
	var cases: Array = [
		[SignedAxis.Axis.PLUS_X, 1, 0],
		[SignedAxis.Axis.MINUS_X, -1, 0],
		[SignedAxis.Axis.PLUS_Y, 1, 1],
		[SignedAxis.Axis.MINUS_Y, -1, 1],
		[SignedAxis.Axis.PLUS_Z, 1, 2],
		[SignedAxis.Axis.MINUS_Z, -1, 2],
	]
	for c: Array in cases:
		var axis_value: SignedAxis.Axis = c[0]
		var want_sign: int = c[1]
		var want_index: int = c[2]
		if SignedAxis.sign_of(axis_value) != want_sign:
			return _fail("signed_axis_sign", "axis %d sign=%d, expected %d" %
				[int(axis_value), SignedAxis.sign_of(axis_value), want_sign])
		if SignedAxis.index_of(axis_value) != want_index:
			return _fail("signed_axis_index", "axis %d index=%d, expected %d" %
				[int(axis_value), SignedAxis.index_of(axis_value), want_index])
	return _ok("signed_axis_sign_and_index")


func _test_signed_axis_inverse() -> bool:
	var pairs: Array = [
		[SignedAxis.Axis.PLUS_X, SignedAxis.Axis.MINUS_X],
		[SignedAxis.Axis.PLUS_Y, SignedAxis.Axis.MINUS_Y],
		[SignedAxis.Axis.PLUS_Z, SignedAxis.Axis.MINUS_Z],
	]
	for p: Array in pairs:
		var a: SignedAxis.Axis = p[0]
		var b: SignedAxis.Axis = p[1]
		if SignedAxis.inverse(a) != b:
			return _fail("signed_axis_inverse",
				"inverse(%d) = %d, expected %d" % [int(a), int(SignedAxis.inverse(a)), int(b)])
		if SignedAxis.inverse(b) != a:
			return _fail("signed_axis_inverse",
				"inverse(%d) = %d, expected %d" % [int(b), int(SignedAxis.inverse(b)), int(a)])
		# inverse(inverse(x)) = x
		if SignedAxis.inverse(SignedAxis.inverse(a)) != a:
			return _fail("signed_axis_inverse", "inverse not involutive on %d" % int(a))
		# Negating to_vector3 matches inverse.
		if SignedAxis.to_vector3(a) != -SignedAxis.to_vector3(b):
			return _fail("signed_axis_inverse", "vector parity broken on %d/%d" % [int(a), int(b)])
	return _ok("signed_axis_inverse")


func _test_signed_axis_from_components_round_trip() -> bool:
	for axis_value: SignedAxis.Axis in [
		SignedAxis.Axis.PLUS_X, SignedAxis.Axis.MINUS_X,
		SignedAxis.Axis.PLUS_Y, SignedAxis.Axis.MINUS_Y,
		SignedAxis.Axis.PLUS_Z, SignedAxis.Axis.MINUS_Z,
	]:
		var idx := SignedAxis.index_of(axis_value)
		var s := SignedAxis.sign_of(axis_value)
		var rebuilt := SignedAxis.from_components(idx, s)
		if rebuilt != axis_value:
			return _fail("signed_axis_from_components",
				"round-trip lost: %d -> (idx=%d sign=%d) -> %d" %
				[int(axis_value), idx, s, int(rebuilt)])
	return _ok("signed_axis_from_components_round_trip")


# ---------- BoneArchetype ----------

func _test_bone_archetype_enum() -> bool:
	var values: Array[BoneArchetype.Type] = BoneArchetype.all()
	if values.size() != BoneArchetype.COUNT:
		return _fail("bone_archetype_enum", "all().size()=%d, COUNT=%d" %
			[values.size(), BoneArchetype.COUNT])
	if BoneArchetype.COUNT != 8:
		return _fail("bone_archetype_enum", "expected 8 archetypes, got %d" % BoneArchetype.COUNT)
	# Each value must be unique and within [0, COUNT).
	var seen := {}
	for v: BoneArchetype.Type in values:
		if seen.has(v):
			return _fail("bone_archetype_enum", "duplicate archetype value %d" % int(v))
		seen[v] = true
		if int(v) < 0 or int(v) >= BoneArchetype.COUNT:
			return _fail("bone_archetype_enum", "archetype %d out of range" % int(v))
	return _ok("bone_archetype_enum")


func _test_bone_archetype_name_round_trip() -> bool:
	for v: BoneArchetype.Type in BoneArchetype.all():
		var name_value := BoneArchetype.to_name(v)
		if name_value == &"":
			return _fail("bone_archetype_name", "no name for %d" % int(v))
		var rebuilt := BoneArchetype.from_name(name_value)
		if rebuilt != int(v):
			return _fail("bone_archetype_name",
				"round-trip lost: %d -> %s -> %d" % [int(v), name_value, rebuilt])
	if BoneArchetype.from_name(&"NotARealArchetype") != -1:
		return _fail("bone_archetype_name", "missing name should yield -1")
	return _ok("bone_archetype_name_round_trip")


# ---------- BoneEntry ----------

func _test_bone_entry_defaults() -> bool:
	var e := BoneEntry.new()
	if e.archetype != BoneArchetype.Type.FIXED:
		return _fail("bone_entry_defaults", "default archetype should be FIXED")
	if e.flex_axis != SignedAxis.Axis.PLUS_X:
		return _fail("bone_entry_defaults", "default flex_axis should be PLUS_X")
	if e.along_bone_axis != SignedAxis.Axis.PLUS_Y:
		return _fail("bone_entry_defaults", "default along_bone_axis should be PLUS_Y")
	if e.abduction_axis != SignedAxis.Axis.PLUS_Z:
		return _fail("bone_entry_defaults", "default abduction_axis should be PLUS_Z")
	if e.rom_min != Vector3.ZERO or e.rom_max != Vector3.ZERO:
		return _fail("bone_entry_defaults", "default ROM should be zero")
	if e.is_left_side:
		return _fail("bone_entry_defaults", "default is_left_side should be false")
	return _ok("bone_entry_defaults")


func _test_bone_entry_basis_round_trip() -> bool:
	# Identity permutation -> identity basis.
	var e := BoneEntry.new()
	var b := e.bone_to_anatomical_basis()
	if not b.is_equal_approx(Basis.IDENTITY):
		return _fail("bone_entry_basis", "identity permutation -> %s, expected IDENTITY" % b)

	# A worked example: bone-local +Y is anatomical flex, bone-local +Z is along-bone,
	# bone-local +X is abduction. Verify basis columns match.
	e.flex_axis = SignedAxis.Axis.PLUS_Y
	e.along_bone_axis = SignedAxis.Axis.PLUS_Z
	e.abduction_axis = SignedAxis.Axis.PLUS_X
	var b2 := e.bone_to_anatomical_basis()
	if b2.x != Vector3(0, 1, 0):
		return _fail("bone_entry_basis", "x col wrong: %s" % b2.x)
	if b2.y != Vector3(0, 0, 1):
		return _fail("bone_entry_basis", "y col wrong: %s" % b2.y)
	if b2.z != Vector3(1, 0, 0):
		return _fail("bone_entry_basis", "z col wrong: %s" % b2.z)
	# Determinant +1: signed permutation, no improper reflection in this case.
	if not is_equal_approx(b2.determinant(), 1.0):
		return _fail("bone_entry_basis", "det=%f, expected +1" % b2.determinant())

	# Mirrored permutation (one negative axis) -> determinant -1.
	e.flex_axis = SignedAxis.Axis.MINUS_X
	e.along_bone_axis = SignedAxis.Axis.PLUS_Y
	e.abduction_axis = SignedAxis.Axis.PLUS_Z
	var b3 := e.bone_to_anatomical_basis()
	if not is_equal_approx(b3.determinant(), -1.0):
		return _fail("bone_entry_basis", "mirrored det=%f, expected -1" % b3.determinant())
	return _ok("bone_entry_basis_round_trip")


# ---------- BoneProfile ----------

func _test_bone_profile_defaults() -> bool:
	var p := BoneProfile.new()
	# total_mass moved to Marionette node in slice 5 — BoneProfile no longer
	# carries it. Test what's left: bones dict + skeleton_profile + mass_fraction.
	if p.bones.size() != 0:
		return _fail("bone_profile_defaults", "bones default should be empty")
	if p.skeleton_profile != null:
		return _fail("bone_profile_defaults", "skeleton_profile default should be null")
	if not is_equal_approx(p.mass_fraction_total(), 0.0):
		return _fail("bone_profile_defaults", "empty profile mass_fraction_total should be 0")
	return _ok("bone_profile_defaults")


func _test_bone_profile_dict_typing() -> bool:
	# Verify the typed Dictionary[StringName, BoneEntry] enforces value type.
	var p := BoneProfile.new()
	var entry := BoneEntry.new()
	entry.archetype = BoneArchetype.Type.HINGE
	entry.mass_fraction = 0.25
	p.bones[&"TestBone"] = entry

	if not p.has_entry(&"TestBone"):
		return _fail("bone_profile_dict", "stored entry not retrievable")
	var got := p.get_entry(&"TestBone")
	if got == null or got.archetype != BoneArchetype.Type.HINGE:
		return _fail("bone_profile_dict", "retrieved entry has wrong archetype")
	if not is_equal_approx(p.mass_fraction_total(), 0.25):
		return _fail("bone_profile_dict", "mass_fraction_total=%f, expected 0.25" %
			p.mass_fraction_total())
	if p.get_entry(&"Missing") != null:
		return _fail("bone_profile_dict", "missing entry should return null")
	return _ok("bone_profile_dict_typing")


# ---------- Default humanoid archetype map ----------

func _test_humanoid_archetype_map_complete() -> bool:
	var profile_resource := load(HUMANOID_PROFILE_PATH)
	if profile_resource == null:
		return _fail("humanoid_archetype_map_complete",
			"could not load %s" % HUMANOID_PROFILE_PATH)
	var profile := profile_resource as SkeletonProfile
	if profile == null:
		return _fail("humanoid_archetype_map_complete",
			"resource is not a SkeletonProfile")

	var bone_count := profile.bone_size
	if bone_count != 84:
		return _fail("humanoid_archetype_map_complete",
			"expected 84 bones in MarionetteHumanoidProfile, got %d" % bone_count)

	var missing: Array[StringName] = []
	for i in range(bone_count):
		var bone_name := profile.get_bone_name(i)
		if not MarionetteArchetypeDefaults.has_archetype_for(bone_name):
			missing.append(bone_name)
	if not missing.is_empty():
		return _fail("humanoid_archetype_map_complete",
			"%d unmapped bones: %s" % [missing.size(), missing])

	# Map keys that aren't in the profile would also be a bug — flag them.
	var profile_names: Dictionary = {}
	for i in range(bone_count):
		profile_names[profile.get_bone_name(i)] = true
	var stray: Array[StringName] = []
	for key: StringName in MarionetteArchetypeDefaults.HUMANOID_BY_BONE.keys():
		if not profile_names.has(key):
			stray.append(key)
	if not stray.is_empty():
		return _fail("humanoid_archetype_map_complete",
			"%d map entries not in profile: %s" % [stray.size(), stray])

	return _ok("humanoid_archetype_map_complete")


func _test_humanoid_archetype_map_known_assignments() -> bool:
	# Spot-check critical assignments from Marionette_plan P2.5.
	var checks := {
		&"Root": BoneArchetype.Type.ROOT,
		&"Hips": BoneArchetype.Type.ROOT,
		&"Spine": BoneArchetype.Type.SPINE_SEGMENT,
		&"Head": BoneArchetype.Type.SPINE_SEGMENT,
		&"Jaw": BoneArchetype.Type.FIXED,
		&"LeftEye": BoneArchetype.Type.FIXED,
		&"LeftShoulder": BoneArchetype.Type.CLAVICLE,
		&"RightShoulder": BoneArchetype.Type.CLAVICLE,
		&"LeftUpperArm": BoneArchetype.Type.BALL,
		&"LeftLowerArm": BoneArchetype.Type.HINGE,
		&"LeftHand": BoneArchetype.Type.SADDLE,
		&"LeftUpperLeg": BoneArchetype.Type.BALL,
		&"LeftLowerLeg": BoneArchetype.Type.HINGE,
		&"LeftFoot": BoneArchetype.Type.SADDLE,
		# Proximal toe phalanx = saddle (MTP), distal = hinge.
		&"LeftBigToeProximal": BoneArchetype.Type.SADDLE,
		&"LeftBigToeDistal": BoneArchetype.Type.HINGE,
		&"LeftToe3Intermediate": BoneArchetype.Type.HINGE,
		# Proximal finger phalanx = saddle (MCP), distal = hinge.
		&"LeftIndexProximal": BoneArchetype.Type.SADDLE,
		&"LeftIndexDistal": BoneArchetype.Type.HINGE,
	}
	for bone_name: StringName in checks:
		var want: int = checks[bone_name]
		var got := MarionetteArchetypeDefaults.archetype_for_bone(bone_name)
		if got != want:
			return _fail("humanoid_archetype_map_known_assignments",
				"%s -> %d, expected %d" % [bone_name, got, want])
	# Unknown bone -> -1.
	if MarionetteArchetypeDefaults.archetype_for_bone(&"NotARealBone") != -1:
		return _fail("humanoid_archetype_map_known_assignments",
			"unknown bone should return -1")
	return _ok("humanoid_archetype_map_known_assignments")


# ---------- Muscle frame builder (P2.7) ----------

func _test_muscle_frame_humanoid() -> bool:
	# On MarionetteHumanoidProfile (Y-up, viewer-perspective naming with
	# LeftUpperLeg at +X, character faces +Z anatomically):
	#   right   ≈ (-1, 0, 0)
	#   up      ≈ (0, 1, 0)
	#   forward ≈ (0, 0, +1) — autodetected from foot bones' bone-local +Y
	#   (ankle->toe in Blender's Y-along-bone convention).
	var profile := load(HUMANOID_PROFILE_PATH) as SkeletonProfile
	if profile == null:
		return _fail("muscle_frame_humanoid", "could not load profile")

	var frame := MuscleFrameBuilder.build(profile)

	if not frame.up.is_equal_approx(Vector3.UP):
		return _fail("muscle_frame_humanoid", "up=%s, expected (0,1,0)" % frame.up)
	if not frame.right.is_equal_approx(Vector3.LEFT):
		# Vector3.LEFT == (-1,0,0) — character's right side, since LeftUpperLeg is at +X.
		return _fail("muscle_frame_humanoid", "right=%s, expected (-1,0,0)" % frame.right)
	if not frame.forward.is_equal_approx(Vector3.BACK):
		# Vector3.BACK == (0,0,+1) — anatomical forward for +Z-facing char.
		return _fail("muscle_frame_humanoid", "forward=%s, expected (0,0,+1)" % frame.forward)
	return _ok("muscle_frame_humanoid")


func _test_muscle_frame_orthonormal() -> bool:
	var profile := load(HUMANOID_PROFILE_PATH) as SkeletonProfile
	var frame := MuscleFrameBuilder.build(profile)
	# Each vector unit length.
	for label_value: Array in [["right", frame.right], ["up", frame.up], ["forward", frame.forward]]:
		var label: String = label_value[0]
		var v: Vector3 = label_value[1]
		if not is_equal_approx(v.length(), 1.0):
			return _fail("muscle_frame_orthonormal", "%s len=%f, expected 1.0" % [label, v.length()])
	# Pairwise orthogonal.
	for pair: Array in [
		["right·up", frame.right.dot(frame.up)],
		["right·forward", frame.right.dot(frame.forward)],
		["up·forward", frame.up.dot(frame.forward)],
	]:
		if absf(pair[1] as float) > 1.0e-5:
			return _fail("muscle_frame_orthonormal", "%s = %f, expected 0" % [pair[0], pair[1]])
	# Handedness of the (right, up, forward) triple is NOT guaranteed to be
	# right-handed: viewer-perspective hip naming gives `left = +X` whose cross
	# with `up` lands at anatomical-back, and the foot-probe autodetect flips
	# `forward` to anatomy. The orthonormal-with-correct-anatomical-labels
	# property is what we want — handedness is incidental.
	return _ok("muscle_frame_orthonormal")


func _test_muscle_frame_world_rests_topology() -> bool:
	# compute_world_rests should produce sensible accumulated origins for a few
	# known-position bones in MarionetteHumanoidProfile.
	var profile := load(HUMANOID_PROFILE_PATH) as SkeletonProfile
	var rests := MuscleFrameBuilder.compute_world_rests(profile)

	if rests.size() != profile.bone_size:
		return _fail("muscle_frame_world_rests",
			"got %d transforms for %d bones" % [rests.size(), profile.bone_size])
	# Hips at (0, 0.75, 0).
	var hips: Transform3D = rests.get(&"Hips", Transform3D.IDENTITY)
	if not hips.origin.is_equal_approx(Vector3(0, 0.75, 0)):
		return _fail("muscle_frame_world_rests",
			"Hips origin=%s, expected (0, 0.75, 0)" % hips.origin)
	# LeftUpperLeg at (0.1, 0.75, 0); RightUpperLeg at (-0.1, 0.75, 0).
	var lul: Transform3D = rests.get(&"LeftUpperLeg", Transform3D.IDENTITY)
	var rul: Transform3D = rests.get(&"RightUpperLeg", Transform3D.IDENTITY)
	if not lul.origin.is_equal_approx(Vector3(0.1, 0.75, 0)):
		return _fail("muscle_frame_world_rests",
			"LeftUpperLeg origin=%s, expected (0.1, 0.75, 0)" % lul.origin)
	if not rul.origin.is_equal_approx(Vector3(-0.1, 0.75, 0)):
		return _fail("muscle_frame_world_rests",
			"RightUpperLeg origin=%s, expected (-0.1, 0.75, 0)" % rul.origin)
	# Hip midpoint helper.
	var mid := MuscleFrameBuilder.hip_midpoint(profile, rests)
	if not mid.is_equal_approx(Vector3(0, 0.75, 0)):
		return _fail("muscle_frame_world_rests",
			"hip_midpoint=%s, expected (0, 0.75, 0)" % mid)
	return _ok("muscle_frame_world_rests_topology")


# ---------- Archetype solvers (P2.6) ----------

const _MUSCLE_FRAME_FIXTURE_RIGHT := Vector3(-1, 0, 0)   # character's right (=world -X)
const _MUSCLE_FRAME_FIXTURE_UP := Vector3(0, 1, 0)
const _MUSCLE_FRAME_FIXTURE_FWD := Vector3(0, 0, -1)


func _make_muscle_frame_fixture() -> MuscleFrame:
	var f := MuscleFrame.new()
	f.right = _MUSCLE_FRAME_FIXTURE_RIGHT
	f.up = _MUSCLE_FRAME_FIXTURE_UP
	f.forward = _MUSCLE_FRAME_FIXTURE_FWD
	return f


func _basis_is_orthonormal(b: Basis, tol: float = 1.0e-5) -> bool:
	if not is_equal_approx(b.x.length(), 1.0):
		return false
	if not is_equal_approx(b.y.length(), 1.0):
		return false
	if not is_equal_approx(b.z.length(), 1.0):
		return false
	if absf(b.x.dot(b.y)) > tol:
		return false
	if absf(b.x.dot(b.z)) > tol:
		return false
	if absf(b.y.dot(b.z)) > tol:
		return false
	return true


func _test_solver_dispatch_orthonormal_for_all_archetypes() -> bool:
	var frame := _make_muscle_frame_fixture()
	# Place a synthetic limb bone hanging downward (T-pose left arm).
	var bone := Transform3D(Basis.IDENTITY, Vector3(0.2, 1.4, 0))
	var child := Transform3D(Basis.IDENTITY, Vector3(0.2, 1.0, 0))   # 0.4 m below

	for arch: BoneArchetype.Type in BoneArchetype.all():
		var basis := MarionetteArchetypeSolverDispatch.solve(arch, bone, child, frame, true)
		if not _basis_is_orthonormal(basis):
			return _fail("solver_dispatch_orthonormal",
				"archetype %s -> non-orthonormal basis %s" % [BoneArchetype.to_name(arch), basis])
	return _ok("solver_dispatch_orthonormal_for_all_archetypes")


func _test_ball_solver_t_pose_left_arm() -> bool:
	# Synthetic T-pose left arm: shoulder at (0.2, 1.5, 0), elbow at (0.5, 1.5, 0).
	# Along-bone points laterally outward (+X). Flex axis should be made
	# perpendicular to that (the muscle frame's left direction +X is parallel
	# to along, so the solver should orthogonalize).
	var frame := _make_muscle_frame_fixture()
	var shoulder := Transform3D(Basis.IDENTITY, Vector3(0.2, 1.5, 0))
	var elbow := Transform3D(Basis.IDENTITY, Vector3(0.5, 1.5, 0))
	var basis := MarionetteBallSolver.solve(shoulder, elbow, frame, true)
	if not _basis_is_orthonormal(basis):
		return _fail("ball_solver_t_pose", "non-orthonormal basis")
	# Along-bone (basis.y) should align with arm direction (+X).
	if not basis.y.is_equal_approx(Vector3.RIGHT):
		return _fail("ball_solver_t_pose", "along=%s, expected (1,0,0)" % basis.y)
	# Flex (basis.x) and abduction (basis.z) span the body's frontal/sagittal
	# planes, both perpendicular to +X.
	if absf(basis.x.dot(Vector3.RIGHT)) > 1.0e-5:
		return _fail("ball_solver_t_pose", "flex axis not perpendicular to along")
	# Now a hanging-down arm: along should be world -Y, flex the lateral axis.
	var shoulder_down := Transform3D(Basis.IDENTITY, Vector3(0.2, 1.5, 0))
	var elbow_down := Transform3D(Basis.IDENTITY, Vector3(0.2, 1.0, 0))
	var basis_down := MarionetteBallSolver.solve(shoulder_down, elbow_down, frame, true)
	if not basis_down.y.is_equal_approx(Vector3.DOWN):
		return _fail("ball_solver_hanging", "along=%s, expected (0,-1,0)" % basis_down.y)
	# Flex axis should be the body's left direction (+X) since lateral_outward
	# for a left-side bone is -muscle_frame.right = +X.
	if not basis_down.x.is_equal_approx(Vector3.RIGHT):
		return _fail("ball_solver_hanging", "flex=%s, expected (1,0,0)" % basis_down.x)
	# Abduction = flex × along = +X × -Y = -Z. With character facing -Z, this
	# means the abduction axis points in the character's facing direction —
	# which is the rotation axis around which forward-abduction motion happens
	# (raising arm sideways from down-by-side to horizontal-out). Sign is
	# fixed by the basis convention (CLAUDE.md §2: Z = X × Y).
	if not basis_down.z.is_equal_approx(Vector3(0, 0, -1)):
		return _fail("ball_solver_hanging", "abd=%s, expected (0,0,-1)" % basis_down.z)
	return _ok("ball_solver_t_pose_left_arm")


func _test_hinge_solver_bent_knee() -> bool:
	# Flexed-knee fixture: upper leg goes from hip (0.1, 1.0, 0) downward to
	# knee (0.1, 0.5, 0). Lower leg is folded posteriorly by 30° (anatomical
	# knee flexion — ankle sits backward-and-below the knee in muscle-frame
	# coords; muscle frame's forward is -Z, so the ankle ends up at +Z).
	# The hinge axis = parent_along × along, both in the YZ plane, so the
	# result lies along world ±X (body lateral).
	var frame := _make_muscle_frame_fixture()
	var hip := Transform3D(Basis.IDENTITY, Vector3(0.1, 1.0, 0))
	var bend := Basis.from_euler(Vector3(deg_to_rad(-30.0), 0, 0))
	var lower_leg := Transform3D(bend, Vector3(0.1, 0.5, 0))
	var ankle_offset := bend * Vector3(0, -0.5, 0)
	var ankle := Transform3D(Basis.IDENTITY, lower_leg.origin + ankle_offset)

	# Pull the knee's motion target through the same dispatch the generator /
	# validator use so the test tracks the convention defined in
	# `solver_utils.anatomical_motion_target` (knee folds backward, opposite of
	# elbow / hip / shoulder).
	var motion_target: Vector3 = MarionetteSolverUtils.anatomical_motion_target(
			&"LeftLowerLeg", BoneArchetype.Type.HINGE, frame)
	var basis := MarionetteHingeSolver.solve(lower_leg, ankle, frame, true, hip, motion_target)
	if not _basis_is_orthonormal(basis):
		return _fail("hinge_solver_bent_knee", "non-orthonormal basis")
	# Hinge axis (basis.x = flex) should align with the body lateral axis. In
	# this fixture parent_along (knee→hip's reverse, i.e., (0,-1,0)) and along
	# (knee→ankle, in the YZ plane) cross to produce ±X.
	var dot_with_lateral: float = absf(basis.x.dot(Vector3.RIGHT))
	if dot_with_lateral < 0.99:
		return _fail("hinge_solver_bent_knee",
			"flex=%s, expected to align with world ±X (|dot|=%f)" % [basis.x, dot_with_lateral])
	# Sign: anatomical knee flexion is posterior, so motion_target = -forward =
	# +Z. flex = along × motion_target picks the side such that +flex rotates
	# the calf backward. For along ≈ (0,-0.87,0.5), along × +Z ≈ (-0.87,0,0),
	# i.e. basis.x points world -X for a left-side knee.
	if basis.x.dot(Vector3.RIGHT) > 0.0:
		return _fail("hinge_solver_bent_knee",
			("flex=%s points anteriorly; knee flexion folds posteriorly so flex axis "
			+ "should be world -X for a left-side bone") % basis.x)
	return _ok("hinge_solver_bent_knee")


func _test_hinge_solver_a_pose_elbow() -> bool:
	# A-pose left elbow in the XY plane. The convention now is that +flex
	# produces forward motion of the bone tip (motion = flex × along ≈
	# muscle_frame.forward). Lock that down rather than the axis direction —
	# the axis itself sits in the XY plane (perpendicular to forearm,
	# orthogonal to forward), not along ±Z as an earlier attempt assumed.
	var frame := _make_muscle_frame_fixture()
	var shoulder := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.5, 0.0))
	var elbow := Transform3D(Basis.IDENTITY, Vector3(0.5, 1.0, 0.0))
	var wrist := Transform3D(Basis.IDENTITY, Vector3(0.9, 0.4, 0.0))
	var basis := MarionetteHingeSolver.solve(elbow, wrist, frame, true, shoulder)
	if not _basis_is_orthonormal(basis):
		return _fail("hinge_a_pose_elbow", "non-orthonormal basis")
	var motion: Vector3 = basis.x.cross(basis.y).normalized()
	var fwd_dot: float = motion.dot(frame.forward)
	if fwd_dot < 0.95:
		return _fail("hinge_a_pose_elbow",
			"+flex motion %s not aligned with forward %s (dot=%f)" %
			[motion, frame.forward, fwd_dot])
	return _ok("hinge_solver_a_pose_elbow")


func _test_saddle_solver_bent_wrist() -> bool:
	# A-pose wrist in the XY plane. Same motion-direction lock-down as the
	# hinge test: +flex on a wrist drives the hand tip forward (palmar flex
	# in the body's anterior direction).
	var frame := _make_muscle_frame_fixture()
	var elbow := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0))
	var wrist := Transform3D(Basis.IDENTITY, Vector3(0.4, 0.6, 0.0))   # forearm in XY
	var hand_tip := Transform3D(Basis.IDENTITY, Vector3(0.5, 0.2, 0.0))  # bend at wrist, still XY
	var basis := MarionetteSaddleSolver.solve(wrist, hand_tip, frame, true, elbow)
	if not _basis_is_orthonormal(basis):
		return _fail("saddle_bent_wrist", "non-orthonormal basis")
	var motion: Vector3 = basis.x.cross(basis.y).normalized()
	var fwd_dot: float = motion.dot(frame.forward)
	if fwd_dot < 0.95:
		return _fail("saddle_bent_wrist",
			"+flex motion %s not aligned with forward %s (dot=%f)" %
			[motion, frame.forward, fwd_dot])
	return _ok("saddle_solver_bent_wrist")


func _test_clavicle_solver_flex_axis_is_up() -> bool:
	# Synthetic left clavicle: bone at base of neck, runs laterally to shoulder.
	# Anatomical clavicle flex = elevation; the bone tip moves +up. The new
	# solver derives flex via along × up, so the flex axis lands at +Z (the
	# rotation axis whose +rotation lifts a +X bone toward +Y), not +Y itself.
	var frame := _make_muscle_frame_fixture()
	var clav := Transform3D(Basis.IDENTITY, Vector3(0, 1.5, 0))
	var shoulder := Transform3D(Basis.IDENTITY, Vector3(0.15, 1.5, 0))   # along +X (lateral)
	var basis := MarionetteClavicleSolver.solve(clav, shoulder, frame, true)
	if not _basis_is_orthonormal(basis):
		return _fail("clavicle_flex_axis", "non-orthonormal")
	if not basis.y.is_equal_approx(Vector3.RIGHT):
		return _fail("clavicle_flex_axis", "along=%s, expected (1,0,0)" % basis.y)
	# Flex (basis.x) = along × up = +X × +Y = +Z. Motion = flex × along
	# = +Z × +X = +Y (up). That's the elevation direction.
	if not basis.x.is_equal_approx(Vector3.BACK):
		return _fail("clavicle_flex_axis", "flex=%s, expected (0,0,1)" % basis.x)
	return _ok("clavicle_solver_flex_axis_is_up")


func _test_spine_solver_along_is_up() -> bool:
	# Synthetic spine bone: parent-to-child runs upward.
	var frame := _make_muscle_frame_fixture()
	var spine := Transform3D(Basis.IDENTITY, Vector3(0, 1.0, 0))
	var chest := Transform3D(Basis.IDENTITY, Vector3(0, 1.1, 0))
	var basis := MarionetteSpineSegmentSolver.solve(spine, chest, frame, false)
	if not _basis_is_orthonormal(basis):
		return _fail("spine_along", "non-orthonormal")
	if not basis.y.is_equal_approx(Vector3.UP):
		return _fail("spine_along", "along=%s, expected (0,1,0)" % basis.y)
	# Spine flex = along × forward = +Y × -Z = -X. Motion = flex × along
	# = -X × +Y = -Z (forward) — anatomical trunk-flex direction.
	if not basis.x.is_equal_approx(Vector3.LEFT):
		return _fail("spine_along", "flex=%s, expected (-1,0,0)" % basis.x)
	return _ok("spine_solver_along_is_up")


# ---------- Permutation matcher (P2.8) ----------

func _test_permutation_matcher_candidate_count() -> bool:
	# Chiral octahedral group has exactly 24 proper-rotation signed permutations.
	# Improper (det = -1) reflections are excluded by construction.
	var n := MarionettePermutationMatcher.candidate_count()
	if n != 24:
		return _fail("matcher_candidate_count", "got %d, expected 24" % n)
	return _ok("permutation_matcher_candidate_count")


func _test_permutation_matcher_identity() -> bool:
	# Aligned target on aligned rest basis: best permutation is the identity
	# permutation, score = 1.
	var r := MarionettePermutationMatcher.find_match(Basis.IDENTITY, Basis.IDENTITY)
	if r.flex_axis != SignedAxis.Axis.PLUS_X:
		return _fail("matcher_identity", "flex=%d, expected PLUS_X" % int(r.flex_axis))
	if r.along_bone_axis != SignedAxis.Axis.PLUS_Y:
		return _fail("matcher_identity", "along=%d, expected PLUS_Y" % int(r.along_bone_axis))
	if r.abduction_axis != SignedAxis.Axis.PLUS_Z:
		return _fail("matcher_identity", "abd=%d, expected PLUS_Z" % int(r.abduction_axis))
	if not is_equal_approx(r.score, 1.0):
		return _fail("matcher_identity", "score=%f, expected 1.0" % r.score)
	if not r.matched:
		return _fail("matcher_identity", "expected matched=true")
	return _ok("permutation_matcher_identity")


func _test_permutation_matcher_known_swap() -> bool:
	# Target columns: flex=+Y, along=+X, abd=-Z. Det = +1 (proper rotation).
	# Rest = identity, so the matcher must recover the swap exactly.
	var target := Basis(Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, 0, -1))
	var r := MarionettePermutationMatcher.find_match(Basis.IDENTITY, target)
	if r.flex_axis != SignedAxis.Axis.PLUS_Y:
		return _fail("matcher_swap", "flex=%d, expected PLUS_Y" % int(r.flex_axis))
	if r.along_bone_axis != SignedAxis.Axis.PLUS_X:
		return _fail("matcher_swap", "along=%d, expected PLUS_X" % int(r.along_bone_axis))
	if r.abduction_axis != SignedAxis.Axis.MINUS_Z:
		return _fail("matcher_swap", "abd=%d, expected MINUS_Z" % int(r.abduction_axis))
	if not is_equal_approx(r.score, 1.0):
		return _fail("matcher_swap", "score=%f, expected 1.0" % r.score)
	if not r.matched:
		return _fail("matcher_swap", "expected matched=true")
	return _ok("permutation_matcher_known_swap")


func _test_permutation_matcher_known_roll() -> bool:
	# Target = identity rotated 30° around +Y. Per-axis dot is cos(30°) for X/Z
	# and 1 for Y; min = cos(30°) ≈ 0.866 — above default 0.85 → matched.
	var target := Basis(Vector3.UP, deg_to_rad(30.0))
	var r := MarionettePermutationMatcher.find_match(Basis.IDENTITY, target)
	if r.flex_axis != SignedAxis.Axis.PLUS_X:
		return _fail("matcher_roll", "flex=%d, expected PLUS_X" % int(r.flex_axis))
	if r.along_bone_axis != SignedAxis.Axis.PLUS_Y:
		return _fail("matcher_roll", "along=%d, expected PLUS_Y" % int(r.along_bone_axis))
	if r.abduction_axis != SignedAxis.Axis.PLUS_Z:
		return _fail("matcher_roll", "abd=%d, expected PLUS_Z" % int(r.abduction_axis))
	var expected: float = cos(deg_to_rad(30.0))
	if absf(r.score - expected) > 1.0e-5:
		return _fail("matcher_roll", "score=%f, expected %f" % [r.score, expected])
	if not r.matched:
		return _fail("matcher_roll", "30° roll should still match at default threshold")
	return _ok("permutation_matcher_known_roll")


func _test_permutation_matcher_pathological() -> bool:
	# 45° roll: best score = cos(45°) ≈ 0.707, below 0.85 → matched=false.
	var target := Basis(Vector3.UP, deg_to_rad(45.0))
	var r := MarionettePermutationMatcher.find_match(Basis.IDENTITY, target)
	if r.matched:
		return _fail("matcher_pathological", "45° roll should not match at default threshold")
	if r.score >= 0.85:
		return _fail("matcher_pathological", "score=%f, expected < 0.85" % r.score)
	if r.score <= 0.0:
		return _fail("matcher_pathological", "score=%f should be positive" % r.score)
	# Lowering the threshold below the score should flip matched to true,
	# proving the threshold is honored independently of the score search.
	var r_loose := MarionettePermutationMatcher.find_match(Basis.IDENTITY, target, 0.5)
	if not r_loose.matched:
		return _fail("matcher_pathological",
			"at threshold 0.5 score %f should still match" % r_loose.score)
	return _ok("permutation_matcher_pathological")


func _test_permutation_matcher_negative_axes() -> bool:
	# Target = (-X, +Y, -Z), determinant = +1 (two flips, proper rotation).
	# Matcher must pick (MINUS_X, PLUS_Y, MINUS_Z).
	var target := Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, -1))
	var r := MarionettePermutationMatcher.find_match(Basis.IDENTITY, target)
	if r.flex_axis != SignedAxis.Axis.MINUS_X:
		return _fail("matcher_neg", "flex=%d, expected MINUS_X" % int(r.flex_axis))
	if r.along_bone_axis != SignedAxis.Axis.PLUS_Y:
		return _fail("matcher_neg", "along=%d, expected PLUS_Y" % int(r.along_bone_axis))
	if r.abduction_axis != SignedAxis.Axis.MINUS_Z:
		return _fail("matcher_neg", "abd=%d, expected MINUS_Z" % int(r.abduction_axis))
	if not is_equal_approx(r.score, 1.0):
		return _fail("matcher_neg", "score=%f, expected 1.0" % r.score)
	return _ok("permutation_matcher_negative_axes")


func _test_permutation_matcher_with_rest_rotation() -> bool:
	# Rest basis = identity rotated 90° around +Y:
	#   rest.x = (0,0,-1), rest.y = (0,1,0), rest.z = (1,0,0).
	# Target = identity. To produce target.x=(1,0,0) from rest, pick the
	# bone-local axis whose rest-rotated vector is (1,0,0): that's +Z (since
	# rest * +Z = rest.z = (1,0,0)). Likewise along=+Y, abd=-X.
	var rest := Basis(Vector3.UP, deg_to_rad(90.0))
	var r := MarionettePermutationMatcher.find_match(rest, Basis.IDENTITY)
	if r.flex_axis != SignedAxis.Axis.PLUS_Z:
		return _fail("matcher_rest_rot", "flex=%d, expected PLUS_Z" % int(r.flex_axis))
	if r.along_bone_axis != SignedAxis.Axis.PLUS_Y:
		return _fail("matcher_rest_rot", "along=%d, expected PLUS_Y" % int(r.along_bone_axis))
	if r.abduction_axis != SignedAxis.Axis.MINUS_X:
		return _fail("matcher_rest_rot", "abd=%d, expected MINUS_X" % int(r.abduction_axis))
	if not is_equal_approx(r.score, 1.0):
		return _fail("matcher_rest_rot", "score=%f, expected 1.0" % r.score)
	return _ok("permutation_matcher_with_rest_rotation")


func _test_permutation_matcher_writes_into_entry() -> bool:
	# write_into() copies the resolved permutation into a BoneEntry, leaving
	# other fields (archetype, ROM, mass) untouched.
	var entry := BoneEntry.new()
	entry.archetype = BoneArchetype.Type.HINGE
	entry.mass_fraction = 0.05
	entry.rom_min = Vector3(-1.0, -1.0, -1.0)
	entry.rom_max = Vector3(1.0, 1.0, 1.0)

	var target := Basis(Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, 0, -1))
	var r := MarionettePermutationMatcher.find_match(Basis.IDENTITY, target)
	r.write_into(entry)

	if entry.flex_axis != SignedAxis.Axis.PLUS_Y:
		return _fail("matcher_write", "flex_axis not copied")
	if entry.along_bone_axis != SignedAxis.Axis.PLUS_X:
		return _fail("matcher_write", "along_bone_axis not copied")
	if entry.abduction_axis != SignedAxis.Axis.MINUS_Z:
		return _fail("matcher_write", "abduction_axis not copied")
	if entry.archetype != BoneArchetype.Type.HINGE:
		return _fail("matcher_write", "archetype clobbered")
	if not is_equal_approx(entry.mass_fraction, 0.05):
		return _fail("matcher_write", "mass_fraction clobbered")
	if entry.rom_max != Vector3(1.0, 1.0, 1.0):
		return _fail("matcher_write", "rom_max clobbered")
	return _ok("permutation_matcher_writes_into_entry")


# ---------- ROM defaults (P2.9) ----------

func _test_rom_defaults_shoulder_vs_hip() -> bool:
	# Both Ball, but distinct ROMs per Marionette_plan P2.9.
	var shoulder := BoneEntry.new()
	shoulder.archetype = BoneArchetype.Type.BALL
	MarionetteRomDefaults.apply(shoulder, &"LeftUpperArm")

	var hip := BoneEntry.new()
	hip.archetype = BoneArchetype.Type.BALL
	MarionetteRomDefaults.apply(hip, &"LeftUpperLeg")

	# Shoulder: flex -50..180° (extension + full overhead), abd -50..180°
	# (cross-body adduction + overhead). Canonical-anatomy convention:
	# rom_min/rom_max are measured from arms-at-side neutral, not T-pose;
	# `_compute_rest_offset` shifts to joint-local at ragdoll build.
	if not is_equal_approx(shoulder.rom_min.x, deg_to_rad(-50.0)):
		return _fail("rom_shoulder", "flex_min=%f, expected -50°" % rad_to_deg(shoulder.rom_min.x))
	if not is_equal_approx(shoulder.rom_max.x, deg_to_rad(180.0)):
		return _fail("rom_shoulder", "flex_max=%f, expected 180°" % rad_to_deg(shoulder.rom_max.x))
	if not is_equal_approx(shoulder.rom_min.z, deg_to_rad(-50.0)):
		return _fail("rom_shoulder", "abd_min=%f, expected -50°" % rad_to_deg(shoulder.rom_min.z))
	if not is_equal_approx(shoulder.rom_max.z, deg_to_rad(180.0)):
		return _fail("rom_shoulder", "abd_max=%f, expected 180°" % rad_to_deg(shoulder.rom_max.z))

	# Hip: flex -30..120°, abd -25..45°.
	if not is_equal_approx(hip.rom_min.x, deg_to_rad(-30.0)):
		return _fail("rom_hip", "flex_min=%f, expected -30°" % rad_to_deg(hip.rom_min.x))
	if not is_equal_approx(hip.rom_max.x, deg_to_rad(120.0)):
		return _fail("rom_hip", "flex_max=%f, expected 120°" % rad_to_deg(hip.rom_max.x))
	if not is_equal_approx(hip.rom_min.z, deg_to_rad(-25.0)):
		return _fail("rom_hip", "abd_min=%f, expected -25°" % rad_to_deg(hip.rom_min.z))
	if not is_equal_approx(hip.rom_max.z, deg_to_rad(45.0)):
		return _fail("rom_hip", "abd_max=%f, expected 45°" % rad_to_deg(hip.rom_max.z))

	# The two are not the same set of values.
	if shoulder.rom_max.is_equal_approx(hip.rom_max):
		return _fail("rom_shoulder_vs_hip", "shoulder and hip rom_max identical")
	# Right-side bones get the same magnitude as left (side flip is at solver time).
	var right_shoulder := BoneEntry.new()
	right_shoulder.archetype = BoneArchetype.Type.BALL
	MarionetteRomDefaults.apply(right_shoulder, &"RightUpperArm")
	if not right_shoulder.rom_max.is_equal_approx(shoulder.rom_max):
		return _fail("rom_shoulder_vs_hip", "right shoulder rom_max != left shoulder")
	return _ok("rom_defaults_shoulder_vs_hip")


func _test_rom_defaults_elbow_vs_knee() -> bool:
	var elbow := BoneEntry.new()
	elbow.archetype = BoneArchetype.Type.HINGE
	MarionetteRomDefaults.apply(elbow, &"LeftLowerArm")
	var knee := BoneEntry.new()
	knee.archetype = BoneArchetype.Type.HINGE
	MarionetteRomDefaults.apply(knee, &"LeftLowerLeg")

	if not is_equal_approx(elbow.rom_max.x, deg_to_rad(140.0)):
		return _fail("rom_elbow", "flex_max=%f, expected 140°" % rad_to_deg(elbow.rom_max.x))
	if not is_equal_approx(knee.rom_max.x, deg_to_rad(135.0)):
		return _fail("rom_knee", "flex_max=%f, expected 135°" % rad_to_deg(knee.rom_max.x))
	# Both should have zero rotation and abduction (1-DOF hinge).
	if not is_equal_approx(elbow.rom_max.y, 0.0) or not is_equal_approx(elbow.rom_max.z, 0.0):
		return _fail("rom_elbow", "expected zero rot/abd, got rot=%f abd=%f" %
			[elbow.rom_max.y, elbow.rom_max.z])
	if not is_equal_approx(knee.rom_max.y, 0.0) or not is_equal_approx(knee.rom_max.z, 0.0):
		return _fail("rom_knee", "expected zero rot/abd")
	return _ok("rom_defaults_elbow_vs_knee")


func _test_rom_defaults_wrist_vs_ankle() -> bool:
	var wrist := BoneEntry.new()
	wrist.archetype = BoneArchetype.Type.SADDLE
	MarionetteRomDefaults.apply(wrist, &"LeftHand")
	var ankle := BoneEntry.new()
	ankle.archetype = BoneArchetype.Type.SADDLE
	MarionetteRomDefaults.apply(ankle, &"LeftFoot")

	# Wrist: flex ±55, abd -15..35.
	if not is_equal_approx(wrist.rom_min.x, deg_to_rad(-55.0)):
		return _fail("rom_wrist", "flex_min=%f" % rad_to_deg(wrist.rom_min.x))
	if not is_equal_approx(wrist.rom_max.z, deg_to_rad(35.0)):
		return _fail("rom_wrist", "abd_max=%f" % rad_to_deg(wrist.rom_max.z))

	# Ankle: flex -15..40, abd ±20.
	if not is_equal_approx(ankle.rom_min.x, deg_to_rad(-15.0)):
		return _fail("rom_ankle", "flex_min=%f" % rad_to_deg(ankle.rom_min.x))
	if not is_equal_approx(ankle.rom_max.x, deg_to_rad(40.0)):
		return _fail("rom_ankle", "flex_max=%f" % rad_to_deg(ankle.rom_max.x))
	if not is_equal_approx(ankle.rom_max.z, deg_to_rad(20.0)):
		return _fail("rom_ankle", "abd_max=%f" % rad_to_deg(ankle.rom_max.z))

	# Saddles have zero medial rotation (only flex + abd are powered axes).
	if not is_equal_approx(wrist.rom_max.y, 0.0):
		return _fail("rom_wrist", "rotation should be zero on saddle")
	return _ok("rom_defaults_wrist_vs_ankle")


func _test_rom_defaults_phalanx_fallback() -> bool:
	# Distal phalanx (HINGE that's not elbow/knee) → 0..80°.
	var distal := BoneEntry.new()
	distal.archetype = BoneArchetype.Type.HINGE
	MarionetteRomDefaults.apply(distal, &"LeftIndexDistal")
	if not is_equal_approx(distal.rom_max.x, deg_to_rad(80.0)):
		return _fail("rom_phalanx", "distal flex_max=%f, expected 80°" % rad_to_deg(distal.rom_max.x))

	# Proximal phalanx (SADDLE that's not Hand/Foot) → 0..90° flex, ±20° abd.
	var proximal := BoneEntry.new()
	proximal.archetype = BoneArchetype.Type.SADDLE
	MarionetteRomDefaults.apply(proximal, &"LeftIndexProximal")
	if not is_equal_approx(proximal.rom_max.x, deg_to_rad(90.0)):
		return _fail("rom_phalanx", "proximal flex_max=%f, expected 90°" % rad_to_deg(proximal.rom_max.x))
	if not is_equal_approx(proximal.rom_max.z, deg_to_rad(20.0)):
		return _fail("rom_phalanx", "proximal abd_max=%f, expected 20°" % rad_to_deg(proximal.rom_max.z))

	# The single "LeftToes" hinge bone (no per-toe phalanges in ARP-light rigs)
	# shares the finger-phalanx ROM by archetype fallback.
	var toes := BoneEntry.new()
	toes.archetype = BoneArchetype.Type.HINGE
	MarionetteRomDefaults.apply(toes, &"LeftToes")
	if not is_equal_approx(toes.rom_max.x, deg_to_rad(80.0)):
		return _fail("rom_phalanx", "Toes block flex_max=%f, expected 80°" % rad_to_deg(toes.rom_max.x))

	# Toe IP joints (distal/intermediate phalanges of toes) get the broader
	# range — dorsiflex matters for toe lift during gait.
	for tn: StringName in [&"LeftBigToeDistal", &"LeftToe2Distal", &"LeftToe2Intermediate", &"RightToe5Distal"]:
		var t := BoneEntry.new()
		t.archetype = BoneArchetype.Type.HINGE
		MarionetteRomDefaults.apply(t, tn)
		if not is_equal_approx(t.rom_min.x, deg_to_rad(-30.0)):
			return _fail("rom_phalanx", "%s flex_min=%f, expected -30°" % [tn, rad_to_deg(t.rom_min.x)])
		if not is_equal_approx(t.rom_max.x, deg_to_rad(80.0)):
			return _fail("rom_phalanx", "%s flex_max=%f, expected 80°" % [tn, rad_to_deg(t.rom_max.x)])
	return _ok("rom_defaults_phalanx_fallback")


func _test_rom_defaults_zero_for_root_and_fixed() -> bool:
	# ROOT and FIXED bones aren't SPD-driven; ROM stays zero so any consumer
	# that accidentally clamps to it produces a no-op rather than a real range.
	var root := BoneEntry.new()
	root.archetype = BoneArchetype.Type.ROOT
	MarionetteRomDefaults.apply(root, &"Hips")
	if root.rom_min != Vector3.ZERO or root.rom_max != Vector3.ZERO:
		return _fail("rom_root", "ROOT should yield zero ROM, got min=%s max=%s" %
			[root.rom_min, root.rom_max])

	var jaw := BoneEntry.new()
	jaw.archetype = BoneArchetype.Type.FIXED
	MarionetteRomDefaults.apply(jaw, &"Jaw")
	if jaw.rom_min != Vector3.ZERO or jaw.rom_max != Vector3.ZERO:
		return _fail("rom_fixed", "FIXED should yield zero ROM")
	return _ok("rom_defaults_zero_for_root_and_fixed")


# ---------- BoneProfile generator (P2.10) ----------

func _make_humanoid_bone_profile() -> BoneProfile:
	var skel_profile := load(HUMANOID_PROFILE_PATH) as SkeletonProfile
	var bp := BoneProfile.new()
	bp.skeleton_profile = skel_profile
	return bp


func _test_bone_profile_generator_humanoid_counts() -> bool:
	# All 84 bones in MarionetteHumanoidProfile have a default archetype
	# (verified by _test_humanoid_archetype_map_complete), so the generator
	# should produce 84 entries with zero skipped. matched + unmatched should
	# cover every non-ROOT / non-FIXED bone exactly once.
	var bp := _make_humanoid_bone_profile()
	var report := BoneProfileGenerator.generate(bp)
	if report.error != "":
		return _fail("generator_counts", "error: %s" % report.error)
	if report.generated != 84:
		return _fail("generator_counts", "generated=%d, expected 84" % report.generated)
	if bp.bones.size() != 84:
		return _fail("generator_counts", "bones.size()=%d, expected 84" % bp.bones.size())
	if report.skipped != 0:
		return _fail("generator_counts", "skipped=%d, expected 0 (skipped=%s)" %
			[report.skipped, report.skipped_bones])
	# 5 bones are excluded from the SPD pipeline (Root, Hips=ROOT; Jaw, LeftEye,
	# RightEye=FIXED). 84 - 5 = 79 should pass through the matcher.
	var spd_driven: int = report.matched + report.unmatched
	if spd_driven != 79:
		return _fail("generator_counts",
			"matched+unmatched=%d, expected 79 (84 - 5 ROOT/FIXED)" % spd_driven)
	return _ok("generator_humanoid_counts")


func _test_bone_profile_generator_archetypes_match_defaults() -> bool:
	# Every entry's archetype must equal MarionetteArchetypeDefaults' verdict —
	# the generator is the only thing that *should* be writing this field.
	var bp := _make_humanoid_bone_profile()
	BoneProfileGenerator.generate(bp)
	for bone_name: StringName in bp.bones.keys():
		var entry: BoneEntry = bp.bones[bone_name]
		var expected: int = MarionetteArchetypeDefaults.archetype_for_bone(bone_name)
		if entry.archetype != expected:
			return _fail("generator_archetypes",
				"%s: entry.archetype=%d, defaults=%d" % [bone_name, int(entry.archetype), expected])
	return _ok("generator_archetypes_match_defaults")


func _test_bone_profile_generator_handedness() -> bool:
	# Bones whose name starts with "Left" -> is_left_side=true; "Right" -> false;
	# centerline (Spine, Head, Hips, Root, ...) -> false.
	var bp := _make_humanoid_bone_profile()
	BoneProfileGenerator.generate(bp)
	var checks := {
		&"LeftUpperArm": true,
		&"LeftLowerLeg": true,
		&"LeftIndexProximal": true,
		&"LeftBigToeDistal": true,
		&"RightUpperArm": false,
		&"RightFoot": false,
		&"RightToe5Intermediate": false,
		&"Hips": false,
		&"Spine": false,
		&"Head": false,
		&"Jaw": false,
	}
	for bone_name: StringName in checks:
		var want: bool = checks[bone_name]
		var entry: BoneEntry = bp.bones[bone_name]
		if entry == null:
			return _fail("generator_handedness", "%s missing from bones dict" % bone_name)
		if entry.is_left_side != want:
			return _fail("generator_handedness",
				"%s: is_left_side=%s, expected %s" % [bone_name, entry.is_left_side, want])
	return _ok("generator_handedness")


func _test_bone_profile_generator_rom_spot_checks() -> bool:
	# Sanity-check that ROM defaults reach entries via the full pipeline.
	var bp := _make_humanoid_bone_profile()
	BoneProfileGenerator.generate(bp)

	# Knee: HINGE, flex_max = 135°.
	var knee: BoneEntry = bp.bones[&"LeftLowerLeg"]
	if not is_equal_approx(knee.rom_max.x, deg_to_rad(135.0)):
		return _fail("generator_rom", "LeftLowerLeg flex_max=%f°, expected 135°" %
			rad_to_deg(knee.rom_max.x))

	# Elbow: HINGE, flex_max = 140°.
	var elbow: BoneEntry = bp.bones[&"LeftLowerArm"]
	if not is_equal_approx(elbow.rom_max.x, deg_to_rad(140.0)):
		return _fail("generator_rom", "LeftLowerArm flex_max=%f°, expected 140°" %
			rad_to_deg(elbow.rom_max.x))

	# Shoulder: BALL, abd_max = 180° (UpperArm-specific, canonical anatomy).
	var shoulder: BoneEntry = bp.bones[&"LeftUpperArm"]
	if not is_equal_approx(shoulder.rom_max.z, deg_to_rad(180.0)):
		return _fail("generator_rom", "LeftUpperArm abd_max=%f°, expected 180°" %
			rad_to_deg(shoulder.rom_max.z))

	# Wrist: SADDLE, flex ±55°.
	var wrist: BoneEntry = bp.bones[&"LeftHand"]
	if not is_equal_approx(wrist.rom_min.x, deg_to_rad(-55.0)):
		return _fail("generator_rom", "LeftHand flex_min=%f°, expected -55°" %
			rad_to_deg(wrist.rom_min.x))
	if not is_equal_approx(wrist.rom_max.x, deg_to_rad(55.0)):
		return _fail("generator_rom", "LeftHand flex_max=%f°, expected 55°" %
			rad_to_deg(wrist.rom_max.x))

	# Index proximal: SADDLE-fallback (saddle that's not Hand/Foot), flex 0..90°.
	var idx_prox: BoneEntry = bp.bones[&"LeftIndexProximal"]
	if not is_equal_approx(idx_prox.rom_max.x, deg_to_rad(90.0)):
		return _fail("generator_rom", "LeftIndexProximal flex_max=%f°, expected 90°" %
			rad_to_deg(idx_prox.rom_max.x))
	return _ok("generator_rom_spot_checks")


func _test_bone_profile_generator_root_and_fixed_left_at_defaults() -> bool:
	# ROOT and FIXED bones get an entry but no permutation matcher run, so
	# their permutation stays at BoneEntry defaults (PLUS_X / PLUS_Y / PLUS_Z)
	# and ROM stays at zero (MarionetteRomDefaults zeroes them too).
	var bp := _make_humanoid_bone_profile()
	BoneProfileGenerator.generate(bp)
	for bone_name: StringName in [&"Root", &"Hips", &"Jaw", &"LeftEye", &"RightEye"]:
		var entry: BoneEntry = bp.bones[bone_name]
		if entry == null:
			return _fail("generator_root_fixed", "%s missing" % bone_name)
		if entry.flex_axis != SignedAxis.Axis.PLUS_X \
				or entry.along_bone_axis != SignedAxis.Axis.PLUS_Y \
				or entry.abduction_axis != SignedAxis.Axis.PLUS_Z:
			return _fail("generator_root_fixed",
				"%s permutation should be default (matcher skipped), got (%d,%d,%d)" %
				[bone_name, int(entry.flex_axis), int(entry.along_bone_axis), int(entry.abduction_axis)])
		if entry.rom_min != Vector3.ZERO or entry.rom_max != Vector3.ZERO:
			return _fail("generator_root_fixed",
				"%s ROM should be zero, got min=%s max=%s" % [bone_name, entry.rom_min, entry.rom_max])
	return _ok("generator_root_and_fixed_left_at_defaults")


func _test_bone_profile_generator_idempotent() -> bool:
	# Regenerating overwrites: both runs produce structurally identical entries
	# for the same input. Confirms the generator wholesale-replaces rather than
	# accumulating, and that the pipeline itself is deterministic.
	var bp := _make_humanoid_bone_profile()
	var r1 := BoneProfileGenerator.generate(bp)
	# Snapshot a few fields per bone, then regenerate and compare.
	var snapshot: Dictionary = {}
	for bone_name: StringName in bp.bones.keys():
		var e: BoneEntry = bp.bones[bone_name]
		snapshot[bone_name] = [int(e.archetype), int(e.flex_axis),
			int(e.along_bone_axis), int(e.abduction_axis),
			e.rom_min, e.rom_max, e.is_left_side]

	var r2 := BoneProfileGenerator.generate(bp)
	if r1.generated != r2.generated:
		return _fail("generator_idempotent",
			"generated diverged: r1=%d r2=%d" % [r1.generated, r2.generated])
	if bp.bones.size() != snapshot.size():
		return _fail("generator_idempotent",
			"size diverged: now %d, was %d" % [bp.bones.size(), snapshot.size()])
	for bone_name: StringName in bp.bones.keys():
		if not snapshot.has(bone_name):
			return _fail("generator_idempotent", "new bone after regeneration: %s" % bone_name)
		var e: BoneEntry = bp.bones[bone_name]
		var snap: Array = snapshot[bone_name]
		if int(e.archetype) != snap[0]:
			return _fail("generator_idempotent", "%s archetype drift" % bone_name)
		if int(e.flex_axis) != snap[1] or int(e.along_bone_axis) != snap[2] or int(e.abduction_axis) != snap[3]:
			return _fail("generator_idempotent", "%s permutation drift" % bone_name)
		if e.rom_min != snap[4] or e.rom_max != snap[5]:
			return _fail("generator_idempotent", "%s ROM drift" % bone_name)
		if e.is_left_side != snap[6]:
			return _fail("generator_idempotent", "%s is_left_side drift" % bone_name)
	return _ok("generator_idempotent")


func _generated_joint_world(bp: BoneProfile, bone_name: StringName) -> Basis:
	# Generates the BoneProfile against the template (no live skeleton) and
	# returns the joint-in-world basis for `bone_name` — i.e., what the
	# JointLimitGizmo would draw at that bone if the rig matched the template.
	# Uses the same dispatch as runtime (anatomical_basis_in_bone_local) so
	# unmatched bones with use_calculated_frame=true round-trip via their
	# stored calculated_anatomical_basis.
	var profile: SkeletonProfile = bp.skeleton_profile
	var rests := MuscleFrameBuilder.compute_world_rests(profile)
	var entry: BoneEntry = bp.bones[bone_name]
	var bone_world: Transform3D = rests[bone_name]
	return bone_world.basis * entry.anatomical_basis_in_bone_local()


# Locks down the template-path expectation for shoulder Ball joints. If this
# regresses, the JointLimitGizmo arcs at upper arms drift off-axis on the
# editor visualization.
func _test_generator_template_upper_arm_joint_frame() -> bool:
	var bp := _make_humanoid_bone_profile()
	BoneProfileGenerator.generate(bp)

	# LeftUpperArm bone is at +X (viewer-perspective naming on a +Z-facing
	# character). along = +X. Flex = along × forward = +X × +Z = -Y. Motion
	# = flex × along = -Y × +X = +Z (anatomical forward), the "raise arm
	# forward" direction.
	var left := _generated_joint_world(bp, &"LeftUpperArm")
	if not left.y.is_equal_approx(Vector3(1, 0, 0)):
		return _fail("template_upper_arm",
			"LeftUpperArm along=%v, expected (1,0,0)" % left.y)
	if not left.x.is_equal_approx(Vector3(0, -1, 0)):
		return _fail("template_upper_arm",
			"LeftUpperArm flex=%v, expected (0,-1,0)" % left.x)
	# RightUpperArm bone is at -X. flex = along × forward = -X × +Z = +Y, the
	# opposite of the left side. Same +flex slider on both sides rotates each
	# arm forward.
	var right := _generated_joint_world(bp, &"RightUpperArm")
	if not right.y.is_equal_approx(Vector3(-1, 0, 0)):
		return _fail("template_upper_arm",
			"RightUpperArm along=%v, expected (-1,0,0)" % right.y)
	if not right.x.is_equal_approx(Vector3(0, 1, 0)):
		return _fail("template_upper_arm",
			"RightUpperArm flex=%v, expected (0,1,0)" % right.x)
	return _ok("generator_template_upper_arm_joint_frame")


# Same lock-down for hip Ball joints. Legs hang down in the template, so
# along = -Y world for both sides.
func _test_generator_template_upper_leg_joint_frame() -> bool:
	var bp := _make_humanoid_bone_profile()
	BoneProfileGenerator.generate(bp)
	var left := _generated_joint_world(bp, &"LeftUpperLeg")
	if not left.y.is_equal_approx(Vector3(0, -1, 0)):
		return _fail("template_upper_leg",
			"LeftUpperLeg along=%v, expected (0,-1,0)" % left.y)
	# Hip flex axis: along × forward = -Y × +Z = -X. Same axis for both sides
	# (along is the same vertical-down for both hips), so the +flex direction
	# wraps both legs forward. The lateral fallback (limb_flex_axis sign-by-
	# side) is no longer used — anatomical_flex_axis derives from along×target
	# directly.
	if not left.x.is_equal_approx(Vector3(-1, 0, 0)):
		return _fail("template_upper_leg",
			"LeftUpperLeg flex=%v, expected (-1,0,0)" % left.x)
	var right := _generated_joint_world(bp, &"RightUpperLeg")
	if not right.y.is_equal_approx(Vector3(0, -1, 0)):
		return _fail("template_upper_leg",
			"RightUpperLeg along=%v, expected (0,-1,0)" % right.y)
	if not right.x.is_equal_approx(Vector3(-1, 0, 0)):
		return _fail("template_upper_leg",
			"RightUpperLeg flex=%v, expected (-1,0,0)" % right.x)
	return _ok("generator_template_upper_leg_joint_frame")


func _test_bone_profile_generator_preserves_missing_rig_bones() -> bool:
	# Calibrating against a partial live rig should not shrink the BoneProfile
	# dict. Bones absent from the live skeleton stay at their previous
	# (template-derived) entries, and the report logs them under preserved.
	var bp := _make_humanoid_bone_profile()
	BoneProfileGenerator.generate(bp)
	if bp.bones.size() != 84:
		return _fail("generator_preserves_missing", "template-path size %d != 84" % bp.bones.size())

	# Synthetic 5-bone partial rig: just enough for the muscle-frame builder
	# (LeftUpperLeg + RightUpperLeg + Head). Profile-name match — no BoneMap
	# entries needed; the generator falls back to direct-match resolution.
	var skel := Skeleton3D.new()
	skel.name = "Skeleton3D"
	skel.add_bone("Hips")                    # 0
	skel.set_bone_rest(0, Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0)))
	skel.add_bone("LeftUpperLeg")            # 1
	skel.set_bone_parent(1, 0)
	skel.set_bone_rest(1, Transform3D(Basis.IDENTITY, Vector3(0.1, 0.0, 0.0)))
	skel.add_bone("RightUpperLeg")           # 2
	skel.set_bone_parent(2, 0)
	skel.set_bone_rest(2, Transform3D(Basis.IDENTITY, Vector3(-0.1, 0.0, 0.0)))
	skel.add_bone("Spine")                   # 3
	skel.set_bone_parent(3, 0)
	skel.set_bone_rest(3, Transform3D(Basis.IDENTITY, Vector3(0.0, 0.2, 0.0)))
	skel.add_bone("Head")                    # 4
	skel.set_bone_parent(4, 3)
	skel.set_bone_rest(4, Transform3D(Basis.IDENTITY, Vector3(0.0, 0.4, 0.0)))

	var bm := BoneMap.new()
	bm.profile = bp.skeleton_profile

	var report := BoneProfileGenerator.generate(bp, skel, bm)
	if report.error != "":
		skel.free()
		return _fail("generator_preserves_missing", "report.error=%s" % report.error)
	# 5 bones present in the partial rig should be regenerated; the other 79
	# should be preserved from the template pass.
	if report.generated != 5:
		skel.free()
		return _fail("generator_preserves_missing",
			"generated=%d, expected 5 (Hips/LUL/RUL/Spine/Head)" % report.generated)
	if report.preserved != 79:
		skel.free()
		return _fail("generator_preserves_missing",
			"preserved=%d, expected 79 (84 - 5)" % report.preserved)
	if bp.bones.size() != 84:
		skel.free()
		return _fail("generator_preserves_missing",
			"final size=%d, expected 84 (no entries lost)" % bp.bones.size())
	skel.free()
	return _ok("generator_preserves_missing_rig_bones")


func _test_bone_profile_generator_null_skeleton_profile_errors() -> bool:
	# Friendly error rather than a crash when the profile isn't wired up.
	var bp := BoneProfile.new()
	var report := BoneProfileGenerator.generate(bp)
	if report.error == "":
		return _fail("generator_null_skel", "expected non-empty error message")
	if report.generated != 0:
		return _fail("generator_null_skel", "generated=%d, expected 0" % report.generated)
	if bp.bones.size() != 0:
		return _fail("generator_null_skel", "bones not empty after error")
	# Null bone_profile too.
	var report2 := BoneProfileGenerator.generate(null)
	if report2.error == "":
		return _fail("generator_null_skel", "null bone_profile should yield error")
	return _ok("generator_null_skeleton_profile_errors")


# ---------- BoneStateProfile (P3.3) ----------

func _test_bone_state_profile_humanoid_defaults() -> bool:
	var profile := load(HUMANOID_PROFILE_PATH) as SkeletonProfile
	var bsp := BoneStateProfile.default_for_skeleton_profile(profile)
	if bsp.states.size() != 84:
		return _fail("bone_state_humanoid", "states.size()=%d, expected 84" % bsp.states.size())
	# Jaw + eyes Kinematic per CLAUDE.md §9.
	for n: StringName in [&"Jaw", &"LeftEye", &"RightEye"]:
		if bsp.states[n] != BoneStateProfile.State.KINEMATIC:
			return _fail("bone_state_humanoid", "%s should be KINEMATIC" % n)
	# Body bones Powered.
	for n: StringName in [&"LeftUpperArm", &"Spine", &"Hips", &"LeftFoot", &"Head"]:
		if bsp.states[n] != BoneStateProfile.State.POWERED:
			return _fail("bone_state_humanoid", "%s should be POWERED" % n)
	return _ok("bone_state_profile_humanoid_defaults")


func _test_bone_state_profile_get_state_fallback() -> bool:
	# Bones not in the dict default to POWERED — gameplay shouldn't crash on
	# unmapped names from forgotten profile updates.
	var bsp := BoneStateProfile.new()
	if bsp.get_state(&"NotARealBone") != BoneStateProfile.State.POWERED:
		return _fail("bone_state_fallback", "unmapped bone should fall back to POWERED")
	bsp.states[&"X"] = BoneStateProfile.State.UNPOWERED
	if bsp.get_state(&"X") != BoneStateProfile.State.UNPOWERED:
		return _fail("bone_state_fallback", "explicit state not honored")
	return _ok("bone_state_profile_get_state_fallback")


# ---------- CollisionExclusionProfile (P3.4) ----------

func _make_3bone_skeleton() -> Skeleton3D:
	# Root (idx 0) -> Hips (idx 1) -> LeftUpperLeg (idx 2). Names match the
	# canonical SkeletonProfile names so build_ragdoll resolves entries via
	# the direct-match fallback (no BoneMap needed).
	var skel := Skeleton3D.new()
	skel.name = "Skeleton3D"
	skel.add_bone("Root")
	skel.add_bone("Hips")
	skel.set_bone_parent(1, 0)
	skel.add_bone("LeftUpperLeg")
	skel.set_bone_parent(2, 1)
	skel.set_bone_rest(0, Transform3D.IDENTITY)
	skel.set_bone_rest(1, Transform3D(Basis.IDENTITY, Vector3(0.0, 0.75, 0.0)))
	skel.set_bone_rest(2, Transform3D(Basis.IDENTITY, Vector3(0.1, 0.0, 0.0)))
	return skel


func _test_collision_exclusion_parent_child_defaults() -> bool:
	var skel := _make_3bone_skeleton()
	var p := CollisionExclusionProfile.parent_child_defaults(skel)
	if p.excluded_pairs.size() != 2:
		skel.free()
		return _fail("col_excl_pc", "expected 2 pairs, got %d" % p.excluded_pairs.size())
	if not p.excluded_pairs.has(Vector2i(0, 1)):
		skel.free()
		return _fail("col_excl_pc", "missing (Root,Hips)")
	if not p.excluded_pairs.has(Vector2i(1, 2)):
		skel.free()
		return _fail("col_excl_pc", "missing (Hips,LeftUpperLeg)")
	skel.free()
	return _ok("collision_exclusion_parent_child_defaults")


func _test_collision_exclusion_siblings() -> bool:
	# Add a second child under Hips so include_siblings has work to do.
	var skel := _make_3bone_skeleton()
	skel.add_bone("RightUpperLeg")  # idx 3
	skel.set_bone_parent(3, 1)
	skel.set_bone_rest(3, Transform3D(Basis.IDENTITY, Vector3(-0.1, 0.0, 0.0)))

	var no_sib := CollisionExclusionProfile.parent_child_defaults(skel, false)
	# Pairs: 0-1, 1-2, 1-3 = 3 pairs without siblings
	if no_sib.excluded_pairs.size() != 3:
		skel.free()
		return _fail("col_excl_sib", "no-sibling pass: expected 3 pairs, got %d" % no_sib.excluded_pairs.size())

	var with_sib := CollisionExclusionProfile.parent_child_defaults(skel, true)
	# Adds (2,3) sibling pair.
	if with_sib.excluded_pairs.size() != 4:
		skel.free()
		return _fail("col_excl_sib", "with-siblings: expected 4 pairs, got %d" % with_sib.excluded_pairs.size())
	if not with_sib.excluded_pairs.has(Vector2i(2, 3)):
		skel.free()
		return _fail("col_excl_sib", "missing sibling pair (LeftUpperLeg,RightUpperLeg)")
	skel.free()
	return _ok("collision_exclusion_siblings")


func _test_collision_exclusion_disabled_bones() -> bool:
	var p := CollisionExclusionProfile.new()
	p.disabled_bones.append("Jaw")
	if not p.is_disabled(&"Jaw"):
		return _fail("col_excl_disabled", "Jaw should be disabled")
	if p.is_disabled(&"Spine"):
		return _fail("col_excl_disabled", "Spine should not be disabled")
	return _ok("collision_exclusion_disabled_bones")


# ---------- MarionetteBone (P3.2) + Marionette.build_ragdoll (P3.7) ----------

func _test_marionette_bone_extends_physical_bone3d() -> bool:
	# Phase 5 Slice 2: MarionetteBone moved from GDScript class_name to a C++
	# GDExtension class. Identifier-based MarionetteBone.new() can't resolve
	# at parse time in `--script` runs (registration is at SCENE init level,
	# after the parser); go through ClassDB.
	if not ClassDB.class_exists("MarionetteBone"):
		return _fail("marionette_bone_extends_physical_bone3d", "MarionetteBone not registered")
	if not ClassDB.is_parent_class("MarionetteBone", "PhysicalBone3D"):
		return _fail("marionette_bone_extends_physical_bone3d", "MarionetteBone does not extend PhysicalBone3D")
	var bone: Object = ClassDB.instantiate("MarionetteBone")
	if bone == null:
		return _fail("marionette_bone_extends_physical_bone3d", "instantiate returned null")
	var entry := BoneEntry.new()
	bone.set("bone_entry", entry)
	var got: Resource = bone.get("bone_entry")
	if got != entry:
		bone.free()
		return _fail("marionette_bone_extends_physical_bone3d", "bone_entry property round-trip failed")
	bone.free()
	return _ok("marionette_bone_extends_physical_bone3d")


# Builds a Marionette wired to a 3-bone synthetic skeleton, populates the
# BoneProfile with hand-crafted entries (so we control the permutation /
# ROM exactly), and runs build_ragdoll. Caller is responsible for
# free()-ing the returned Marionette.
func _build_synthetic_marionette() -> Marionette:
	var skel := _make_3bone_skeleton()
	var marionette := Marionette.new()
	marionette.name = "Marionette"
	marionette.add_child(skel)
	marionette.skeleton = NodePath("Skeleton3D")

	var skel_profile := load(HUMANOID_PROFILE_PATH) as SkeletonProfile
	var bp := BoneProfile.new()
	bp.skeleton_profile = skel_profile

	var root_entry := BoneEntry.new()
	root_entry.archetype = BoneArchetype.Type.ROOT
	bp.bones[&"Root"] = root_entry

	var hip_entry := BoneEntry.new()
	hip_entry.archetype = BoneArchetype.Type.ROOT
	bp.bones[&"Hips"] = hip_entry

	var leg_entry := BoneEntry.new()
	leg_entry.archetype = BoneArchetype.Type.BALL
	# Pick a non-identity permutation so joint_rotation baking has something
	# observable: bone-local +Y becomes flex, +Z becomes along-bone, +X abd.
	leg_entry.flex_axis = SignedAxis.Axis.PLUS_Y
	leg_entry.along_bone_axis = SignedAxis.Axis.PLUS_Z
	leg_entry.abduction_axis = SignedAxis.Axis.PLUS_X
	leg_entry.rom_min = Vector3(deg_to_rad(-15.0), deg_to_rad(-45.0), 0.0)
	leg_entry.rom_max = Vector3(deg_to_rad(100.0), deg_to_rad(45.0), deg_to_rad(40.0))
	bp.bones[&"LeftUpperLeg"] = leg_entry

	marionette.bone_profile = bp
	root.add_child(marionette)
	marionette.build_ragdoll()
	return marionette


func _find_simulator(marionette: Marionette) -> PhysicalBoneSimulator3D:
	var skel: Skeleton3D = marionette.resolve_skeleton()
	if skel == null:
		return null
	for child: Node in skel.get_children():
		if child is PhysicalBoneSimulator3D:
			return child
	return null


func _find_bone(sim: PhysicalBoneSimulator3D, bone_name: String) -> MarionetteBone:
	for child: Node in sim.get_children():
		if child is MarionetteBone and (child as MarionetteBone).bone_name == bone_name:
			return child
	return null


func _test_build_ragdoll_synthetic_structure() -> bool:
	var m := _build_synthetic_marionette()
	var sim := _find_simulator(m)
	if sim == null:
		m.free()
		return _fail("build_ragdoll_struct", "no PhysicalBoneSimulator3D under Skeleton3D")
	if String(sim.name) != "MarionetteSim":
		m.free()
		return _fail("build_ragdoll_struct", "sim name=%s, expected MarionetteSim" % sim.name)

	var bone_count: int = 0
	for child: Node in sim.get_children():
		if child is MarionetteBone:
			bone_count += 1
	if bone_count != 3:
		m.free()
		return _fail("build_ragdoll_struct", "expected 3 MarionetteBones, got %d" % bone_count)

	var leg := _find_bone(sim, "LeftUpperLeg")
	if leg == null:
		m.free()
		return _fail("build_ragdoll_struct", "LeftUpperLeg bone missing")
	if leg.joint_type != PhysicalBone3D.JOINT_TYPE_6DOF:
		m.free()
		return _fail("build_ragdoll_struct", "joint_type=%d, expected 6DOF" % leg.joint_type)
	# bone_entry forwarded.
	if leg.bone_entry == null:
		m.free()
		return _fail("build_ragdoll_struct", "bone_entry not forwarded")
	if leg.bone_entry.archetype != BoneArchetype.Type.BALL:
		m.free()
		return _fail("build_ragdoll_struct", "bone_entry.archetype mismatch")
	# Has a CollisionShape3D child.
	var has_shape := false
	for child: Node in leg.get_children():
		if child is CollisionShape3D:
			has_shape = true
			break
	if not has_shape:
		m.free()
		return _fail("build_ragdoll_struct", "no CollisionShape3D on bone")
	m.free()
	return _ok("build_ragdoll_synthetic_structure")


func _test_build_ragdoll_joint_rotation_baking() -> bool:
	# joint_rotation should bake the bone_to_anatomical permutation. With the
	# leg entry's permutation (flex=+Y, along=+Z, abd=+X), the joint frame
	# basis is the rotation that maps identity to those columns. Round-trip
	# via Basis.from_euler should reproduce that basis.
	var m := _build_synthetic_marionette()
	var sim := _find_simulator(m)
	var leg := _find_bone(sim, "LeftUpperLeg")
	if leg == null:
		m.free()
		return _fail("build_ragdoll_jr", "leg bone missing")

	var expected: Basis = leg.bone_entry.bone_to_anatomical_basis()
	var got: Basis = Basis.from_euler(leg.joint_rotation)
	if not got.is_equal_approx(expected):
		m.free()
		return _fail("build_ragdoll_jr",
			"joint_rotation basis %s, expected %s" % [got, expected])
	m.free()
	return _ok("build_ragdoll_joint_rotation_baking")


func _test_bone_entry_anatomical_basis_branches_on_flag() -> bool:
	# Default (use_calculated_frame=false) returns the signed-permutation
	# basis built from the *_axis enums. Flipping the flag returns the stored
	# calculated_anatomical_basis verbatim so non-axis-aligned rigs survive.
	var entry := BoneEntry.new()
	entry.flex_axis = SignedAxis.Axis.PLUS_Y
	entry.along_bone_axis = SignedAxis.Axis.PLUS_Z
	entry.abduction_axis = SignedAxis.Axis.PLUS_X
	var perm_expected := Basis(Vector3.UP, Vector3.BACK, Vector3.RIGHT)
	if not entry.anatomical_basis_in_bone_local().is_equal_approx(perm_expected):
		return _fail("entry_basis_branch", "default (matched) path didn't return signed-permutation basis")

	# Pick a non-axis-aligned basis: rotate identity 30° around X. Stored
	# verbatim and returned when flag flips.
	var calculated := Basis.IDENTITY.rotated(Vector3.RIGHT, deg_to_rad(30.0))
	entry.calculated_anatomical_basis = calculated
	entry.use_calculated_frame = true
	if not entry.anatomical_basis_in_bone_local().is_equal_approx(calculated):
		return _fail("entry_basis_branch", "flag-on path didn't return calculated basis")
	return _ok("bone_entry_anatomical_basis_branches_on_flag")


func _test_build_ragdoll_bakes_calculated_frame_when_flag_set() -> bool:
	# When the generator falls back (use_calculated_frame=true), build_ragdoll
	# bakes calculated_anatomical_basis into joint_rotation directly instead
	# of the signed-permutation basis. Round-trip via Basis.from_euler.
	var skel := _make_3bone_skeleton()
	var marionette := Marionette.new()
	marionette.name = "Marionette"
	marionette.add_child(skel)
	marionette.skeleton = NodePath("Skeleton3D")

	var bp := BoneProfile.new()
	bp.skeleton_profile = load(HUMANOID_PROFILE_PATH) as SkeletonProfile
	bp.bones[&"Root"] = BoneEntry.new()
	bp.bones[&"Root"].archetype = BoneArchetype.Type.ROOT
	bp.bones[&"Hips"] = BoneEntry.new()
	bp.bones[&"Hips"].archetype = BoneArchetype.Type.ROOT

	var leg_entry := BoneEntry.new()
	leg_entry.archetype = BoneArchetype.Type.BALL
	# A non-axis-aligned target frame the matcher could never reproduce with
	# 24 signed-permutation candidates (it's 30° off every axis pair).
	leg_entry.calculated_anatomical_basis = Basis.IDENTITY \
			.rotated(Vector3.RIGHT, deg_to_rad(30.0)) \
			.rotated(Vector3.UP, deg_to_rad(20.0))
	leg_entry.use_calculated_frame = true
	leg_entry.rom_min = Vector3.ZERO
	leg_entry.rom_max = Vector3(deg_to_rad(20.0), 0.0, 0.0)
	bp.bones[&"LeftUpperLeg"] = leg_entry

	marionette.bone_profile = bp
	root.add_child(marionette)
	marionette.build_ragdoll()

	var sim := _find_simulator(marionette)
	var leg := _find_bone(sim, "LeftUpperLeg")
	if leg == null:
		marionette.free()
		return _fail("build_ragdoll_calc_frame", "leg bone missing")

	var expected: Basis = leg_entry.calculated_anatomical_basis
	var got: Basis = Basis.from_euler(leg.joint_rotation)
	if not got.is_equal_approx(expected):
		marionette.free()
		return _fail("build_ragdoll_calc_frame",
			"joint_rotation basis %s, expected calculated %s" % [got, expected])
	marionette.free()
	return _ok("build_ragdoll_bakes_calculated_frame_when_flag_set")


func _test_build_ragdoll_rom_round_trip() -> bool:
	# Each angular limit should round-trip from BoneEntry through the dynamic
	# property paths. linear_limits should be locked to (0, 0).
	var m := _build_synthetic_marionette()
	var sim := _find_simulator(m)
	var leg := _find_bone(sim, "LeftUpperLeg")
	var entry := leg.bone_entry

	# _apply_joint_constraints writes degrees (Jolt unit quirk fix in slice 3)
	# — convert expected values from rad to deg before compare. LeftUpperLeg
	# is BALL: no HINGE X-flip, no mirror_abd.
	var checks := {
		"joint_constraints/x/angular_limit_lower": rad_to_deg(entry.rom_min.x),
		"joint_constraints/x/angular_limit_upper": rad_to_deg(entry.rom_max.x),
		"joint_constraints/y/angular_limit_lower": rad_to_deg(entry.rom_min.y),
		"joint_constraints/y/angular_limit_upper": rad_to_deg(entry.rom_max.y),
		"joint_constraints/z/angular_limit_lower": rad_to_deg(entry.rom_min.z),
		"joint_constraints/z/angular_limit_upper": rad_to_deg(entry.rom_max.z),
	}
	for path: String in checks:
		var got: float = leg.get(path)
		var want: float = checks[path]
		if not is_equal_approx(got, want):
			m.free()
			return _fail("build_ragdoll_rom",
				"%s = %f, expected %f" % [path, got, want])
	# Linear axes locked to zero.
	for axis: String in ["x", "y", "z"]:
		var lo: float = leg.get("joint_constraints/%s/linear_limit_lower" % axis)
		var hi: float = leg.get("joint_constraints/%s/linear_limit_upper" % axis)
		if not is_equal_approx(lo, 0.0) or not is_equal_approx(hi, 0.0):
			m.free()
			return _fail("build_ragdoll_rom",
				"linear_limit_%s not locked: [%f, %f]" % [axis, lo, hi])
	m.free()
	return _ok("build_ragdoll_rom_round_trip")


func _test_build_ragdoll_idempotent() -> bool:
	# Calling build_ragdoll twice should not stack simulators — the second
	# call clears the first.
	var m := _build_synthetic_marionette()
	m.build_ragdoll()  # second call

	var skel: Skeleton3D = m.resolve_skeleton()
	var sim_count: int = 0
	for child: Node in skel.get_children():
		if child is PhysicalBoneSimulator3D:
			sim_count += 1
	if sim_count != 1:
		m.free()
		return _fail("build_ragdoll_idempotent", "expected 1 simulator after rebuild, got %d" % sim_count)

	# Clear should remove it cleanly.
	m.clear_ragdoll()
	var still: int = 0
	for child: Node in skel.get_children():
		if child is PhysicalBoneSimulator3D:
			still += 1
	if still != 0:
		m.free()
		return _fail("build_ragdoll_idempotent", "clear_ragdoll left %d simulators" % still)
	m.free()
	return _ok("build_ragdoll_idempotent")


func _test_build_ragdoll_skips_unknown_bones() -> bool:
	# Skeleton bones with no BoneProfile entry are silently skipped. Construct
	# a 4-bone skeleton (extra cosmetic bone) but only populate 3 entries.
	var skel := _make_3bone_skeleton()
	skel.add_bone("CosmeticTail")  # idx 3, no profile entry
	skel.set_bone_parent(3, 0)
	skel.set_bone_rest(3, Transform3D(Basis.IDENTITY, Vector3(0.0, -0.1, 0.0)))

	var marionette := Marionette.new()
	marionette.name = "Marionette"
	marionette.add_child(skel)
	marionette.skeleton = NodePath("Skeleton3D")

	var bp := BoneProfile.new()
	bp.skeleton_profile = load(HUMANOID_PROFILE_PATH) as SkeletonProfile
	var generic_entry := BoneEntry.new()
	generic_entry.archetype = BoneArchetype.Type.ROOT
	bp.bones[&"Root"] = generic_entry
	bp.bones[&"Hips"] = generic_entry
	bp.bones[&"LeftUpperLeg"] = generic_entry
	marionette.bone_profile = bp

	root.add_child(marionette)
	marionette.build_ragdoll()

	var sim: PhysicalBoneSimulator3D = null
	for child: Node in skel.get_children():
		if child is PhysicalBoneSimulator3D:
			sim = child
			break
	var bone_count: int = 0
	for child: Node in sim.get_children():
		if child is MarionetteBone:
			bone_count += 1
	if bone_count != 3:
		marionette.free()
		return _fail("build_ragdoll_skip",
			"expected 3 bones (cosmetic skipped), got %d" % bone_count)
	# CosmeticTail bone should not exist.
	if _find_bone(sim, "CosmeticTail") != null:
		marionette.free()
		return _fail("build_ragdoll_skip", "CosmeticTail should have been skipped")
	marionette.free()
	return _ok("build_ragdoll_skips_unknown_bones")


# ---------- AnatomicalPose (P4.4) ----------

func _test_anatomical_pose_zero_yields_identity() -> bool:
	var entry := BoneEntry.new()
	var q := AnatomicalPose.bone_local_rotation(entry, 0.0, 0.0, 0.0)
	if not q.is_equal_approx(Quaternion.IDENTITY):
		return _fail("anatomical_pose_zero", "zero angles → %s, expected IDENTITY" % q)
	# Null entry must also degrade to IDENTITY (matches the early-return in
	# AnatomicalPose.bone_local_rotation; defends inspector-time bones with
	# no BoneEntry yet).
	var q_null := AnatomicalPose.bone_local_rotation(null, 1.0, 1.0, 1.0)
	if not q_null.is_equal_approx(Quaternion.IDENTITY):
		return _fail("anatomical_pose_zero", "null entry → %s, expected IDENTITY" % q_null)
	return _ok("anatomical_pose_zero_yields_identity")


func _test_anatomical_pose_single_axis_flex_default_permutation() -> bool:
	# Default BoneEntry: flex=+X, along=+Y, abd=+Z. flex-only input must
	# collapse to a pure rotation around bone-local +X.
	var entry := BoneEntry.new()
	var angle := deg_to_rad(30.0)
	var q := AnatomicalPose.bone_local_rotation(entry, angle, 0.0, 0.0)
	var expected := Quaternion(Vector3(1.0, 0.0, 0.0), angle)
	if not q.is_equal_approx(expected):
		return _fail("anatomical_pose_default_flex", "got %s, expected %s" % [q, expected])
	return _ok("anatomical_pose_single_axis_flex_default_permutation")


func _test_anatomical_pose_permuted_flex_axis() -> bool:
	# Bone-local +Z encodes flex (e.g., a roll-rotated rest basis). Single-axis
	# flex must rotate around +Z, not +X.
	var entry := BoneEntry.new()
	entry.flex_axis = SignedAxis.Axis.PLUS_Z
	var angle := deg_to_rad(45.0)
	var q := AnatomicalPose.bone_local_rotation(entry, angle, 0.0, 0.0)
	var expected := Quaternion(Vector3(0.0, 0.0, 1.0), angle)
	if not q.is_equal_approx(expected):
		return _fail("anatomical_pose_permuted_flex", "got %s, expected %s" % [q, expected])
	return _ok("anatomical_pose_permuted_flex_axis")


func _test_anatomical_pose_negative_axis() -> bool:
	# -X flex axis: flex by +θ should rotate around -X by θ, equivalently +X
	# by -θ. Catches sign-bit drops in SignedAxis.to_vector3 wiring.
	var entry := BoneEntry.new()
	entry.flex_axis = SignedAxis.Axis.MINUS_X
	var angle := deg_to_rad(60.0)
	var q := AnatomicalPose.bone_local_rotation(entry, angle, 0.0, 0.0)
	var expected := Quaternion(Vector3(-1.0, 0.0, 0.0), angle)
	if not q.is_equal_approx(expected):
		return _fail("anatomical_pose_negative_axis", "got %s, expected %s" % [q, expected])
	var equiv := Quaternion(Vector3(1.0, 0.0, 0.0), -angle)
	if not q.is_equal_approx(equiv):
		return _fail("anatomical_pose_negative_axis",
				"-X by +θ should equal +X by -θ; got %s" % q)
	return _ok("anatomical_pose_negative_axis")


func _test_anatomical_pose_compose_order() -> bool:
	# Default permutation. flex=π/2 around +X composed with rot=π/2 around +Y
	# yields q = qx * qy (the code's order). Probing q against bone-local +Y:
	#   intrinsic order qx*qy:  qy(+Y)=+Y → qx(+Y)=+Z
	#   extrinsic flip qy*qx:   qx(+Y)=+Z → qy(+Z)=+X  (must NOT be this)
	# This is the discriminating probe — every other axis-input also differs
	# between the two orders, but +Y → +Z is the cleanest readout.
	var entry := BoneEntry.new()
	var q := AnatomicalPose.bone_local_rotation(entry, PI / 2.0, PI / 2.0, 0.0)
	var probe := q * Vector3.UP
	if not probe.is_equal_approx(Vector3(0.0, 0.0, 1.0)):
		return _fail("anatomical_pose_compose",
				"intrinsic flex-then-rot on +Y should give +Z, got %s" % probe)
	if probe.is_equal_approx(Vector3(1.0, 0.0, 0.0)):
		return _fail("anatomical_pose_compose",
				"extrinsic compose order detected (q*+Y = +X)")
	return _ok("anatomical_pose_compose_order")


# ---------- MarionetteBoneSliders (P4 inspector slider widget) ----------

# Reuses _build_synthetic_marionette: LeftUpperLeg has all three ROM axes
# non-zero with permuted basis (flex=+Y, along=+Z, abd=+X), so all three
# sliders instantiate and a flex-only nudge produces a pure +Y rotation.
#
# Two harness quirks shape these tests:
#   1. `_ready` doesn't auto-fire and `value_changed` doesn't propagate when
#      a Control isn't inside the active scene tree. Headless SceneTree
#      tests run synchronously in `_init`, so we drive the widget's
#      lifecycle (`_ready`, `_apply_pose`, `_exit_tree`) directly. The
#      signal connection itself is editor plumbing — verified in-editor,
#      not in unit tests.
#   2. `Skeleton3D.set/get_bone_pose_rotation` round-trips through Basis,
#      which adds ~2e-4 of quaternion noise (Quaternion.is_equal_approx
#      uses 1e-5 — too tight). Tests use _quat_close which compares via
#      Quaternion.angle_to with a generous-but-conclusive 1e-3 rad bound.
const _QUAT_TOL_RAD: float = 1.0e-3


func _quat_close(a: Quaternion, b: Quaternion) -> bool:
	return a.angle_to(b) < _QUAT_TOL_RAD


func _test_muscle_slider_applies_pose() -> bool:
	var m := _build_synthetic_marionette()
	var sim := _find_simulator(m)
	var bone := _find_bone(sim, "LeftUpperLeg")
	if bone == null:
		m.free()
		return _fail("muscle_slider_applies", "LeftUpperLeg MarionetteBone missing")
	var skel: Skeleton3D = m.resolve_skeleton()
	var bone_idx := skel.find_bone("LeftUpperLeg")
	var rest := skel.get_bone_pose_rotation(bone_idx)

	var widget := MarionetteBoneSliders.new(bone)
	widget._ready()
	if widget._flex_slider == null:
		widget.free()
		m.free()
		return _fail("muscle_slider_applies", "flex slider not built — check ROM gating")

	widget._flex_slider.value = deg_to_rad(30.0)
	var quantized: float = widget._flex_slider.value
	widget._apply_pose()

	var actual := skel.get_bone_pose_rotation(bone_idx)
	# LeftUpperLeg flex_axis = +Y in our synthetic permutation.
	var expected := rest * Quaternion(Vector3.UP, quantized)
	var ok := _quat_close(actual, expected)

	widget._exit_tree()
	widget.free()
	m.free()
	if not ok:
		return _fail("muscle_slider_applies",
				"pose=%s, expected=%s, angle_to=%f" %
				[actual, expected, actual.angle_to(expected)])
	return _ok("muscle_slider_applies_pose")


func _test_muscle_slider_restores_rest_on_exit_tree() -> bool:
	var m := _build_synthetic_marionette()
	var sim := _find_simulator(m)
	var bone := _find_bone(sim, "LeftUpperLeg")
	var skel: Skeleton3D = m.resolve_skeleton()
	var bone_idx := skel.find_bone("LeftUpperLeg")
	var rest := skel.get_bone_pose_rotation(bone_idx)

	var widget := MarionetteBoneSliders.new(bone)
	widget._ready()
	if widget._flex_slider == null:
		widget.free()
		m.free()
		return _fail("muscle_slider_restore", "flex slider not built")

	widget._flex_slider.value = deg_to_rad(45.0)
	widget._apply_pose()
	var moved := skel.get_bone_pose_rotation(bone_idx)
	if _quat_close(moved, rest):
		widget._exit_tree()
		widget.free()
		m.free()
		return _fail("muscle_slider_restore", "_apply_pose did not displace pose")

	# Inspector deselection in production runs via NOTIFICATION_EXIT_TREE →
	# _exit_tree → _restore_rest. We invoke _exit_tree directly.
	widget._exit_tree()
	var after := skel.get_bone_pose_rotation(bone_idx)
	var ok := _quat_close(after, rest)

	widget.free()
	m.free()
	if not ok:
		return _fail("muscle_slider_restore",
				"after exit_tree=%s, rest=%s" % [after, rest])
	return _ok("muscle_slider_restores_rest_on_exit_tree")


func _test_muscle_slider_reset_button() -> bool:
	var m := _build_synthetic_marionette()
	var sim := _find_simulator(m)
	var bone := _find_bone(sim, "LeftUpperLeg")
	var skel: Skeleton3D = m.resolve_skeleton()
	var bone_idx := skel.find_bone("LeftUpperLeg")
	var rest := skel.get_bone_pose_rotation(bone_idx)

	var widget := MarionetteBoneSliders.new(bone)
	widget._ready()
	if widget._flex_slider == null or widget._abd_slider == null:
		widget.free()
		m.free()
		return _fail("muscle_slider_reset", "expected sliders not built")

	widget._flex_slider.value = deg_to_rad(40.0)
	widget._abd_slider.value = deg_to_rad(20.0)
	widget._apply_pose()
	var moved := skel.get_bone_pose_rotation(bone_idx)
	if _quat_close(moved, rest):
		widget._exit_tree()
		widget.free()
		m.free()
		return _fail("muscle_slider_reset", "_apply_pose did not displace pose pre-reset")

	widget.reset_to_rest()
	var after := skel.get_bone_pose_rotation(bone_idx)
	var pose_restored := _quat_close(after, rest)

	widget.free()
	m.free()
	if not pose_restored:
		return _fail("muscle_slider_reset",
				"pose after reset=%s, rest=%s" % [after, rest])
	return _ok("muscle_slider_reset_button")


# ---------- P5.8 / slice 8a — mode toggle + rest-pose guard ----------

# When the slider is in Ragdoll Test mode, dragging it must not call
# `Skeleton3D.set_bone_pose_rotation` — SPD owns the bone pose. We assert
# the skeleton's pose stays at rest even after a slider value change +
# `_apply_pose()` call.
func _test_muscle_slider_kinematic_write_gated_in_ragdoll_test() -> bool:
	var m := _build_synthetic_marionette()
	var sim := _find_simulator(m)
	var bone := _find_bone(sim, "LeftUpperLeg")
	if bone == null:
		m.free()
		return _fail("muscle_slider_gated_in_ragdoll_test", "LeftUpperLeg missing")
	var skel: Skeleton3D = m.resolve_skeleton()
	var bone_idx := skel.find_bone("LeftUpperLeg")
	var rest := skel.get_bone_pose_rotation(bone_idx)

	var widget := MarionetteBoneSliders.new(bone)
	widget._ready()
	if widget._flex_slider == null:
		widget.free()
		m.free()
		return _fail("muscle_slider_gated_in_ragdoll_test", "flex slider missing")
	widget.set_mode(MarionetteBoneSliders.Mode.RAGDOLL_TEST)

	# Move the slider + force _apply_pose. The skeleton's pose should not
	# move because the kinematic write is gated.
	widget._flex_slider.value = deg_to_rad(30.0)
	widget._apply_pose()
	var after := skel.get_bone_pose_rotation(bone_idx)
	var unchanged := _quat_close(after, rest)

	widget._exit_tree()
	widget.free()
	m.free()
	if not unchanged:
		return _fail("muscle_slider_gated_in_ragdoll_test",
				"skeleton pose moved despite RAGDOLL_TEST mode: pose=%s rest=%s" %
				[after, rest])
	return _ok("muscle_slider_kinematic_write_gated_in_ragdoll_test")


# Dock entry into Ragdoll Test must (1) build the ragdoll if not built and
# (2) write gravity_scale=0 on the Marionette. We instantiate the dock
# directly and drive `_enter_mode` without going through the EditorInterface
# selection path.
func _test_muscle_test_dock_enter_ragdoll_test_zeros_gravity() -> bool:
	var m := _build_synthetic_marionette()
	var dock := MarionetteMuscleTestDock.new()
	# Add to a transient parent so the dock's tree machinery is happy.
	# Skip _enter_tree's EditorInterface path by leaving the dock outside
	# `Engine.is_editor_hint() == true` (headless), which it already is.
	root.add_child(dock)
	dock._set_active_marionette(m)

	# Pre-condition: gravity_scale at 1.0.
	if absf(m.get_gravity_scale() - 1.0) > 1.0e-6:
		dock.queue_free(); m.free()
		return _fail("dock_enter_ragdoll_zeros_gravity",
				"pre-entry gravity_scale=%f, expected 1.0" % m.get_gravity_scale())

	# Drive a mode change: simulate user picking item index 1 (Ragdoll Test).
	dock._on_mode_changed(1)

	var ok_g := absf(m.get_gravity_scale()) < 1.0e-6
	var ok_mode := dock.get_mode() == MarionetteMuscleTestDock.Mode.RAGDOLL_TEST
	# The previously-built ragdoll persists; dock does not rebuild.
	var sim := _find_simulator(m)
	var ok_sim := sim != null

	dock._on_mode_changed(0)  # exit cleanly before tearing down
	dock.queue_free()
	m.free()
	if not ok_g:
		return _fail("dock_enter_ragdoll_zeros_gravity",
				"gravity not zeroed: %f" % m.get_gravity_scale() if is_instance_valid(m) else "m freed")
	if not ok_mode:
		return _fail("dock_enter_ragdoll_zeros_gravity", "mode not RAGDOLL_TEST")
	if not ok_sim:
		return _fail("dock_enter_ragdoll_zeros_gravity", "simulator missing under skeleton")
	return _ok("muscle_test_dock_enter_ragdoll_test_zeros_gravity")


# Exit from Ragdoll Test must restore the saved gravity_scale and leave
# the skeleton at rest. We verify (a) gravity round-trip + (b) the dock's
# mode bit flips back to Preview.
func _test_muscle_test_dock_exit_restores_gravity_and_rest() -> bool:
	var m := _build_synthetic_marionette()
	# Set a non-default pre-entry gravity so we can detect proper restore.
	m.set_gravity_scale(0.7)
	var dock := MarionetteMuscleTestDock.new()
	root.add_child(dock)
	dock._set_active_marionette(m)

	dock._on_mode_changed(1)  # enter Ragdoll Test
	if absf(m.get_gravity_scale()) > 1.0e-6:
		dock.queue_free(); m.free()
		return _fail("dock_exit_restores", "entry didn't zero gravity")

	dock._on_mode_changed(0)  # exit back to Preview

	var ok_g := absf(m.get_gravity_scale() - 0.7) < 1.0e-6
	var ok_mode := dock.get_mode() == MarionetteMuscleTestDock.Mode.SKELETON3D_PREVIEW

	var gravity_after := m.get_gravity_scale()
	dock.queue_free()
	m.free()
	if not ok_g:
		return _fail("dock_exit_restores",
				"gravity not restored: got %f, expected 0.7" % gravity_after)
	if not ok_mode:
		return _fail("dock_exit_restores", "mode did not flip back to Preview")
	return _ok("muscle_test_dock_exit_restores_gravity_and_rest")


# ---------- MarionetteBoneRegion (P4.3 dock grouping) ----------

func _test_bone_region_humanoid_total_84() -> bool:
	# Every name in the archetype default map must classify into a real
	# region — proves the dock won't lose bones to OTHER for a humanoid rig.
	var unmapped: Array[StringName] = []
	for bone_name: StringName in MarionetteArchetypeDefaults.HUMANOID_BY_BONE.keys():
		if not MarionetteBoneRegion.has_mapping_for(bone_name):
			unmapped.append(bone_name)
	if unmapped.size() > 0:
		return _fail("bone_region_humanoid_total",
				"%d bones unmapped: %s" % [unmapped.size(), unmapped])
	# And: total mapped count = 84 (cross-check with the archetype map).
	var humanoid_count := MarionetteArchetypeDefaults.HUMANOID_BY_BONE.size()
	if humanoid_count != 84:
		return _fail("bone_region_humanoid_total",
				"archetype map has %d bones, expected 84" % humanoid_count)
	return _ok("bone_region_humanoid_total_84")


func _test_bone_region_left_right_balance() -> bool:
	# Left/right paired regions must have identical bone counts. Catches
	# typos like a missing RightThumbDistal or asymmetric finger naming.
	var counts := _count_humanoid_per_region()
	var pairs: Array = [
		[MarionetteBoneRegion.Region.LEFT_ARM, MarionetteBoneRegion.Region.RIGHT_ARM, "Arm"],
		[MarionetteBoneRegion.Region.LEFT_HAND, MarionetteBoneRegion.Region.RIGHT_HAND, "Hand"],
		[MarionetteBoneRegion.Region.LEFT_LEG, MarionetteBoneRegion.Region.RIGHT_LEG, "Leg"],
		[MarionetteBoneRegion.Region.LEFT_FOOT, MarionetteBoneRegion.Region.RIGHT_FOOT, "Foot"],
	]
	for pair: Array in pairs:
		var l: int = counts.get(pair[0], 0)
		var r: int = counts.get(pair[1], 0)
		if l != r:
			return _fail("bone_region_lr_balance",
					"%s asymmetric: left=%d right=%d" % [pair[2], l, r])
	return _ok("bone_region_left_right_balance")


func _test_bone_region_per_region_counts() -> bool:
	# Spot-check exact per-region counts so a stray reclassification
	# (moving Hips out of Spine, dropping Jaw, etc.) trips the test.
	var counts := _count_humanoid_per_region()
	var expectations: Array = [
		[MarionetteBoneRegion.Region.SPINE, 5, "Spine: Root+Hips+Spine+Chest+UpperChest"],
		[MarionetteBoneRegion.Region.HEAD_NECK, 5, "Head/Neck: Neck+Head+Jaw+LeftEye+RightEye"],
		[MarionetteBoneRegion.Region.LEFT_ARM, 3, "Left arm: Shoulder+UpperArm+LowerArm"],
		[MarionetteBoneRegion.Region.LEFT_HAND, 16, "Left hand: Hand + 15 finger bones"],
		[MarionetteBoneRegion.Region.LEFT_LEG, 2, "Left leg: UpperLeg+LowerLeg"],
		[MarionetteBoneRegion.Region.LEFT_FOOT, 16, "Left foot: Foot+Toes + 14 toe bones"],
	]
	for ex: Array in expectations:
		var actual: int = counts.get(ex[0], 0)
		if actual != ex[1]:
			return _fail("bone_region_per_count",
					"%s expected %d got %d" % [ex[2], ex[1], actual])
	return _ok("bone_region_per_region_counts")


func _test_bone_region_unknown_falls_back_to_other() -> bool:
	var r := MarionetteBoneRegion.region_for(&"CosmeticTail")
	if r != MarionetteBoneRegion.Region.OTHER:
		return _fail("bone_region_other", "unknown bone got region %d, expected OTHER" % r)
	if MarionetteBoneRegion.has_mapping_for(&"CosmeticTail"):
		return _fail("bone_region_other", "has_mapping_for should be false for unknown")
	return _ok("bone_region_unknown_falls_back_to_other")


func _test_bone_region_label_for_each() -> bool:
	# Every region in ORDER must have a non-empty label — guards against
	# adding a Region enum value but forgetting the LABELS entry.
	for region: int in MarionetteBoneRegion.ORDER:
		var label := MarionetteBoneRegion.label_for(region)
		if label == "" or label == "Region":
			return _fail("bone_region_label", "region %d missing label" % region)
	return _ok("bone_region_label_for_each")


func _count_humanoid_per_region() -> Dictionary[int, int]:
	var counts: Dictionary[int, int] = {}
	for bone_name: StringName in MarionetteArchetypeDefaults.HUMANOID_BY_BONE.keys():
		var region := MarionetteBoneRegion.region_for(bone_name)
		counts[region] = counts.get(region, 0) + 1
	return counts


# ---------- MarionetteMacroPresets — anatomical-axis macros (per-region groups) ----------

func _test_macro_arms_flex_ext_covers_arm_bones() -> bool:
	# Arms group should target every LEFT_ARM + RIGHT_ARM bone with the flex
	# axis (1, 0, 0) and nothing else.
	var inf: Dictionary = MarionetteMacroPresets.influences_for(MarionetteMacroPresets.KEY_ARMS_FLEX_EXT)
	var must_have: Array[StringName] = [
		&"LeftShoulder", &"LeftUpperArm", &"LeftLowerArm",
		&"RightShoulder", &"RightUpperArm", &"RightLowerArm",
	]
	for bn: StringName in must_have:
		if not inf.has(bn):
			return _fail("macro_arms_flex", "missing %s" % bn)
		if not (inf[bn] as Vector3).is_equal_approx(Vector3(1, 0, 0)):
			return _fail("macro_arms_flex", "%s coeff=%s expected (1,0,0)" % [bn, inf[bn]])
	# Reject leg / hand / spine bones — outside arm scope.
	for outsider: StringName in [&"LeftHand", &"RightUpperLeg", &"Spine", &"LeftIndexProximal"]:
		if inf.has(outsider):
			return _fail("macro_arms_flex", "unexpected bone %s in arms scope" % outsider)
	return _ok("macro_arms_flex_ext_covers_arm_bones")


func _test_macro_legs_med_lat_axis_only() -> bool:
	# Leg medial/lateral macro should set anatomical Y on every leg bone.
	var inf: Dictionary = MarionetteMacroPresets.influences_for(MarionetteMacroPresets.KEY_LEGS_MED_LAT)
	if not inf.has(&"LeftUpperLeg"):
		return _fail("macro_legs_medlat", "missing LeftUpperLeg")
	var v: Vector3 = inf[&"LeftUpperLeg"] as Vector3
	if not v.is_equal_approx(Vector3(0, 1, 0)):
		return _fail("macro_legs_medlat", "LeftUpperLeg coeff=%s expected (0,1,0)" % v)
	if inf.has(&"LeftFoot"):
		return _fail("macro_legs_medlat", "feet should not appear in legs scope")
	return _ok("macro_legs_med_lat_axis_only")


func _test_macro_all_covers_every_mapped_bone() -> bool:
	# all_flex_ext is the unfiltered axis macro — should cover EVERY region-
	# mapped bone (we use FLEX rather than ABD_ADD because ABD_ADD now
	# excludes the SPINE region; spine bones don't have clinical
	# medial/lateral or abduction/adduction in the limb sense).
	var inf: Dictionary = MarionetteMacroPresets.influences_for(MarionetteMacroPresets.KEY_ALL_FLEX_EXT)
	var mapped: Array[StringName] = MarionetteBoneRegion.all_mapped_bones()
	if inf.size() != mapped.size():
		return _fail("macro_all", "inf size %d, mapped %d" % [inf.size(), mapped.size()])
	for bn: StringName in mapped:
		if not inf.has(bn):
			return _fail("macro_all", "missing %s" % bn)
		if not (inf[bn] as Vector3).is_equal_approx(Vector3(1, 0, 0)):
			return _fail("macro_all", "%s coeff=%s expected (1,0,0)" % [bn, inf[bn]])
	# Counterpart: ABD_ADD should match every mapped bone EXCEPT the SPINE +
	# HEAD_NECK chain (Spine, Chest, UpperChest, Neck, Head). Catches
	# regression if either exclusion is silently dropped. Middle finger /
	# middle toe stay in the dict (they're region-mapped) but with Z=0 from
	# `_apply_finger_toe_abd_overrides` — that's checked separately in
	# `_test_macro_finger_toe_abd_excludes_middle`.
	var inf_abd: Dictionary = MarionetteMacroPresets.influences_for(MarionetteMacroPresets.KEY_ALL_ABD_ADD)
	for bn: StringName in mapped:
		var region: int = MarionetteBoneRegion.region_for(bn)
		var should_be_present: bool = (
				region != MarionetteBoneRegion.Region.SPINE
				and region != MarionetteBoneRegion.Region.HEAD_NECK)
		if inf_abd.has(bn) != should_be_present:
			return _fail("macro_all",
					"%s in ABD_ADD: got %s, expected %s (region %d)" %
					[bn, inf_abd.has(bn), should_be_present, region])
	return _ok("macro_all_covers_every_mapped_bone")


func _test_macro_hands_excludes_arms() -> bool:
	# Hand macros should drive finger bones and the wrist (LEFT_HAND /
	# RIGHT_HAND regions) but not Shoulder / UpperArm / LowerArm.
	var inf: Dictionary = MarionetteMacroPresets.influences_for(MarionetteMacroPresets.KEY_HANDS_FLEX_EXT)
	if not inf.has(&"LeftHand"):
		return _fail("macro_hands", "LeftHand missing")
	if not inf.has(&"LeftIndexProximal"):
		return _fail("macro_hands", "LeftIndexProximal missing")
	for outsider: StringName in [&"LeftShoulder", &"LeftUpperArm", &"LeftLowerArm"]:
		if inf.has(outsider):
			return _fail("macro_hands", "arm bone %s leaked into hands scope" % outsider)
	return _ok("macro_hands_excludes_arms")


func _test_macro_body_covers_spine_and_head_neck() -> bool:
	var inf: Dictionary = MarionetteMacroPresets.influences_for(MarionetteMacroPresets.KEY_BODY_FLEX_EXT)
	for bn: StringName in [&"Spine", &"Chest", &"UpperChest", &"Neck", &"Head", &"Hips"]:
		if not inf.has(bn):
			return _fail("macro_body", "missing %s" % bn)
	for outsider: StringName in [&"LeftUpperArm", &"RightUpperLeg", &"LeftHand", &"LeftFoot"]:
		if inf.has(outsider):
			return _fail("macro_body", "%s leaked into body scope" % outsider)
	return _ok("macro_body_covers_spine_and_head_neck")


func _test_macro_group_keys_partition_anatomical_set() -> bool:
	# Every key referenced by GROUP_KEYS must exist in ORDER and have a label.
	# Catches typos in either table.
	var seen: Dictionary[StringName, bool] = {}
	for group: StringName in MarionetteMacroPresets.GROUP_ORDER:
		var keys: Array = MarionetteMacroPresets.keys_for_group(group)
		if keys.is_empty():
			return _fail("macro_group_keys", "group %s has no keys" % group)
		for key in keys:
			var sn: StringName = key
			if seen.has(sn):
				return _fail("macro_group_keys", "key %s appears in multiple groups" % sn)
			seen[sn] = true
			if not MarionetteMacroPresets.ORDER.has(sn):
				return _fail("macro_group_keys", "%s missing from ORDER" % sn)
			if MarionetteMacroPresets.label_for(sn) == String(sn):
				return _fail("macro_group_keys", "%s missing from LABELS" % sn)
	# All ORDER entries should be reached via groups.
	for key: StringName in MarionetteMacroPresets.ORDER:
		if not seen.has(key):
			return _fail("macro_group_keys", "%s in ORDER but no group references it" % key)
	return _ok("macro_group_keys_partition_anatomical_set")


func _test_motion_validator_template_profile_no_wrongs() -> bool:
	# Generate the template profile, run the dynamic motion test, expect zero
	# WRONG outcomes. Every bone's anatomical flex axis should produce motion
	# in the archetype-expected direction (forward for limb/spine, up for
	# clavicle). If a future solver change breaks this — say swapping a sign
	# or picking the wrong cross-product orientation — the motion test catches
	# it where the static validator can't.
	var bp := _make_humanoid_bone_profile()
	BoneProfileGenerator.generate(bp)
	var report := MarionetteFrameValidator.validate_motion(bp)
	if report.error != "":
		return _fail("motion_template", "error: %s" % report.error)
	if report.wrong_count != 0:
		# Build a list of offenders for the failure message — the dynamic
		# test exists precisely to surface these so debugging is easy.
		var wrongs: Array[StringName] = report.by_status("WRONG")
		return _fail("motion_template", "%d bones moved the wrong direction on +flex: %s" %
				[report.wrong_count, wrongs])
	# Some bones can legitimately come out as WEAK (e.g., clavicles with
	# along-axis nearly parallel to up; spine segments where forward dot is
	# noisy due to muscle-frame rounding). Don't fail on those.
	if report.diagnoses.is_empty():
		return _fail("motion_template", "no diagnoses produced — empty profile?")
	return _ok("motion_validator_template_profile_no_wrongs")


# ---------- MarionetteFrameValidator ----------

func _test_validator_template_profile_all_ok() -> bool:
	# A freshly-generated template profile is consistent with the solver by
	# construction (the matcher just picked among candidates of the same
	# input). Every SPD bone should validate as OK.
	var bp := _make_humanoid_bone_profile()
	BoneProfileGenerator.generate(bp)
	var report := MarionetteFrameValidator.validate(bp)
	if report.error != "":
		return _fail("validator_template", "error: %s" % report.error)
	if report.flipped_count != 0:
		return _fail("validator_template",
			"%d FLIPPED on a fresh template — solver/matcher disagreement" % report.flipped_count)
	if report.swapped_count != 0:
		return _fail("validator_template",
			"%d SWAPPED on a fresh template" % report.swapped_count)
	if report.bad_count != 0:
		return _fail("validator_template", "%d BAD on a fresh template" % report.bad_count)
	# OK + WEAK is acceptable on the template (some bones legitimately have
	# rest bases that score in the WEAK band, e.g. clavicle with along-axis
	# nearly parallel to lateral).
	if report.ok_count + report.weak_count == 0:
		return _fail("validator_template", "no bones validated — empty diagnoses?")
	return _ok("validator_template_profile_all_ok")


func _test_validator_flips_sign_error() -> bool:
	# Manually invert the flex axis on one entry — validator should classify
	# that bone as FLIPPED, leave the rest at their previous status.
	var bp := _make_humanoid_bone_profile()
	BoneProfileGenerator.generate(bp)
	var entry: BoneEntry = bp.bones[&"LeftLowerArm"]
	# Replace flex_axis with its inverse (PLUS_X → MINUS_X, etc.).
	entry.flex_axis = SignedAxis.inverse(entry.flex_axis)
	# Make sure the calculated-frame fallback isn't shadowing the change.
	entry.use_calculated_frame = false
	var report := MarionetteFrameValidator.validate(bp)
	var found_flipped: bool = false
	for d: MarionetteFrameValidator.BoneDiagnosis in report.diagnoses:
		if d.bone_name == &"LeftLowerArm":
			if d.status != "FLIPPED":
				return _fail("validator_flip",
					"LeftLowerArm status=%s, expected FLIPPED (flex_dot=%f)" %
					[d.status, d.flex_dot])
			found_flipped = true
	if not found_flipped:
		return _fail("validator_flip", "LeftLowerArm missing from diagnoses")
	return _ok("validator_flips_sign_error")


func _test_validator_swaps_axis_misassignment() -> bool:
	# Swap the flex and abd axes on an entry — both end up high-correlation
	# with the *wrong* target column. Validator should catch this as SWAPPED
	# (or at worst FLIPPED — both signal the entry is broken; SWAPPED is the
	# more specific classification).
	var bp := _make_humanoid_bone_profile()
	BoneProfileGenerator.generate(bp)
	var entry: BoneEntry = bp.bones[&"LeftUpperArm"]
	var saved_flex: SignedAxis.Axis = entry.flex_axis
	entry.flex_axis = entry.abduction_axis
	entry.abduction_axis = saved_flex
	entry.use_calculated_frame = false
	var report := MarionetteFrameValidator.validate(bp)
	var found_misclass: bool = false
	for d: MarionetteFrameValidator.BoneDiagnosis in report.diagnoses:
		if d.bone_name == &"LeftUpperArm":
			# Must not pass as OK after a hand-broken swap.
			if d.status == "OK":
				return _fail("validator_swap",
					"LeftUpperArm passed as OK despite axis swap (flex_dot=%f abd_dot=%f)" %
					[d.flex_dot, d.abd_dot])
			found_misclass = true
	if not found_misclass:
		return _fail("validator_swap", "LeftUpperArm missing from diagnoses")
	return _ok("validator_swaps_axis_misassignment")


# ---------- T-pose calibration path (Marionette_Update_TPose_Calibration.md) ----------

func _test_canonical_directions_humanoid_coverage() -> bool:
	# Every bone in MarionetteHumanoidProfile that is not ROOT/FIXED must
	# return a non-zero canonical along-direction. ROOT/FIXED bones never
	# run the T-pose solver (the generator short-circuits them), so we only
	# assert coverage on the bones that actually consume the table.
	var profile := load(HUMANOID_PROFILE_PATH) as SkeletonProfile
	if profile == null:
		return _fail("canonical_directions_coverage", "could not load profile")
	var frame := MuscleFrameBuilder.build(profile)
	var missing: Array[StringName] = []
	for i in range(profile.bone_size):
		var bone_name := profile.get_bone_name(i)
		var archetype: int = MarionetteArchetypeDefaults.archetype_for_bone(bone_name)
		if archetype == BoneArchetype.Type.ROOT or archetype == BoneArchetype.Type.FIXED:
			continue
		var is_left_side: bool = String(bone_name).begins_with("Left")
		var along: Vector3 = MarionetteCanonicalDirections.along_for(bone_name, frame, is_left_side)
		if along == Vector3.ZERO:
			missing.append(bone_name)
	if not missing.is_empty():
		return _fail("canonical_directions_coverage",
				"%d non-ROOT/FIXED bones returned ZERO: %s" % [missing.size(), missing])
	return _ok("canonical_directions_humanoid_coverage")


func _test_canonical_directions_handedness() -> bool:
	# Limb chain bones must mirror by side: left -> -mf.right, right -> +mf.right.
	# Spine chain (Hips/Spine/Chest/UpperChest/Neck/Head) returns +mf.up.
	# Leg chain returns -mf.up; Foot returns +mf.forward; Toes return +mf.forward.
	var frame := MuscleFrame.new()
	frame.right = Vector3(1, 0, 0)
	frame.up = Vector3(0, 1, 0)
	frame.forward = Vector3(0, 0, 1)
	var checks: Array = [
		[&"LeftUpperArm", true, Vector3(-1, 0, 0)],
		[&"RightUpperArm", false, Vector3(1, 0, 0)],
		[&"LeftHand", true, Vector3(-1, 0, 0)],
		[&"RightHand", false, Vector3(1, 0, 0)],
		[&"LeftIndexProximal", true, Vector3(-1, 0, 0)],
		[&"RightLittleDistal", false, Vector3(1, 0, 0)],
		[&"Spine", false, Vector3(0, 1, 0)],
		[&"Chest", false, Vector3(0, 1, 0)],
		[&"UpperChest", false, Vector3(0, 1, 0)],
		[&"Neck", false, Vector3(0, 1, 0)],
		[&"Head", false, Vector3(0, 1, 0)],
		[&"LeftUpperLeg", true, Vector3(0, -1, 0)],
		[&"RightLowerLeg", false, Vector3(0, -1, 0)],
		[&"LeftFoot", true, Vector3(0, 0, 1)],
		[&"LeftToes", true, Vector3(0, 0, 1)],
		[&"RightBigToeProximal", false, Vector3(0, 0, 1)],
	]
	for c: Array in checks:
		var bone_name: StringName = c[0]
		var is_left: bool = c[1]
		var want: Vector3 = c[2]
		var got: Vector3 = MarionetteCanonicalDirections.along_for(bone_name, frame, is_left)
		if not got.is_equal_approx(want):
			return _fail("canonical_directions_handedness",
					"%s (left=%s): got %s, expected %s" % [bone_name, is_left, got, want])
	return _ok("canonical_directions_handedness")


func _test_t_pose_basis_solver_orthonormal_humanoid() -> bool:
	# For every non-ROOT/FIXED humanoid bone, the T-pose solver must produce
	# an orthonormal basis with determinant ±1.
	var profile := load(HUMANOID_PROFILE_PATH) as SkeletonProfile
	if profile == null:
		return _fail("t_pose_solver_orthonormal", "could not load profile")
	var frame := MuscleFrameBuilder.build(profile)
	for i in range(profile.bone_size):
		var bone_name := profile.get_bone_name(i)
		var archetype: int = MarionetteArchetypeDefaults.archetype_for_bone(bone_name)
		if archetype == BoneArchetype.Type.ROOT or archetype == BoneArchetype.Type.FIXED:
			continue
		var is_left_side: bool = String(bone_name).begins_with("Left")
		var basis: Basis = MarionetteTPoseBasisSolver.solve(bone_name, archetype, frame, is_left_side)
		# Pivot has motion_target == ZERO in anatomical_motion_target, so the
		# solver returns IDENTITY for it. IDENTITY is orthonormal too — the
		# loop below still validates it without special-casing.
		for label_value: Array in [["x", basis.x], ["y", basis.y], ["z", basis.z]]:
			var v: Vector3 = label_value[1]
			if not is_equal_approx(v.length(), 1.0):
				return _fail("t_pose_solver_orthonormal",
						"%s col-%s len=%f" % [bone_name, label_value[0], v.length()])
		var dots: Array[float] = [
			basis.x.dot(basis.y),
			basis.x.dot(basis.z),
			basis.y.dot(basis.z),
		]
		for d: float in dots:
			if absf(d) > 1.0e-5:
				return _fail("t_pose_solver_orthonormal",
						"%s columns not orthogonal (dot=%f)" % [bone_name, d])
		var det: float = basis.determinant()
		if absf(absf(det) - 1.0) > 1.0e-4:
			return _fail("t_pose_solver_orthonormal",
					"%s det=%f, expected ±1" % [bone_name, det])
	return _ok("t_pose_basis_solver_orthonormal_humanoid")


func _test_t_pose_basis_solver_along_matches_table() -> bool:
	# Solver's along (basis.y) must equal the canonical-table direction for
	# every non-ROOT/FIXED bone — that's the whole contract of the T-pose
	# method. Catches regressions if make_anatomical_basis ever rotates the
	# along axis away from the table value.
	var profile := load(HUMANOID_PROFILE_PATH) as SkeletonProfile
	if profile == null:
		return _fail("t_pose_solver_along", "could not load profile")
	var frame := MuscleFrameBuilder.build(profile)
	for i in range(profile.bone_size):
		var bone_name := profile.get_bone_name(i)
		var archetype: int = MarionetteArchetypeDefaults.archetype_for_bone(bone_name)
		if archetype == BoneArchetype.Type.ROOT or archetype == BoneArchetype.Type.FIXED:
			continue
		var is_left_side: bool = String(bone_name).begins_with("Left")
		var expected_along: Vector3 = MarionetteCanonicalDirections.along_for(
				bone_name, frame, is_left_side)
		if expected_along == Vector3.ZERO:
			continue
		var basis: Basis = MarionetteTPoseBasisSolver.solve(bone_name, archetype, frame, is_left_side)
		if basis.is_equal_approx(Basis.IDENTITY):
			# motion_target was ZERO (Pivot/Root/Fixed branches) — solver
			# returns IDENTITY, don't assert against the table.
			continue
		var got_along: Vector3 = basis.y.normalized()
		if not got_along.is_equal_approx(expected_along.normalized()):
			return _fail("t_pose_solver_along",
					"%s along=%s, expected %s" % [bone_name, got_along, expected_along])
	return _ok("t_pose_basis_solver_along_matches_table")


func _test_t_pose_basis_solver_motion_alignment() -> bool:
	# +flex on the resulting basis must produce motion in the
	# anatomical_motion_target direction. Construction:
	#   motion = flex × along; flex = along × motion_target
	# So flex × along should land along motion_target up to sign. We assert
	# alignment > 0.5 to catch sign errors and gross misalignments.
	var profile := load(HUMANOID_PROFILE_PATH) as SkeletonProfile
	if profile == null:
		return _fail("t_pose_solver_motion", "could not load profile")
	var frame := MuscleFrameBuilder.build(profile)
	for i in range(profile.bone_size):
		var bone_name := profile.get_bone_name(i)
		var archetype: int = MarionetteArchetypeDefaults.archetype_for_bone(bone_name)
		if archetype == BoneArchetype.Type.ROOT or archetype == BoneArchetype.Type.FIXED:
			continue
		var is_left_side: bool = String(bone_name).begins_with("Left")
		var motion_target: Vector3 = MarionetteSolverUtils.anatomical_motion_target(
				bone_name, archetype, frame)
		if motion_target == Vector3.ZERO:
			continue
		var basis: Basis = MarionetteTPoseBasisSolver.solve(bone_name, archetype, frame, is_left_side)
		var motion: Vector3 = basis.x.cross(basis.y)
		if motion.length_squared() < 1.0e-6:
			return _fail("t_pose_solver_motion",
					"%s flex × along is degenerate" % bone_name)
		var alignment: float = motion.normalized().dot(motion_target.normalized())
		if alignment < 0.5:
			return _fail("t_pose_solver_motion",
					"%s flex×along·motion=%f (motion=%s, target=%s)" %
					[bone_name, alignment, motion.normalized(), motion_target])
	return _ok("t_pose_basis_solver_motion_alignment")


func _test_bone_profile_generator_method_parity_template() -> bool:
	# Run the generator twice on the same template profile, once per method,
	# and compare per-bone agreement angles between the two baked anatomical
	# bases. Major SPD joints should agree within a tight threshold; spine
	# segments and clavicles can diverge more because the archetype solvers
	# do non-trivial geometry there.
	var bp_arch := _make_humanoid_bone_profile()
	BoneProfileGenerator.generate_with_method(bp_arch, BoneProfileGenerator.Method.ARCHETYPE)
	var bp_tpose := _make_humanoid_bone_profile()
	BoneProfileGenerator.generate_with_method(bp_tpose, BoneProfileGenerator.Method.TPOSE)

	if bp_arch.bones.size() != bp_tpose.bones.size():
		return _fail("method_parity",
				"size mismatch: archetype=%d tpose=%d" %
				[bp_arch.bones.size(), bp_tpose.bones.size()])

	# Tight parity expected at major SPD joints.
	var tight: Array[StringName] = [
		&"LeftUpperArm", &"RightUpperArm",
		&"LeftLowerArm", &"RightLowerArm",
		&"LeftUpperLeg", &"RightUpperLeg",
		&"LeftLowerLeg", &"RightLowerLeg",
		&"LeftHand", &"RightHand",
		&"LeftFoot", &"RightFoot",
	]
	var tight_threshold_deg: float = 5.0
	# Loose ceiling on every other bone: just guard against pathological flips.
	var loose_threshold_deg: float = 90.0
	var summary: PackedStringArray = PackedStringArray()
	for bone_name: StringName in bp_arch.bones.keys():
		var arch_entry: BoneEntry = bp_arch.bones[bone_name]
		var tpose_entry: BoneEntry = bp_tpose.bones[bone_name]
		if arch_entry == null or tpose_entry == null:
			continue
		if not arch_entry.use_calculated_frame or not tpose_entry.use_calculated_frame:
			continue
		var qa := Quaternion(arch_entry.calculated_anatomical_basis.orthonormalized())
		var qt := Quaternion(tpose_entry.calculated_anatomical_basis.orthonormalized())
		var angle_deg: float = rad_to_deg(qa.angle_to(qt))
		summary.append("  %-28s arch_vs_tpose=%6.2f deg" % [bone_name, angle_deg])
		var threshold: float = tight_threshold_deg if tight.has(bone_name) else loose_threshold_deg
		if angle_deg > threshold:
			print("[method_parity] per-bone agreement (deg):")
			for line: String in summary:
				print(line)
			return _fail("method_parity",
					"%s diverges by %.2f deg (threshold %.2f deg)" %
					[bone_name, angle_deg, threshold])
	return _ok("bone_profile_generator_method_parity_template")


# ---------- BoneEntry.rest_anatomical_offset (canonical-anatomy ROM) ----------

# Helper: build a synthetic HINGE entry with a calculated_anatomical_basis whose
# +X column points along `flex_axis_world` once composed with `bone_world.basis`.
# Used by the rest-offset tests below — they hand-pick parent/bone/child world
# transforms and then set up an entry whose joint flex axis matches the
# limb-plane normal, so _compute_rest_offset's sign extraction is deterministic.
func _make_hinge_entry_with_world_flex(
		bone_world: Transform3D,
		flex_axis_world: Vector3) -> BoneEntry:
	var entry := BoneEntry.new()
	entry.archetype = BoneArchetype.Type.HINGE
	# entry.calculated_anatomical_basis is in bone-local space; transform the
	# requested world flex axis into bone-local. Bone rest basis is identity in
	# our test fixtures, so this is the identity case but stays correct if a
	# future fixture rolls the bone basis.
	var local_x: Vector3 = bone_world.basis.inverse() * flex_axis_world
	# Build a basis whose +X is local_x; +Y and +Z are arbitrary perpendiculars.
	var ortho_y: Vector3 = MarionetteSolverUtils.perpendicular_to_axis_near(
			local_x.normalized(), Vector3.UP)
	var ortho_z: Vector3 = local_x.normalized().cross(ortho_y).normalized()
	entry.calculated_anatomical_basis = Basis(local_x.normalized(), ortho_y, ortho_z)
	entry.use_calculated_frame = true
	return entry


func _test_rest_offset_hinge_collinear_is_zero() -> bool:
	# Parent at +Y, bone at origin, child along -Y. parent_along ≡ child_along
	# (both point -Y from the bone). Bend axis is the zero vector → offset = 0.
	var parent := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0))
	var bone := Transform3D(Basis.IDENTITY, Vector3.ZERO)
	var child := Transform3D(Basis.IDENTITY, Vector3(0.0, -1.0, 0.0))
	var entry := _make_hinge_entry_with_world_flex(bone, Vector3.RIGHT)
	var offset: Vector3 = BoneProfileGenerator._compute_rest_offset(
			BoneArchetype.Type.HINGE, bone, child, parent,
			MuscleFrame.new(), entry, &"LeftLowerArm")
	if not offset.is_equal_approx(Vector3.ZERO):
		return _fail("rest_offset_hinge_collinear",
				"collinear limb should yield zero offset, got %s" % offset)
	return _ok("rest_offset_hinge_collinear_is_zero")


func _test_rest_offset_hinge_a_pose_elbow_bend() -> bool:
	# A-pose-style left elbow in the XY plane. parent_along (shoulder→elbow) =
	# (1, -1, 0)/√2; child_along (elbow→wrist) = (1, -1.5, 0).normalized() —
	# the forearm is folded ~14° anteriorly (toward muscle-frame +Z is N/A here
	# since fixture is in XY only; the bend is purely in the limb plane). The
	# joint flex axis we hand the entry is +Z (out of the plane), so a positive
	# flex rotation moves the bone tip in the +X direction. The bend axis here
	# (parent_along × child_along) lands along ±Z and we sign rest_offset.x
	# accordingly. Magnitude must match the analytic angle within FP noise.
	var shoulder := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.5, 0.0))
	var elbow := Transform3D(Basis.IDENTITY, Vector3(0.5, 1.0, 0.0))
	var wrist := Transform3D(Basis.IDENTITY, Vector3(0.9, 0.4, 0.0))
	var parent_along: Vector3 = (elbow.origin - shoulder.origin).normalized()
	var child_along: Vector3 = (wrist.origin - elbow.origin).normalized()
	var expected_mag: float = acos(clampf(parent_along.dot(child_along), -1.0, 1.0))

	var entry := _make_hinge_entry_with_world_flex(elbow, Vector3.BACK)
	var offset: Vector3 = BoneProfileGenerator._compute_rest_offset(
			BoneArchetype.Type.HINGE, elbow, wrist, shoulder,
			MuscleFrame.new(), entry, &"LeftLowerArm")
	if absf(absf(offset.x) - expected_mag) > 1e-4:
		return _fail("rest_offset_a_pose_elbow",
				"|offset.x|=%f, expected %f" % [absf(offset.x), expected_mag])
	if not is_equal_approx(offset.y, 0.0) or not is_equal_approx(offset.z, 0.0):
		return _fail("rest_offset_a_pose_elbow",
				"non-flex components should be zero, got (%f, %f)" %
				[offset.y, offset.z])
	return _ok("rest_offset_hinge_a_pose_elbow_bend")


func _test_rest_offset_root_fixed_pivot_returns_zero() -> bool:
	# DOF-less archetypes always return zero — there's no joint to offset.
	var parent := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0))
	var bone := Transform3D(Basis.IDENTITY, Vector3(0.5, 0.5, 0.0))
	var child := Transform3D(Basis.IDENTITY, Vector3(1.0, 0.0, 0.0))
	var entry := _make_hinge_entry_with_world_flex(bone, Vector3.BACK)
	for arch: int in [BoneArchetype.Type.PIVOT, BoneArchetype.Type.ROOT, BoneArchetype.Type.FIXED]:
		var offset: Vector3 = BoneProfileGenerator._compute_rest_offset(
				arch, bone, child, parent, MuscleFrame.new(), entry, &"Hips")
		if not offset.is_equal_approx(Vector3.ZERO):
			return _fail("rest_offset_root_fixed_pivot",
					"archetype %s should return zero, got %s" %
					[BoneArchetype.to_name(arch), offset])
	return _ok("rest_offset_root_fixed_pivot_returns_zero")


func _test_rest_offset_ball_shoulder_t_pose_abd_offset() -> bool:
	# Right shoulder in T-pose: bone at +X (laterally extended), child further
	# along +X. canonical_along = -muscle_frame.up = (0,-1,0); rest_along =
	# (1,0,0). Rotation from canonical to rest is +90° around +Z (world).
	# Joint frame for right shoulder T-pose: flex=+up, along=+right, abd=-Z;
	# axis-in-joint-coords lands on -Z component → -π/2. mirror_abd flips it
	# back to +π/2 in canonical-positive convention.
	var hips_mid := Transform3D(Basis.IDENTITY, Vector3.ZERO)
	var shoulder := Transform3D(Basis.IDENTITY, Vector3(1.0, 0.0, 0.0))  # bone origin
	var elbow := Transform3D(Basis.IDENTITY, Vector3(2.0, 0.0, 0.0))     # child origin
	# Build a real BoneEntry the same way the generator would: run the BALL
	# solver and detect mirror_abd at canonical pose, then call _compute_rest_offset.
	var mf := MuscleFrame.new()
	var motion_target: Vector3 = MarionetteSolverUtils.anatomical_motion_target(
			&"RightUpperArm", BoneArchetype.Type.BALL, mf)
	var target_basis: Basis = MarionetteBallSolver.solve(
			shoulder, elbow, mf, false, hips_mid, motion_target)
	var entry := BoneEntry.new()
	entry.archetype = BoneArchetype.Type.BALL
	entry.is_left_side = false
	entry.calculated_anatomical_basis = shoulder.basis.inverse() * target_basis
	entry.use_calculated_frame = true
	# Mirror_abd at canonical: rotate the rest-pose abd motion by Q(rest→canonical).
	var rest_along := (elbow.origin - shoulder.origin).normalized()
	var natural_abd_at_rest: Vector3 = target_basis.z.cross(rest_along)
	var canonical_along := -mf.up
	var q := Quaternion(rest_along, canonical_along)
	var natural_abd_at_canonical: Vector3 = q * natural_abd_at_rest
	var expected_abd: Vector3 = MarionetteSolverUtils.expected_abd_motion_direction(
			BoneArchetype.Type.BALL, false, mf)
	entry.mirror_abd = natural_abd_at_canonical.normalized().dot(expected_abd) < 0.0
	if not entry.mirror_abd:
		return _fail("rest_offset_ball_shoulder",
				"right shoulder T-pose should set mirror_abd=true (canonical-pose check)")

	var offset: Vector3 = BoneProfileGenerator._compute_rest_offset(
			BoneArchetype.Type.BALL, shoulder, elbow, hips_mid,
			mf, entry, &"RightUpperArm")
	# Expect ~+90° on Z, ~0 on X and Y.
	if absf(offset.z - PI / 2.0) > 1e-4:
		return _fail("rest_offset_ball_shoulder",
				"abd offset = %f rad, expected +π/2" % offset.z)
	if absf(offset.x) > 1e-4 or absf(offset.y) > 1e-4:
		return _fail("rest_offset_ball_shoulder",
				"flex/rot offsets should be ~0, got (%f, %f)" % [offset.x, offset.y])
	return _ok("rest_offset_ball_shoulder_t_pose_abd_offset")


func _test_rest_offset_ball_hip_aligned_returns_zero() -> bool:
	# T-pose hip: leg straight down, rest_along = -muscle_frame.up = canonical_along.
	# Angle = 0 → offset = ZERO without going through the rotation math.
	var hips := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0))
	var hip := Transform3D(Basis.IDENTITY, Vector3(0.2, 1.0, 0.0))
	var knee := Transform3D(Basis.IDENTITY, Vector3(0.2, 0.0, 0.0))
	var mf := MuscleFrame.new()
	var entry := BoneEntry.new()
	entry.archetype = BoneArchetype.Type.BALL
	entry.is_left_side = true
	entry.calculated_anatomical_basis = Basis.IDENTITY
	entry.use_calculated_frame = true
	var offset: Vector3 = BoneProfileGenerator._compute_rest_offset(
			BoneArchetype.Type.BALL, hip, knee, hips,
			mf, entry, &"LeftUpperLeg")
	if not offset.is_equal_approx(Vector3.ZERO):
		return _fail("rest_offset_ball_hip",
				"hip with rest=canonical should yield zero offset, got %s" % offset)
	return _ok("rest_offset_ball_hip_aligned_returns_zero")


func _test_rest_offset_saddle_foot_horizontal_returns_zero() -> bool:
	# T-pose ankle: leg vertical, foot pointing forward. canonical_along for
	# Foot = muscle_frame.forward, rest_along = forward → angle = 0.
	var leg := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0))
	var foot := Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.0))
	var toes := Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -0.3))  # forward = -Z in MuscleFrame default
	var mf := MuscleFrame.new()
	var entry := BoneEntry.new()
	entry.archetype = BoneArchetype.Type.SADDLE
	entry.is_left_side = true
	entry.calculated_anatomical_basis = Basis.IDENTITY
	entry.use_calculated_frame = true
	var offset: Vector3 = BoneProfileGenerator._compute_rest_offset(
			BoneArchetype.Type.SADDLE, foot, toes, leg,
			mf, entry, &"LeftFoot")
	if not offset.is_equal_approx(Vector3.ZERO):
		return _fail("rest_offset_saddle_foot",
				"horizontal foot in T-pose should yield zero offset, got %s" % offset)
	return _ok("rest_offset_saddle_foot_horizontal_returns_zero")


func _test_anatomical_pose_subtracts_rest_offset() -> bool:
	# Slider value of `rest_offset` should land the bone exactly on rest pose
	# (Quaternion.IDENTITY) regardless of which axis the offset is on.
	var entry := BoneEntry.new()
	entry.rest_anatomical_offset = Vector3(deg_to_rad(15.0), 0.0, 0.0)
	var q := AnatomicalPose.bone_local_rotation(
			entry, deg_to_rad(15.0), 0.0, 0.0)
	if not q.is_equal_approx(Quaternion.IDENTITY):
		return _fail("anatomical_pose_subtracts_offset",
				"flex=15° with rest_offset.x=15° should give IDENTITY, got %s" % q)
	# Mid-range slider: input flex = 90° canonical → joint angle = 75°.
	var q_mid := AnatomicalPose.bone_local_rotation(
			entry, deg_to_rad(90.0), 0.0, 0.0)
	var expected_mid := Quaternion(Vector3(1.0, 0.0, 0.0), deg_to_rad(75.0))
	if not q_mid.is_equal_approx(expected_mid):
		return _fail("anatomical_pose_subtracts_offset",
				"flex=90°−15° offset should be 75° around +X, got %s" % q_mid)
	return _ok("anatomical_pose_subtracts_rest_offset")


func _test_anatomical_pose_canonical_zero_at_offset() -> bool:
	# Slider at canonical zero (flex=0) on a 15°-offset bone should rotate the
	# bone *back* from rest by -15° around the joint's +X — that's the joint
	# angle that takes the bone from rest to the canonical anatomical zero
	# pose (e.g., a fully-straightened A-pose elbow).
	var entry := BoneEntry.new()
	entry.rest_anatomical_offset = Vector3(deg_to_rad(15.0), 0.0, 0.0)
	var q := AnatomicalPose.bone_local_rotation(entry, 0.0, 0.0, 0.0)
	var expected := Quaternion(Vector3(1.0, 0.0, 0.0), deg_to_rad(-15.0))
	if not q.is_equal_approx(expected):
		return _fail("anatomical_pose_canonical_zero",
				"flex=0 with rest_offset.x=15° should be -15° around +X, got %s" % q)
	return _ok("anatomical_pose_canonical_zero_at_offset")


func _test_build_ragdoll_rom_shifted_by_rest_offset() -> bool:
	# Build the synthetic ragdoll, manually set rest_offset on LeftUpperLeg's
	# entry, rebuild, and confirm the joint constraint bounds shift by the
	# negation of the offset on every axis. Catches regressions in the
	# `_apply_joint_constraints` shift independently of the generator wiring.
	var m := _build_synthetic_marionette()
	var sim := _find_simulator(m)
	var leg := _find_bone(sim, "LeftUpperLeg")
	var entry := leg.bone_entry
	# Synthetic baseline already has all-zero offsets — set non-zero values on
	# every axis so a missed shift on any axis fails the test.
	var offset := Vector3(deg_to_rad(7.0), deg_to_rad(-3.0), deg_to_rad(11.0))
	entry.rest_anatomical_offset = offset
	# Re-bake constraints using the same code path as build_ragdoll.
	Marionette._apply_joint_constraints(leg, entry)

	# _apply_joint_constraints writes degrees (Jolt unit quirk fix in
	# slice 3) — convert expected values from rad to deg before compare.
	# LeftUpperLeg is BALL: no HINGE X-flip applies, no mirror_abd, so the
	# expected value is rom - offset on every axis as the original test
	# computed, just unit-shifted.
	var checks := {
		"joint_constraints/x/angular_limit_lower": rad_to_deg(entry.rom_min.x - offset.x),
		"joint_constraints/x/angular_limit_upper": rad_to_deg(entry.rom_max.x - offset.x),
		"joint_constraints/y/angular_limit_lower": rad_to_deg(entry.rom_min.y - offset.y),
		"joint_constraints/y/angular_limit_upper": rad_to_deg(entry.rom_max.y - offset.y),
		"joint_constraints/z/angular_limit_lower": rad_to_deg(entry.rom_min.z - offset.z),
		"joint_constraints/z/angular_limit_upper": rad_to_deg(entry.rom_max.z - offset.z),
	}
	for path: String in checks:
		var got: float = leg.get(path)
		var want: float = checks[path]
		if not is_equal_approx(got, want):
			m.free()
			return _fail("rom_shifted_by_offset",
					"%s = %f, expected %f (rest_offset shift)" % [path, got, want])
	m.free()
	return _ok("build_ragdoll_rom_shifted_by_rest_offset")


# ---------- BoneNameNormalizer / BoneNameDictionary / BoneMapAutoFiller ------

const _TEST_RIG_DIR := "res://tests/marionette/skeletons/"


func _normalizer_check(raw: String, expected_tokens: Array, expected_side: int,
		test_name: String) -> bool:
	var got: Dictionary = BoneNameNormalizer.normalize(raw)
	var got_tokens: PackedStringArray = got["tokens"]
	if got["side"] != expected_side:
		return _fail(test_name,
				"%s → side=%d, expected %d" % [raw, got["side"], expected_side])
	if got_tokens.size() != expected_tokens.size():
		return _fail(test_name, "%s → tokens=%s, expected %s"
				% [raw, str(got_tokens), str(expected_tokens)])
	for i: int in got_tokens.size():
		if got_tokens[i] != String(expected_tokens[i]):
			return _fail(test_name, "%s → tokens=%s, expected %s"
					% [raw, str(got_tokens), str(expected_tokens)])
	return true


func _test_normalizer_arp_examples() -> bool:
	var cases: Array = [
		# raw, expected_tokens, expected_side
		["root.x", ["root"], BoneNameNormalizer.Side.CENTER],
		["spine_01.x", ["spine", "1"], BoneNameNormalizer.Side.CENTER],
		["head.x", ["head"], BoneNameNormalizer.Side.CENTER],
		["shoulder.l", ["shoulder"], BoneNameNormalizer.Side.LEFT],
		["arm_stretch.l", ["arm"], BoneNameNormalizer.Side.LEFT],
		["forearm_stretch.r", ["forearm"], BoneNameNormalizer.Side.RIGHT],
		["c_thumb1.l", ["thumb", "1"], BoneNameNormalizer.Side.LEFT],
		["c_pinky3.r", ["pinky", "3"], BoneNameNormalizer.Side.RIGHT],
		["thigh_stretch.l", ["thigh"], BoneNameNormalizer.Side.LEFT],
		["c_toes_thumb1.l", ["toes", "thumb", "1"], BoneNameNormalizer.Side.LEFT],
	]
	for case: Array in cases:
		if not _normalizer_check(case[0], case[1], case[2], "normalizer_arp"):
			return false
	return _ok("normalizer_arp_examples")


func _test_normalizer_mixamo_examples() -> bool:
	var cases: Array = [
		["mixamorig:Hips", ["hips"], BoneNameNormalizer.Side.NONE],
		["mixamorig:Spine", ["spine"], BoneNameNormalizer.Side.NONE],
		["mixamorig:Spine1", ["spine", "1"], BoneNameNormalizer.Side.NONE],
		["mixamorig:LeftShoulder", ["shoulder"], BoneNameNormalizer.Side.LEFT],
		["mixamorig:LeftArm", ["arm"], BoneNameNormalizer.Side.LEFT],
		["mixamorig:LeftForeArm", ["fore", "arm"], BoneNameNormalizer.Side.LEFT],
		["mixamorig:LeftHandThumb1", ["hand", "thumb", "1"], BoneNameNormalizer.Side.LEFT],
		["mixamorig:LeftUpLeg", ["up", "leg"], BoneNameNormalizer.Side.LEFT],
		["mixamorig:RightToeBase", ["toe"], BoneNameNormalizer.Side.RIGHT],  # _base in noise
	]
	for case: Array in cases:
		if not _normalizer_check(case[0], case[1], case[2], "normalizer_mixamo"):
			return false
	return _ok("normalizer_mixamo_examples")


func _test_normalizer_rigify_examples() -> bool:
	var cases: Array = [
		["DEF-spine", ["spine"], BoneNameNormalizer.Side.NONE],
		["DEF-spine.001", ["spine", "1"], BoneNameNormalizer.Side.NONE],
		["DEF-spine.006", ["spine", "6"], BoneNameNormalizer.Side.NONE],
		["DEF-shoulder.L", ["shoulder"], BoneNameNormalizer.Side.LEFT],
		["DEF-upper_arm.L", ["upper", "arm"], BoneNameNormalizer.Side.LEFT],
		["DEF-forearm.R", ["forearm"], BoneNameNormalizer.Side.RIGHT],
		["DEF-f_index.01.L", ["index", "1"], BoneNameNormalizer.Side.LEFT],  # `f` in noise
		["DEF-thumb.02.L", ["thumb", "2"], BoneNameNormalizer.Side.LEFT],
		["DEF-thigh.L", ["thigh"], BoneNameNormalizer.Side.LEFT],
		["DEF-toe.R", ["toe"], BoneNameNormalizer.Side.RIGHT],
	]
	for case: Array in cases:
		if not _normalizer_check(case[0], case[1], case[2], "normalizer_rigify"):
			return false
	return _ok("normalizer_rigify_examples")


func _test_normalizer_godot_arp_examples() -> bool:
	# godot_ARP rig (ARP with "Rename for Godot" enabled): standard humanoid
	# names get Godot-native PascalCase, but ARP's toe extensions keep their
	# `c_toes_*` names with `Left`/`Right` prefixed → `Leftc_toes_thumb1`.
	var cases: Array = [
		["Hips", ["hips"], BoneNameNormalizer.Side.NONE],
		["Spine", ["spine"], BoneNameNormalizer.Side.NONE],
		["LeftFoot", ["foot"], BoneNameNormalizer.Side.LEFT],
		["LeftUpperArm", ["upper", "arm"], BoneNameNormalizer.Side.LEFT],
		["RightThumbMetacarpal", ["thumb", "metacarpal"], BoneNameNormalizer.Side.RIGHT],
		# `Leftc_toes_thumb1` — the Step 1 Left/Right prefix split is what makes
		# this case work; without it `Leftc` would become a single token.
		["Leftc_toes_thumb1", ["toes", "thumb", "1"], BoneNameNormalizer.Side.LEFT],
		["Rightc_toes_pinky3", ["toes", "pinky", "3"], BoneNameNormalizer.Side.RIGHT],
	]
	for case: Array in cases:
		if not _normalizer_check(case[0], case[1], case[2], "normalizer_godot_arp"):
			return false
	return _ok("normalizer_godot_arp_examples")


func _test_normalizer_side_compatibility() -> bool:
	var S := BoneNameNormalizer.Side
	# Slot side derivation.
	if BoneNameNormalizer.slot_required_side(&"LeftShoulder") != S.LEFT:
		return _fail("side_compat", "slot_required_side(LeftShoulder) != LEFT")
	if BoneNameNormalizer.slot_required_side(&"RightFoot") != S.RIGHT:
		return _fail("side_compat", "slot_required_side(RightFoot) != RIGHT")
	if BoneNameNormalizer.slot_required_side(&"Hips") != S.NONE:
		return _fail("side_compat", "slot_required_side(Hips) != NONE")
	# Compatibility table.
	if not BoneNameNormalizer.sides_compatible(S.LEFT, S.LEFT):
		return _fail("side_compat", "L vs L should be compatible")
	if BoneNameNormalizer.sides_compatible(S.RIGHT, S.LEFT):
		return _fail("side_compat", "R vs L should NOT be compatible")
	if BoneNameNormalizer.sides_compatible(S.LEFT, S.NONE):
		return _fail("side_compat", "L vs NONE should NOT be compatible")
	if not BoneNameNormalizer.sides_compatible(S.NONE, S.NONE):
		return _fail("side_compat", "NONE vs NONE should be compatible")
	if not BoneNameNormalizer.sides_compatible(S.CENTER, S.NONE):
		return _fail("side_compat", "CENTER vs NONE should be compatible")
	return _ok("normalizer_side_compatibility")


func _test_dictionary_all_slots_have_some_entry() -> bool:
	# Every slot except {Root, LeftEye, RightEye, Jaw} (intentionally sparse)
	# should resolve at least one expected name across all conventions.
	var expected_empty: Dictionary = {
		&"Root": true,  # ARP `c_traj` is locomotion-only — intentionally unmapped.
	}
	for slot_str: String in BoneNameDictionary.SLOT_NAMES:
		var slot: StringName = StringName(slot_str)
		var names: PackedStringArray = BoneNameDictionary.expected_names(slot)
		if names.is_empty() and not expected_empty.has(slot):
			return _fail("dict_complete",
					"slot %s has no expected names across any convention" % slot_str)
	return _ok("dictionary_all_slots_have_some_entry")


func _test_dictionary_left_right_mirror_consistent() -> bool:
	# For every Left* slot, the corresponding Right* slot's expected names
	# should be bone-for-bone mirrors (same conventions, just sided).
	var d: Dictionary = BoneNameDictionary.slot_dict()
	for slot_str: String in BoneNameDictionary.SLOT_NAMES:
		if not slot_str.begins_with("Left"):
			continue
		var right_slot_str: String = "Right" + slot_str.substr(4)
		var left_dict: Dictionary = d.get(StringName(slot_str), {})
		var right_dict: Dictionary = d.get(StringName(right_slot_str), {})
		if left_dict.size() != right_dict.size():
			return _fail("dict_mirror",
					"%s has %d entries but %s has %d"
					% [slot_str, left_dict.size(), right_slot_str, right_dict.size()])
		for conv in left_dict:
			if not right_dict.has(conv):
				return _fail("dict_mirror",
						"%s convention %s missing from %s"
						% [slot_str, conv, right_slot_str])
	return _ok("dictionary_left_right_mirror_consistent")


func _test_dictionary_no_collisions_within_convention() -> bool:
	# Within a single convention, no two slots should share the same expected
	# bone name (would mean two slots fight for the same source bone).
	var d: Dictionary = BoneNameDictionary.slot_dict()
	var per_conv_seen: Dictionary = {}
	for slot in d:
		var entries: Dictionary = d[slot]
		for conv: String in entries:
			var name: String = entries[conv]
			if name.is_empty():
				continue
			var key: String = "%s|%s" % [conv, name]
			if per_conv_seen.has(key):
				return _fail("dict_collision",
						"convention %s assigns %s to both %s and %s"
						% [conv, name, per_conv_seen[key], slot])
			per_conv_seen[key] = slot
	return _ok("dictionary_no_collisions_within_convention")


func _load_glb_skeleton(rel_path: String) -> Skeleton3D:
	var doc: GLTFDocument = GLTFDocument.new()
	var state: GLTFState = GLTFState.new()
	var abs_path: String = ProjectSettings.globalize_path(_TEST_RIG_DIR + rel_path)
	var err: int = doc.append_from_file(abs_path, state)
	if err != OK:
		push_error("load_glb_skeleton: append_from_file(%s) returned %d" % [abs_path, err])
		return null
	var root: Node = doc.generate_scene(state)
	if root == null:
		return null
	return _find_skeleton3d(root)


func _find_skeleton3d(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var r: Skeleton3D = _find_skeleton3d(c)
		if r != null:
			return r
	return null


func _auto_fill_glb(rel_path: String, min_filled: int, test_name: String) -> bool:
	var skel: Skeleton3D = _load_glb_skeleton(rel_path)
	if skel == null:
		return _fail(test_name, "could not load %s" % rel_path)
	var results: Dictionary = BoneMapAutoFiller.auto_fill(skel)
	skel.queue_free()
	# Report fill counts per confidence bucket for diagnostic purposes.
	var exact: int = 0
	var strong: int = 0
	var partial: int = 0
	for slot in results:
		var c: float = results[slot]["confidence"]
		if c >= 0.95: exact += 1
		elif c >= 0.85: strong += 1
		else: partial += 1
	print("  [%s] %s → filled=%d (exact=%d strong=%d partial=%d) of %d slots"
			% [test_name, rel_path, results.size(), exact, strong, partial,
			BoneNameDictionary.SLOT_NAMES.size()])
	if results.size() < min_filled:
		return _fail(test_name, "only %d slots filled, expected ≥ %d"
				% [results.size(), min_filled])
	return true


func _test_auto_filler_arp_glb() -> bool:
	# Full ARP rig with 432 bones — most are helpers/IK/FK. Should still find
	# the deform-bone subset for the body axis, arms, hands, legs, toes.
	# Expecting: 7 spine + 8 arms + 30 fingers + 8 legs + 28 toes = 81.
	# Allow some slack for unmapped Root/Eyes/Jaw (4 expected unmapped).
	if not _auto_fill_glb("ARP.glb", 75, "auto_filler_arp"):
		return false
	return _ok("auto_filler_arp_glb")


func _test_auto_filler_godot_arp_glb() -> bool:
	# Godot-renamed ARP: 96 bones, native humanoid + ARP toe extensions.
	# Should fill nearly all slots (no eyes/jaw on this rig either).
	if not _auto_fill_glb("godot_ARP.glb", 75, "auto_filler_godot_arp"):
		return false
	return _ok("auto_filler_godot_arp_glb")


func _test_auto_filler_mixamo_glb() -> bool:
	# Mixamo: 65 bones. No metacarpals (except thumb), no individual toes
	# (only LeftToeBase / RightToeBase aggregate), no UpperChest. Expect:
	# Hips, Spine, Spine1=Chest, Spine2=UpperChest? actually three spines:
	# (Hips, Spine, Chest, UpperChest, Neck, Head) = 6
	# + 4×2 = 8 arms + 6 thumbs (3×2) + 24 fingers (3×4×2) = 30 hand
	# + 4×2 = 8 legs (incl ToeBase as Toes) = 6 + 8 + 30 + 8 = 52.
	if not _auto_fill_glb("Mixamo.glb", 50, "auto_filler_mixamo"):
		return false
	return _ok("auto_filler_mixamo_glb")


func _test_auto_filler_rigify_glb() -> bool:
	# Rigify rig: 918 bones, only DEF-* are deform. After helper exclusion:
	# 7 spine + 8 arms + 6 thumbs + 24 fingers + 8 legs + 2 toes (DEF-toe
	# only, no phalanges) = ~55.
	if not _auto_fill_glb("Rigify_nomesh.glb", 50, "auto_filler_rigify"):
		return false
	return _ok("auto_filler_rigify_glb")


func _test_auto_filler_preserves_existing_entries() -> bool:
	# When an existing BoneMap has a non-empty entry, auto-fill must NOT
	# overwrite it — even if the auto-fill would have picked something else.
	var skel: Skeleton3D = _load_glb_skeleton("Mixamo.glb")
	if skel == null:
		return _fail("autofill_preserve", "could not load Mixamo.glb")
	var bm: BoneMap = BoneMap.new()
	bm.profile = load("res://addons/marionette/scripts/data/marionette_humanoid_profile.tres")
	# Pre-set an entry the auto-filler would choose differently.
	bm.set_skeleton_bone_name(&"Hips", &"_user_pinned_value")
	var results: Dictionary = BoneMapAutoFiller.auto_fill(skel, bm)
	BoneMapAutoFiller.apply_to_bone_map(bm, results)
	skel.queue_free()
	var hips_after: StringName = bm.get_skeleton_bone_name(&"Hips")
	if String(hips_after) != "_user_pinned_value":
		return _fail("autofill_preserve",
				"Hips overwritten to %s — should have stayed _user_pinned_value"
				% String(hips_after))
	# But empty slots should still be filled — verify Spine got something.
	var spine_after: StringName = bm.get_skeleton_bone_name(&"Spine")
	if String(spine_after).is_empty():
		return _fail("autofill_preserve",
				"Spine slot stayed empty — auto-fill didn't run for unfilled slots")
	return _ok("auto_filler_preserves_existing_entries")
