extends SceneTree

# Headless ragdoll stability tuner.
#
# Loops a parameter grid, runs each combination on the kasumi rig with
# anatomical masses + bone collisions on, measures stability (time until
# any bone exceeds an explosion threshold), and prints a results table.
#
# Stability metric:
#   stable_s     — time in sim seconds before any bone exceeded velocity
#                  or dispersion threshold; SIM_SECONDS = "didn't explode".
#   max_speed    — peak |linear_velocity| seen across all bones at any tick.
#   max_dispers  — peak distance any bone moved from its initial position.
#
# Run:
#   godot --headless --path /home/caetano/desktop/cosmic-bliss/game \
#         --script /home/caetano/desktop/cosmic-bliss/extensions/marionette/tests/ragdoll_tuner.gd

const KASUMI_SCENE: String = "res://tests/marionette/kasumi/kasumi.tscn"
const SIM_SECONDS: float = 15.0
const PHYSICS_RATE: int = 60
const EXPLOSION_VELOCITY: float = 50.0   # m/s; floor impacts can hit ~25 transiently
const EXPLOSION_DISPERSION: float = 4.0  # meters from initial position
const JOINT_AXES: Array[String] = ["x", "y", "z"]

# Anatomical mass distribution copied from ragdoll_physics_test.gd. Bones
# missing from the table fall back to ANATOMICAL_DEFAULT (50 g for the
# small phalanges).
const ANATOMICAL: Dictionary = {
	"Root": 0.5,
	"Hips": 12.0, "Spine": 6.0, "Chest": 8.0, "UpperChest": 6.0,
	"Neck": 1.0, "Head": 4.5,
	"LeftShoulder": 0.7,  "RightShoulder": 0.7,
	"LeftUpperArm": 2.0,  "RightUpperArm": 2.0,
	"LeftLowerArm": 1.2,  "RightLowerArm": 1.2,
	"LeftHand": 0.4,      "RightHand": 0.4,
	"LeftUpperLeg": 9.0,  "RightUpperLeg": 9.0,
	"LeftLowerLeg": 4.0,  "RightLowerLeg": 4.0,
	"LeftFoot": 0.8,      "RightFoot": 0.8,
}
const ANATOMICAL_DEFAULT: float = 0.05

# Tether bone names per region — same set the interactive scene uses for
# the Standing preset.
const TETHER_BONES_BY_REGION: Dictionary = {
	"hips":  ["Hips"],
	"spine": ["Spine", "Chest", "UpperChest"],
	"head":  ["Head"],
	"hands": ["LeftHand", "RightHand"],
	"feet":  ["LeftFoot", "RightFoot"],
}
const TETHER_DAMPING_RATIO: float = 1.0
const PHYSICS_DT: float = 1.0 / float(PHYSICS_RATE)

