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
		_test_bone_profile_generator_null_skeleton_profile_errors,
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
	# On MarionetteHumanoidProfile (Y-up, character built facing -Z, LeftUpperLeg at +X):
	#   right   ≈ (-1, 0, 0)
	#   up      ≈ (0, 1, 0)
	#   forward ≈ (0, 0, -1)
	var profile := load(HUMANOID_PROFILE_PATH) as SkeletonProfile
	if profile == null:
		return _fail("muscle_frame_humanoid", "could not load profile")

	var frame := MuscleFrameBuilder.build(profile)

	if not frame.up.is_equal_approx(Vector3.UP):
		return _fail("muscle_frame_humanoid", "up=%s, expected (0,1,0)" % frame.up)
	if not frame.right.is_equal_approx(Vector3.LEFT):
		# Vector3.LEFT == (-1,0,0) — character's right side, since LeftUpperLeg is at +X.
		return _fail("muscle_frame_humanoid", "right=%s, expected (-1,0,0)" % frame.right)
	if not frame.forward.is_equal_approx(Vector3.FORWARD):
		# Vector3.FORWARD == (0,0,-1).
		return _fail("muscle_frame_humanoid", "forward=%s, expected (0,0,-1)" % frame.forward)
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
	# (right, up, forward) is a right-handed triple: right × up = forward.
	# Note this is unusual — Godot's Node3D basis stores (right, up, back),
	# i.e., right × up = back = -forward. Our MuscleFrame names the third axis
	# anatomically (forward = where the character faces), so the cross product
	# convention flips sign relative to Godot's basis.
	var rxu: Vector3 = frame.right.cross(frame.up)
	if not rxu.is_equal_approx(frame.forward):
		return _fail("muscle_frame_orthonormal",
			"right×up=%s, expected forward=%s" % [rxu, frame.forward])
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
	# (0.1, 0.5, 0). Lower leg's bone-rest is *bent forward* — its bone-local
	# +Y points forward-and-down. Child (ankle) is forward of the knee.
	# Hinge axis should land on the lateral axis.
	var frame := _make_muscle_frame_fixture()
	# The "bone" (lower leg) sits at the knee. Its rest basis has +Y along the
	# lower-leg direction, which is bent forward by say 30°.
	var bend := Basis.from_euler(Vector3(deg_to_rad(-30.0), 0, 0))   # rotate around +X
	var lower_leg := Transform3D(bend, Vector3(0.1, 0.5, 0))
	# Ankle world position: knee + bend * (0,-0.5,0) = knee + (0, -0.5*cos30, 0.5*sin30)
	# Note: rotating (0,-0.5,0) by -30° around +X gives (0, -0.433, 0.25).
	var ankle_offset := bend * Vector3(0, -0.5, 0)
	var ankle := Transform3D(Basis.IDENTITY, lower_leg.origin + ankle_offset)

	var basis := MarionetteHingeSolver.solve(lower_leg, ankle, frame, true)
	if not _basis_is_orthonormal(basis):
		return _fail("hinge_solver_bent_knee", "non-orthonormal basis")
	# Hinge axis (basis.x = flex) should align with the body lateral axis,
	# which is the cross product of the bone's parent_along and the
	# child-direction. In this fixture both vectors lie in the YZ plane, so
	# the hinge axis lies along world ±X. We just check it's nearly lateral.
	var dot_with_lateral: float = absf(basis.x.dot(Vector3.RIGHT))
	if dot_with_lateral < 0.99:
		return _fail("hinge_solver_bent_knee",
			"flex=%s, expected to align with world ±X (|dot|=%f)" % [basis.x, dot_with_lateral])
	# Sign: the solver flips so flex.dot(limb_flex_axis) >= 0. limb_flex_axis
	# for a left-side bone = -muscle_frame.right = +X. So basis.x ≈ +X.
	if basis.x.dot(Vector3.RIGHT) < 0.0:
		return _fail("hinge_solver_bent_knee", "flex points opposite to lateral_outward")
	return _ok("hinge_solver_bent_knee")


func _test_clavicle_solver_flex_axis_is_up() -> bool:
	# Synthetic left clavicle: bone at base of neck, runs laterally to shoulder.
	# Flex axis should be UP (so flex motion = shrug elevation).
	var frame := _make_muscle_frame_fixture()
	var clav := Transform3D(Basis.IDENTITY, Vector3(0, 1.5, 0))
	var shoulder := Transform3D(Basis.IDENTITY, Vector3(0.15, 1.5, 0))   # along +X (lateral)
	var basis := MarionetteClavicleSolver.solve(clav, shoulder, frame, true)
	if not _basis_is_orthonormal(basis):
		return _fail("clavicle_flex_axis", "non-orthonormal")
	# Along-bone should be +X (lateral). Flex axis should be perpendicular to
	# it AND closest to +Y (up).
	if not basis.y.is_equal_approx(Vector3.RIGHT):
		return _fail("clavicle_flex_axis", "along=%s, expected (1,0,0)" % basis.y)
	if not basis.x.is_equal_approx(Vector3.UP):
		return _fail("clavicle_flex_axis", "flex=%s, expected (0,1,0)" % basis.x)
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
	# Flex axis should be lateral (+X = body left = -muscle_frame.right).
	if not basis.x.is_equal_approx(Vector3.RIGHT):
		return _fail("spine_along", "flex=%s, expected (1,0,0)" % basis.x)
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
