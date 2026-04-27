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