# Each row of the sweep table. Tweak between runs to bisect toward stability.
# k = angular spring stiffness, c = angular spring damping
# soft = angular limit softness, limit_damp = angular limit damping
# body_damp = linear+angular damp on each bone
# spring_on = whether to enable the angular spring at all
# Round 2 — bisect around no_spring + body_damp_2 (best from round 1) and
# stress-test with a one-shot impulse perturbation per bone at t=0.5s.
# Without perturbation, the character barely moves once it lands; with it,
# we get a controlled measure of "how much does the rig amplify a kick".
# Round 4: tethers active + bigger kick + sustained drag-on-finger force
# (matching what the user's drag manipulator actually applies). Two new
# stress patterns:
#   imp >= 2.0 — random per-bone kick stronger than typical contact
#   drag_bone / drag_force — continuous force on a single named bone for
#                            the entire run. Mimics LMB-drag on a fingertip.
const ALL_REGIONS: Array = ["hips", "spine", "head", "hands", "feet"]
var SWEEPS: Array[Dictionary] = [
	# Standing repro at OLD defaults — what user actually sees.
	{"label": "OLD defaults",        "spring_on": true,  "k": 5.0, "c": 0.5, "body_damp": 0.5, "regions": ALL_REGIONS, "tether_omega": 8.0, "gravity_scale": 0.2, "perturb": true, "imp": 2.0, "drag_bone": "", "drag_force": 0.0},
	# Round 3 winner with tethers
	{"label": "no_spring+damp_5",    "spring_on": false, "k": 0.0, "c": 0.0, "body_damp": 5.0, "regions": ALL_REGIONS, "tether_omega": 8.0, "gravity_scale": 0.2, "perturb": true, "imp": 2.0, "drag_bone": "", "drag_force": 0.0},
	# Same but with sustained finger drag
	{"label": "+drag finger 5N",     "spring_on": false, "k": 0.0, "c": 0.0, "body_damp": 5.0, "regions": ALL_REGIONS, "tether_omega": 8.0, "gravity_scale": 0.2, "perturb": false, "imp": 0.0, "drag_bone": "LeftIndexDistal", "drag_force": 5.0},
	{"label": "+drag finger 15N",    "spring_on": false, "k": 0.0, "c": 0.0, "body_damp": 5.0, "regions": ALL_REGIONS, "tether_omega": 8.0, "gravity_scale": 0.2, "perturb": false, "imp": 0.0, "drag_bone": "LeftIndexDistal", "drag_force": 15.0},
	{"label": "+drag finger 30N",    "spring_on": false, "k": 0.0, "c": 0.0, "body_damp": 5.0, "regions": ALL_REGIONS, "tether_omega": 8.0, "gravity_scale": 0.2, "perturb": false, "imp": 0.0, "drag_bone": "LeftIndexDistal", "drag_force": 30.0},
	# Higher damp under finger drag
	{"label": "damp_15 +drag 30N",   "spring_on": false, "k": 0.0, "c": 0.0, "body_damp": 15.0,"regions": ALL_REGIONS, "tether_omega": 8.0, "gravity_scale": 0.2, "perturb": false, "imp": 0.0, "drag_bone": "LeftIndexDistal", "drag_force": 30.0},
	{"label": "damp_30 +drag 30N",   "spring_on": false, "k": 0.0, "c": 0.0, "body_damp": 30.0,"regions": ALL_REGIONS, "tether_omega": 8.0, "gravity_scale": 0.2, "perturb": false, "imp": 0.0, "drag_bone": "LeftIndexDistal", "drag_force": 30.0},
	# Test if dragging the hand directly is more stable than the fingertip
	{"label": "+drag HAND 30N",      "spring_on": false, "k": 0.0, "c": 0.0, "body_damp": 5.0, "regions": ALL_REGIONS, "tether_omega": 8.0, "gravity_scale": 0.2, "perturb": false, "imp": 0.0, "drag_bone": "LeftHand", "drag_force": 30.0},
	# Lower tether ω with finger drag
	{"label": "t_omega_4 +drag 15N", "spring_on": false, "k": 0.0, "c": 0.0, "body_damp": 5.0, "regions": ALL_REGIONS, "tether_omega": 4.0, "gravity_scale": 0.2, "perturb": false, "imp": 0.0, "drag_bone": "LeftIndexDistal", "drag_force": 15.0},
]

var _packed_scene: PackedScene
var _floor_body: StaticBody3D
var _scene_instance: Node
var _marionette: Marionette
var _simulator: PhysicalBoneSimulator3D
var _bones: Array[MarionetteBone] = []
# Initial position per bone, captured fresh at the start of each sweep.
var _initial_pos: Dictionary = {}
# Active tethers for the current sweep — list of {bone, anchor, k, c}.
var _tethers: Array[Dictionary] = []


func _init() -> void:
	print("==== Marionette ragdoll stability tuner ====")
	print("Loading kasumi scene...")
	_packed_scene = load(KASUMI_SCENE)
	if _packed_scene == null:
		push_error("Failed to load kasumi scene")
		quit(1)
		return
	# Floor stays alive across all sweeps — only the kasumi rig is rebuilt.
	_floor_body = _build_floor()
	root.add_child(_floor_body)

	print()
	print("Running %d sweeps, up to %.1fs each. Sim is %d Hz." %
			[SWEEPS.size(), SIM_SECONDS, PHYSICS_RATE])
	print("Explosion thresholds: |v| > %.1f m/s OR dispersion > %.1f m" %
			[EXPLOSION_VELOCITY, EXPLOSION_DISPERSION])
	print()
	print("%-22s | %-9s | %-10s | %-11s | %s" %
			["sweep", "stable_s", "max_speed", "max_dispers", "verdict"])
	print("-".repeat(80))

	for sweep: Dictionary in SWEEPS:
		var result: Dictionary = await _run_sweep(sweep)
		var verdict: String = "STABLE" if result.stable_seconds >= SIM_SECONDS else \
				"exploded@%.2fs" % result.stable_seconds
		print("%-22s | %-9.2f | %-10.2f | %-11.2f | %s" % [
			sweep.label,
			result.stable_seconds,
			result.max_speed,
			result.max_dispersion,
			verdict,
		])

	print()
	print("Done.")
	quit()


