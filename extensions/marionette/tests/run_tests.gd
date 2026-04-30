extends SceneTree


const HUMANOID_PROFILE_PATH := "res://addons/marionette/data/marionette_humanoid_profile.tres"


func _init() -> void:
	var passed: int = 0
	var failed: int = 0

	for test_callable: Callable in [
		_test_smoke,
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
	if not is_equal_approx(p.total_mass, 70.0):
		return _fail("bone_profile_defaults", "total_mass default should be 70.0")
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
	# Bent-knee fixture: upper leg goes from hip (0.1, 1.0, 0) downward to knee
	# (0.1, 0.5, 0). Lower leg is bent forward by 30°. Ankle sits forward-and-
	# below the knee. The hinge axis = parent_along × along, both in the YZ
	# plane, so the result lies along world ±X (body lateral).
	var frame := _make_muscle_frame_fixture()
	var hip := Transform3D(Basis.IDENTITY, Vector3(0.1, 1.0, 0))
	var bend := Basis.from_euler(Vector3(deg_to_rad(-30.0), 0, 0))
	var lower_leg := Transform3D(bend, Vector3(0.1, 0.5, 0))
	var ankle_offset := bend * Vector3(0, -0.5, 0)
	var ankle := Transform3D(Basis.IDENTITY, lower_leg.origin + ankle_offset)

	var basis := MarionetteHingeSolver.solve(lower_leg, ankle, frame, true, hip)
	if not _basis_is_orthonormal(basis):
		return _fail("hinge_solver_bent_knee", "non-orthonormal basis")
	# Hinge axis (basis.x = flex) should align with the body lateral axis. In
	# this fixture parent_along (knee→hip's reverse, i.e., (0,-1,0)) and along
	# (knee→ankle, in the YZ plane) cross to produce ±X.
	var dot_with_lateral: float = absf(basis.x.dot(Vector3.RIGHT))
	if dot_with_lateral < 0.99:
		return _fail("hinge_solver_bent_knee",
			"flex=%s, expected to align with world ±X (|dot|=%f)" % [basis.x, dot_with_lateral])
	# Sign: the solver flips so flex.dot(limb_flex_axis) >= 0. limb_flex_axis
	# for a left-side bone = -muscle_frame.right = +X. So basis.x ≈ +X.
	if basis.x.dot(Vector3.RIGHT) < 0.0:
		return _fail("hinge_solver_bent_knee", "flex points opposite to lateral_outward")
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

	# Shoulder: flex 0..150°, abd 0..150°.
	if not is_equal_approx(shoulder.rom_min.x, 0.0):
		return _fail("rom_shoulder", "flex_min=%f, expected 0" % shoulder.rom_min.x)
	if not is_equal_approx(shoulder.rom_max.x, deg_to_rad(150.0)):
		return _fail("rom_shoulder", "flex_max=%f, expected 150°" % rad_to_deg(shoulder.rom_max.x))
	if not is_equal_approx(shoulder.rom_max.z, deg_to_rad(150.0)):
		return _fail("rom_shoulder", "abd_max=%f, expected 150°" % rad_to_deg(shoulder.rom_max.z))

	# Hip: flex -15..100°, abd 0..40°.
	if not is_equal_approx(hip.rom_min.x, deg_to_rad(-15.0)):
		return _fail("rom_hip", "flex_min=%f, expected -15°" % rad_to_deg(hip.rom_min.x))
	if not is_equal_approx(hip.rom_max.x, deg_to_rad(100.0)):
		return _fail("rom_hip", "flex_max=%f, expected 100°" % rad_to_deg(hip.rom_max.x))
	if not is_equal_approx(hip.rom_max.z, deg_to_rad(40.0)):
		return _fail("rom_hip", "abd_max=%f, expected 40°" % rad_to_deg(hip.rom_max.z))

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
	# shares the phalanx ROM by archetype fallback.
	var toes := BoneEntry.new()
	toes.archetype = BoneArchetype.Type.HINGE
	MarionetteRomDefaults.apply(toes, &"LeftToes")
	if not is_equal_approx(toes.rom_max.x, deg_to_rad(80.0)):
		return _fail("rom_phalanx", "Toes block flex_max=%f, expected 80°" % rad_to_deg(toes.rom_max.x))
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

	# Shoulder: BALL, abd_max = 150° (UpperArm-specific).
	var shoulder: BoneEntry = bp.bones[&"LeftUpperArm"]
	if not is_equal_approx(shoulder.rom_max.z, deg_to_rad(150.0)):
		return _fail("generator_rom", "LeftUpperArm abd_max=%f°, expected 150°" %
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
	var b := MarionetteBone.new()
	var ok := b is PhysicalBone3D
	b.free()
	if not ok:
		return _fail("marionette_bone_class", "MarionetteBone should extend PhysicalBone3D")
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
	bp.total_mass = 70.0

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
	bp.total_mass = 70.0
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

	var checks := {
		"joint_constraints/x/angular_limit_lower": entry.rom_min.x,
		"joint_constraints/x/angular_limit_upper": entry.rom_max.x,
		"joint_constraints/y/angular_limit_lower": entry.rom_min.y,
		"joint_constraints/y/angular_limit_upper": entry.rom_max.y,
		"joint_constraints/z/angular_limit_lower": entry.rom_min.z,
		"joint_constraints/z/angular_limit_upper": entry.rom_max.z,
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
	# all_abd_add should include EVERY region-mapped bone.
	var inf: Dictionary = MarionetteMacroPresets.influences_for(MarionetteMacroPresets.KEY_ALL_ABD_ADD)
	var mapped: Array[StringName] = MarionetteBoneRegion.all_mapped_bones()
	if inf.size() != mapped.size():
		return _fail("macro_all", "inf size %d, mapped %d" % [inf.size(), mapped.size()])
	for bn: StringName in mapped:
		if not inf.has(bn):
			return _fail("macro_all", "missing %s" % bn)
		if not (inf[bn] as Vector3).is_equal_approx(Vector3(0, 0, 1)):
			return _fail("macro_all", "%s coeff=%s expected (0,0,1)" % [bn, inf[bn]])
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