# Per-sweep teardown + rebuild. Frees the entire kasumi instance and
# instantiates a fresh one so all of Marionette's runtime state — bone
# transforms, joint internal state, collision-exception lists, body
# RIDs — is reset to scene-default. Slower than reusing one instance,
# but earlier attempts at reset (kinematic-follow + restart, plus
# PhysicsServer3D.body_set_state) leaked enough joint state that
# repeated sweeps with identical params exploded harder each time.
func _setup_fresh_instance() -> void:
	if _scene_instance != null:
		_scene_instance.queue_free()
		await process_frame  # let the free actually happen
		_scene_instance = null
	_bones.clear()

	_scene_instance = _packed_scene.instantiate()
	root.add_child(_scene_instance)
	_marionette = _find_marionette(_scene_instance)
	if _marionette == null:
		push_error("No Marionette node found in fresh instance")
		return
	_marionette.start_simulation()
	_simulator = _find_simulator()
	if _simulator == null:
		push_error("No PhysicalBoneSimulator3D in fresh instance")
		return
	for child: Node in _simulator.get_children():
		if child is MarionetteBone:
			var b: MarionetteBone = child
			b.linear_damp_mode = PhysicalBone3D.DAMP_MODE_REPLACE
			b.angular_damp_mode = PhysicalBone3D.DAMP_MODE_REPLACE
			_bones.append(b)


func _build_floor() -> StaticBody3D:
	var floor_body := StaticBody3D.new()
	floor_body.name = "TunerFloor"
	var shape := BoxShape3D.new()
	shape.size = Vector3(20, 0.4, 20)
	var collider := CollisionShape3D.new()
	collider.shape = shape
	floor_body.add_child(collider)
	floor_body.position = Vector3(0, -0.2, 0)
	return floor_body


func _find_marionette(node: Node) -> Marionette:
	if node is Marionette:
		return node
	for c: Node in node.get_children():
		var m: Marionette = _find_marionette(c)
		if m != null:
			return m
	return null


func _find_simulator() -> PhysicalBoneSimulator3D:
	var skel: Skeleton3D = _marionette.resolve_skeleton()
	if skel == null:
		return null
	for c: Node in skel.get_children():
		if c is PhysicalBoneSimulator3D:
			return c
	return null


func _apply_anatomical_masses() -> void:
	for b: MarionetteBone in _bones:
		var m: float = ANATOMICAL.get(b.bone_name, ANATOMICAL_DEFAULT)
		b.mass = max(m, 0.001)


func _apply_collisions_on() -> void:
	for b: MarionetteBone in _bones:
		b.collision_layer = 1
		b.collision_mask = 1
		for c: Node in b.get_children():
			if c is CollisionShape3D:
				(c as CollisionShape3D).disabled = false


func _apply_gravity_scale(g: float) -> void:
	for b: MarionetteBone in _bones:
		b.gravity_scale = g


# Captures fresh tether anchors at each bone's current world position.
# omega = 0 (or empty regions) → no tethers, list stays empty.
func _setup_tethers(active_regions: Array, omega: float) -> void:
	_tethers.clear()
	if omega <= 0.0 or active_regions.is_empty():
		return
	for region: String in active_regions:
		var bone_names: Array = TETHER_BONES_BY_REGION.get(region, [])
		for bone_name: String in bone_names:
			var b: MarionetteBone = _find_bone_by_name(bone_name)
			if b == null:
				continue
			var mass: float = b.mass
			_tethers.append({
				"bone": b,
				"anchor": b.global_position,
				"k": mass * omega * omega,
				"c": 2.0 * TETHER_DAMPING_RATIO * mass * omega,
			})


func _find_bone_by_name(name: String) -> MarionetteBone:
	for b: MarionetteBone in _bones:
		if b.bone_name == name:
			return b
	return null


func _apply_params(p: Dictionary) -> void:
	var body_damp: float = p.get("body_damp", 0.5)
	var spring_on: bool = p.get("spring_on", false)
	var k: float = p.get("k", 0.0)
	var c: float = p.get("c", 0.0)
	# soft / limit_damp are no-ops in Jolt anyway — only set if present
	# to avoid the warning spam.
	for b: MarionetteBone in _bones:
		b.linear_damp = body_damp
		b.angular_damp = body_damp
		for axis: String in JOINT_AXES:
			b.set("joint_constraints/%s/angular_spring_enabled" % axis, spring_on)
			b.set("joint_constraints/%s/angular_spring_stiffness" % axis, k)
			b.set("joint_constraints/%s/angular_spring_damping" % axis, c)


# Stops sim, forces every bone back to its skeleton-rest world transform
# with zero velocity (via PhysicsServer3D.body_set_state, the only path
# that survives Jolt's body activation), restarts sim, applies the
# parameter set, then steps physics for SIM_SECONDS measuring max
# velocity and max dispersion. Returns the moment the rig "explodes" (any
# bone past the velocity or dispersion threshold), or SIM_SECONDS if not.
func _run_sweep(params: Dictionary) -> Dictionary:
	# Fresh instance per sweep — see _setup_fresh_instance for rationale.
	await _setup_fresh_instance()
	_apply_anatomical_masses()
	_apply_collisions_on()
	_apply_params(params)
	_apply_gravity_scale(params.get("gravity_scale", 1.0))
	# Let the new state settle into the bodies for one frame before measuring.
	await physics_frame
	# Tethers — captured AFTER the settle frame so anchors track post-mass
	# adjustments. Mirrors the interactive scene's _refresh_tethers.
	_setup_tethers(params.get("regions", []), params.get("tether_omega", 0.0))
	# Optional perturbation: ~0.5s after sim start, kick every bone with a
	# small random impulse. Models the "user grabbed something" event the
	# interactive scene actually sees.
	var perturb: bool = params.get("perturb", false)
	var perturb_step: int = int(0.5 * PHYSICS_RATE) if perturb else -1

	_initial_pos.clear()
	for b: MarionetteBone in _bones:
		_initial_pos[b.bone_name] = b.global_position

	var max_speed: float = 0.0
	var max_dispersion: float = 0.0
	var explosion_step: int = -1
	var max_steps: int = int(SIM_SECONDS * PHYSICS_RATE)
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	# Sustained drag — pull a single bone toward an offset point with a
	# constant force. Models the LMB-drag manipulator's "grab the fingertip
	# and pull" interaction, which is the actual observed instability path.
	var drag_bone_name: String = params.get("drag_bone", "")
	var drag_force_mag: float = params.get("drag_force", 0.0)
	var drag_bone: MarionetteBone = _find_bone_by_name(drag_bone_name) if drag_bone_name != "" else null
	# Pull direction: 30° down-right from the bone's initial position.
	var drag_direction: Vector3 = Vector3(0.5, -0.7, 0.5).normalized()
	for step: int in max_steps:
		# Tether forces every tick — mirrors the interactive scene's
		# `_physics_process` tether loop (force * delta -> impulse).
		for t: Dictionary in _tethers:
			var tb: MarionetteBone = t["bone"]
			if not is_instance_valid(tb):
				continue
			var disp: Vector3 = (t["anchor"] as Vector3) - tb.global_position
			var f: Vector3 = disp * float(t["k"]) - tb.linear_velocity * float(t["c"])
			tb.apply_central_impulse(f * PHYSICS_DT)
		# Sustained drag.
		if drag_bone != null and drag_force_mag > 0.0:
			drag_bone.apply_central_impulse(drag_direction * drag_force_mag * PHYSICS_DT)
		if step == perturb_step:
			# Per-bone random impulse, magnitude from `imp` param. Models
			# the "user grabbed something" event; bigger imp = harder kick.
			var mag: float = params.get("imp", 0.3)
			for b: MarionetteBone in _bones:
				var imp := Vector3(rng.randf_range(-1, 1),
						rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * mag
				b.apply_central_impulse(imp)
		await physics_frame
		for b: MarionetteBone in _bones:
			var v: float = b.linear_velocity.length()
			if v > max_speed:
				max_speed = v
			var d: float = b.global_position.distance_to(_initial_pos[b.bone_name])
			if d > max_dispersion:
				max_dispersion = d
			if explosion_step < 0 and (v > EXPLOSION_VELOCITY or d > EXPLOSION_DISPERSION):
				explosion_step = step
		if explosion_step >= 0:
			break

	var stable_seconds: float = SIM_SECONDS if explosion_step < 0 \
			else float(explosion_step) / PHYSICS_RATE
	return {
		"stable_seconds": stable_seconds,
		"max_speed": max_speed,
		"max_dispersion": max_dispersion,
	}
