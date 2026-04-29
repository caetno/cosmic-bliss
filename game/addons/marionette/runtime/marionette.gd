@tool
class_name Marionette
extends Node3D

# Top-level Marionette node. Owns the data resources (BoneProfile,
# BoneStateProfile, CollisionExclusionProfile), resolves the live Skeleton3D,
# and builds/tears down the physical ragdoll on demand. Phase 5 will also
# host the SPD update path; for now Powered bones are simply dynamic.
#
# Gizmos that read off this node:
#   - MarionetteAuthoringGizmo  — muscle frame + per-bone solver tripods
#   - MarionetteJointLimitGizmo — per-bone ROM arcs in joint-local space
#
# The two inspector tool buttons drive the ragdoll lifecycle in editor:
#   "Build Ragdoll" — creates PhysicalBoneSimulator3D + MarionetteBones
#   "Clear Ragdoll" — removes the simulator (and all bones)
# In editor builds the bones are forced kinematic so they don't drop while
# the user is authoring; runtime callers get the actual configured states.

const _SIMULATOR_NAME: StringName = &"MarionetteSim"

# --- Data resources ---

@export var bone_profile: BoneProfile:
	set(value):
		if bone_profile == value:
			return
		bone_profile = value
		update_gizmos()

@export var bone_state_profile: BoneStateProfile

@export var collision_exclusion_profile: CollisionExclusionProfile

# Translates BoneProfile/SkeletonProfile bone names to the rig's bone names.
# Optional — when null, build_ragdoll falls back to direct name match (which
# works after Godot's import-time retargeting renames bones to canonical
# profile names).
@export var bone_map: BoneMap:
	set(value):
		if bone_map == value:
			return
		bone_map = value
		update_gizmos()

# Path to a sibling/child Skeleton3D.
@export_node_path("Skeleton3D") var skeleton: NodePath:
	set(value):
		if skeleton == value:
			return
		skeleton = value
		update_gizmos()

# Total ragdoll mass. Distributed via BoneEntry.mass_fraction; bones with
# mass_fraction == 0 (the P2.10 default) split the remainder uniformly.
@export_range(0.5, 200.0, 0.1) var total_mass: float = 70.0

# --- Tool buttons (editor authoring) ---

@export_tool_button("Build Ragdoll") var _build_btn: Callable = build_ragdoll
@export_tool_button("Clear Ragdoll") var _clear_btn: Callable = clear_ragdoll

# Hides PhysicalBone3D children in the editor — both their (already-hidden)
# capsule colliders and Godot's built-in 6DOF joint gizmo, which clutters the
# scene at ~80 bones. Default off because the user almost never needs to see
# the physical bones during authoring; the Marionette gizmos (authoring +
# joint-limit) live on the Marionette node itself, which stays visible.
# Setter walks any already-built bones and updates their `visible` live so
# the toggle works without rebuild.
@export var show_physics_bones_in_editor: bool = false:
	set(value):
		if show_physics_bones_in_editor == value:
			return
		show_physics_bones_in_editor = value
		_apply_physics_bone_visibility()
# The BoneProfile inspector's "Generate from Skeleton" button uses the
# *template* reference poses — fine for shipping defaults, but per-rig roll
# differences (ARP for instance) leave joint frames mis-aligned on the live
# skeleton. This button recomputes BoneProfile entries against the actual
# Skeleton3D + BoneMap on this Marionette, so each rig gets its own
# matcher-resolved permutation. Mutates `bone_profile` in place — Ctrl+S
# to persist.
@export_tool_button("Calibrate Profile from Skeleton") var _calibrate_btn: Callable = calibrate_bone_profile_from_skeleton
# Static-analysis diagnostic: per-bone comparison of the BoneEntry-baked
# anatomical frame against the solver's recomputed target frame, both in
# world space. Prints OK/FLIPPED/SWAPPED/BAD per bone so I can pinpoint
# which archetype's solver or matcher is misaligned without test-driving
# every joint by hand.
@export_tool_button("Validate Joint Frames") var _validate_btn: Callable = validate_joint_frames

# Bone names handed to physical_bones_start_simulation(). Populated by
# build_ragdoll() from BoneStateProfile (excludes Kinematic bones + FIXED
# archetypes). Cleared by clear_ragdoll().
var _dynamic_bone_names: Array[StringName] = []

# Pending flag for the deferred gizmo refresh — see request_gizmo_refresh().
var _gizmo_refresh_pending: bool = false


# Schedules a single gizmo refresh for end-of-frame, regardless of how many
# callers requested one. The refresh is a no-op visibility flicker on this
# Marionette node — the only path that reliably drives the editor viewport
# repaint in @tool (Node3D.update_gizmos goes through MessageQueue::push_callable,
# which the editor doesn't flush in time during continuous input — same root
# cause as godotengine/godot#71979). Living on the Marionette (not on
# transient slider widgets) means the deferred call survives widgets being
# freed mid-frame, e.g. when the user deselects the Marionette and the
# muscle-test dock tears down its bone widgets.
func request_gizmo_refresh() -> void:
	if _gizmo_refresh_pending:
		return
	_gizmo_refresh_pending = true
	call_deferred(&"_do_gizmo_refresh")


func _do_gizmo_refresh() -> void:
	_gizmo_refresh_pending = false
	if not visible:
		return
	visible = false
	visible = true


func resolve_skeleton() -> Skeleton3D:
	if skeleton.is_empty():
		return null
	var node: Node = get_node_or_null(skeleton)
	return node as Skeleton3D


# Returns the canonical SkeletonProfile bone name corresponding to a
# Skeleton3D bone name on the live rig. Resolution order:
#   1. BoneMap reverse lookup (rig→profile mapping for the pre-retarget
#      workflow). We use `find_profile_bone_name` rather than the forward
#      `get_skeleton_bone_name` so unmapped names return &"" silently —
#      the forward lookup pushes a console error per missing key.
#   2. Direct name match (post-retarget workflow, where Godot has already
#      renamed source bones to canonical names — leaving BoneMap mappings
#      stale but the skeleton self-describing).
# Returns &"" if no entry exists in the BoneProfile.
func _resolve_profile_name(skel_bone_name: StringName) -> StringName:
	if bone_profile == null:
		return &""
	if bone_map != null:
		var pn: StringName = bone_map.find_profile_bone_name(skel_bone_name)
		if pn != &"" and bone_profile.has_entry(pn):
			return pn
	if bone_profile.has_entry(skel_bone_name):
		return skel_bone_name
	return &""


# Builds a physical ragdoll from the configured profiles. Idempotent: any
# existing simulator is cleared first. Skeleton bones not present in the
# BoneProfile are silently skipped (lets characters add cosmetic bones the
# profile doesn't know about). Bones in `collision_exclusion_profile.disabled_bones`
# are also skipped.
func build_ragdoll() -> void:
	var skel: Skeleton3D = resolve_skeleton()
	if skel == null:
		push_error("Marionette.build_ragdoll: skeleton not resolvable from %s" % skeleton)
		return
	if bone_profile == null:
		push_error("Marionette.build_ragdoll: bone_profile not set")
		return
	if bone_profile.bones.is_empty():
		push_warning("Marionette.build_ragdoll: bone_profile has no entries — run 'Generate from Skeleton' first")
		return

	clear_ragdoll()

	# Default any missing profile so build_ragdoll always has something to read.
	var states: BoneStateProfile = bone_state_profile
	if states == null:
		states = BoneStateProfile.default_for_skeleton_profile(bone_profile.skeleton_profile)
	var exclusions: CollisionExclusionProfile = collision_exclusion_profile
	if exclusions == null:
		exclusions = CollisionExclusionProfile.parent_child_defaults(skel)

	var sim := PhysicalBoneSimulator3D.new()
	sim.name = String(_SIMULATOR_NAME)
	skel.add_child(sim)
	_set_owner_for_editor(sim)

	# Pre-pass: count active bones for uniform mass fallback when entries
	# carry mass_fraction == 0.0 (the P2.10 default).
	var bone_count: int = skel.get_bone_count()
	var active_count: int = 0
	for i in range(bone_count):
		var profile_name: StringName = _resolve_profile_name(skel.get_bone_name(i))
		if profile_name == &"" or exclusions.is_disabled(profile_name):
			continue
		active_count += 1
	var fallback_mass: float = total_mass / max(active_count, 1)

	# Pass 2: build PhysicalBone3Ds. Kinematic vs dynamic is decided by which
	# bones we hand to physical_bones_start_simulation() — there's no per-body
	# kinematic flag on PhysicalBone3D. So we cache the dynamic-bone-name list
	# and stash it on the simulator for start_simulation() to consume.
	var bones_by_skel_index: Dictionary[int, MarionetteBone] = {}
	var dynamic_bone_names: Array[StringName] = []
	for i in range(bone_count):
		var skel_bone_name: StringName = skel.get_bone_name(i)
		var profile_name: StringName = _resolve_profile_name(skel_bone_name)
		if profile_name == &"" or exclusions.is_disabled(profile_name):
			continue
		var entry: BoneEntry = bone_profile.get_entry(profile_name)
		if entry == null:
			continue

		var state: int = states.get_state(profile_name)
		# FIXED archetype trumps profile state — these bones are anatomically
		# rigid and never simulated regardless of what the profile says.
		if entry.archetype == BoneArchetype.Type.FIXED:
			state = BoneStateProfile.State.KINEMATIC

		var bone := _build_bone(skel, i, skel_bone_name, entry, fallback_mass)
		sim.add_child(bone)
		_set_owner_for_editor(bone)
		_apply_joint_constraints(bone, entry)
		bones_by_skel_index[i] = bone
		if state != BoneStateProfile.State.KINEMATIC:
			dynamic_bone_names.append(skel_bone_name)

	_dynamic_bone_names = dynamic_bone_names

	# Pair-wise collision exclusions via PhysicsBody3D.add_collision_exception_with.
	# (PhysicalBoneSimulator3D's older API was a global exception list; pair-wise
	# fits better here.)
	for pair: Vector2i in exclusions.excluded_pairs:
		var a: MarionetteBone = bones_by_skel_index.get(pair.x)
		var b: MarionetteBone = bones_by_skel_index.get(pair.y)
		if a != null and b != null:
			a.add_collision_exception_with(b)

	# Drive editor gizmos from the live skeleton: pose changes (slider drags,
	# animation, IK) emit pose_updated, which queues a gizmo redraw so the ROM
	# arcs / authoring tripods follow the armature instead of frozen at rest.
	# is_connected check keeps repeated build_ragdoll calls idempotent.
	if not skel.pose_updated.is_connected(update_gizmos):
		skel.pose_updated.connect(update_gizmos)


# Tears down any existing PhysicalBoneSimulator3D under the resolved skeleton.
# Safe to call when no ragdoll exists.
func clear_ragdoll() -> void:
	var skel: Skeleton3D = resolve_skeleton()
	if skel == null:
		return
	var existing: Node = skel.get_node_or_null(NodePath(String(_SIMULATOR_NAME)))
	if existing == null:
		# Fall back to scanning children: a hand-renamed simulator still gets cleared.
		for child in skel.get_children():
			if child is PhysicalBoneSimulator3D:
				existing = child
				break
	if existing == null:
		return
	# free() rather than queue_free() so the editor button result is immediate
	# (subsequent build_ragdoll in the same frame doesn't see ghost children).
	existing.get_parent().remove_child(existing)
	existing.free()
	_dynamic_bone_names.clear()


# Starts physics simulation on the dynamic bones (Powered + Unpowered).
# Kinematic bones (Jaw, eyes, FIXED archetypes, anything explicitly marked
# Kinematic in the BoneStateProfile) follow the skeleton instead. Must be
# called after build_ragdoll(). Editor builds typically don't call this;
# it's the runtime entry point.
func start_simulation() -> void:
	var sim: PhysicalBoneSimulator3D = _find_simulator()
	if sim == null:
		push_error("Marionette.start_simulation: no ragdoll built")
		return
	if _dynamic_bone_names.is_empty():
		# Falling back to the no-arg form starts every bone — the user likely
		# wants that if they didn't customize state at build time.
		sim.physical_bones_start_simulation()
	else:
		sim.physical_bones_start_simulation(_dynamic_bone_names)


# Stops simulation; bones revert to kinematic-follows-skeleton.
func stop_simulation() -> void:
	var sim: PhysicalBoneSimulator3D = _find_simulator()
	if sim == null:
		return
	sim.physical_bones_stop_simulation()


# Re-runs the BoneProfile pipeline against this Marionette's live skeleton +
# bone_map, so each bone's permutation reflects the actual rig's rest bases
# (including any per-bone roll baked at modeling time). Use this when the
# template-derived permutations leave the gizmo arcs visibly off-axis on
# your specific character. Calls `bone_profile.emit_changed()` so the editor
# marks the resource dirty; user must Ctrl+S to persist.
func calibrate_bone_profile_from_skeleton() -> void:
	if bone_profile == null:
		push_warning("Marionette.calibrate: bone_profile not set")
		return
	if bone_profile.skeleton_profile == null:
		push_warning("Marionette.calibrate: bone_profile.skeleton_profile not set")
		return
	var skel: Skeleton3D = resolve_skeleton()
	if skel == null:
		push_warning("Marionette.calibrate: skeleton not resolvable from %s" % skeleton)
		return
	if bone_map == null:
		push_warning("Marionette.calibrate: bone_map not set — can't translate rig names")
		return
	var path: String = bone_profile.resource_path if bone_profile.resource_path != "" else "<unsaved>"
	print("[Marionette] calibrating %s against live skeleton — per-bone log:" % path)
	var report: BoneProfileGenerator.GenerateReport = BoneProfileGenerator.generate(
			bone_profile, skel, bone_map, true)
	if report.error != "":
		push_warning("Marionette.calibrate: %s" % report.error)
		return
	bone_profile.emit_changed()
	# Auto-persist the calibrated profile to disk. Without this, a project
	# reload reverts the bones dict to whatever was last manually Ctrl+S'd —
	# the preserved 6 template-only bones get dropped on reload because the
	# saved file still has the pre-calibrate state. Skip when the resource
	# is built-in (no path) — that's a profile embedded in a scene, which
	# saves with the scene.
	if bone_profile.resource_path != "":
		# Default flags only. FLAG_BUNDLE_RESOURCES bundles the *script* sources
		# (BoneEntry, BoneProfile) directly into the .tres as GDScript
		# sub-resources, which then conflict with the registered global
		# class_names — Godot rejects the loaded .tres as plain Resource and
		# `var bp: BoneProfile = ...` typed assignments fail.
		var save_err: int = ResourceSaver.save(
				bone_profile, bone_profile.resource_path)
		if save_err != OK:
			push_warning("Marionette.calibrate: ResourceSaver returned %d for %s" % [save_err, path])
		else:
			# Verify by reloading from disk — the previous "wrote OK" message
			# was misleading because it returned OK while persisting only 78
			# of 84 entries. Print the on-disk count so regressions surface.
			var reloaded: Resource = ResourceLoader.load(
					bone_profile.resource_path, "BoneProfile",
					ResourceLoader.CACHE_MODE_REPLACE)
			var on_disk_count: int = -1
			if reloaded is BoneProfile:
				on_disk_count = (reloaded as BoneProfile).bones.size()
			print("[Marionette]   wrote %s (in-memory=%d, on-disk=%d)" %
					[path, bone_profile.bones.size(), on_disk_count])
	if report.preserved > 0:
		print("[Marionette]   preserved (in profile but not in rig): %s" % [report.preserved_bones])
	if report.unmatched > 0:
		print("[Marionette]   fallback bones (rig roll outside ±31° tolerance — calculated frame baked instead): %s" % [report.unmatched_bones])
	update_gizmos()


func validate_joint_frames() -> void:
	if bone_profile == null:
		push_warning("Marionette.validate_joint_frames: bone_profile not set")
		return
	if bone_profile.skeleton_profile == null:
		push_warning("Marionette.validate_joint_frames: bone_profile.skeleton_profile not set")
		return
	# Live-skeleton path when available; falls through to template otherwise.
	# Live is what the user actually sees — the diagnostic should match.
	var skel: Skeleton3D = resolve_skeleton()
	var bm: BoneMap = bone_map
	var path: String = bone_profile.resource_path if bone_profile.resource_path != "" else "<unsaved>"
	var source_label: String = "live skeleton" if (skel != null and bm != null) else "template reference poses"
	print("[Marionette] validating %s against %s — per-bone log:" % [path, source_label])
	var report: MarionetteFrameValidator.ValidationReport = MarionetteFrameValidator.validate(bone_profile, skel, bm)
	if report.error != "":
		push_warning("Marionette.validate_joint_frames: %s" % report.error)
		return
	for d: MarionetteFrameValidator.BoneDiagnosis in report.diagnoses:
		print(d.format_line())
	print("[Marionette] frames: ok=%d weak=%d flipped=%d swapped=%d bad=%d skipped=%d (total %d)"
			% [report.ok_count, report.weak_count, report.flipped_count,
				report.swapped_count, report.bad_count, report.skipped_count,
				report.diagnoses.size()])
	if report.flipped_count > 0:
		print("[Marionette]   FLIPPED bones: %s" % [report.by_status("FLIPPED")])
	if report.swapped_count > 0:
		print("[Marionette]   SWAPPED bones: %s" % [report.by_status("SWAPPED")])
	if report.bad_count > 0:
		print("[Marionette]   BAD bones: %s" % [report.by_status("BAD")])

	# Dynamic motion test — independent check against the solver. This is
	# what catches cases where the static frame matches the solver target but
	# the solver target itself is wrong (e.g., wrong axis chosen, sign flipped
	# in the solver). Output is per-bone flex motion direction vs. archetype-
	# expected anatomical direction.
	print("[Marionette] motion direction check (flex axis × bone-to-child):")
	var motion_report: MarionetteFrameValidator.MotionReport = MarionetteFrameValidator.validate_motion(bone_profile, skel, bm)
	for md: MarionetteFrameValidator.MotionDiagnosis in motion_report.diagnoses:
		print(md.format_line())
	print("[Marionette] motion: ok=%d weak=%d wrong=%d skipped=%d (total %d)" % [
			motion_report.ok_count, motion_report.weak_count,
			motion_report.wrong_count, motion_report.skipped_count,
			motion_report.diagnoses.size()])
	if motion_report.wrong_count > 0:
		print("[Marionette]   WRONG-motion bones (solver bug suspect): %s" % [motion_report.by_status("WRONG")])


func _find_simulator() -> PhysicalBoneSimulator3D:
	var skel: Skeleton3D = resolve_skeleton()
	if skel == null:
		return null
	var sim: Node = skel.get_node_or_null(NodePath(String(_SIMULATOR_NAME)))
	if sim is PhysicalBoneSimulator3D:
		return sim
	for child: Node in skel.get_children():
		if child is PhysicalBoneSimulator3D:
			return child
	return null


# --- internals ---

func _build_bone(
		skel: Skeleton3D,
		skel_index: int,
		skel_bone_name: StringName,
		entry: BoneEntry,
		fallback_mass: float) -> MarionetteBone:
	var bone := MarionetteBone.new()
	bone.name = String(skel_bone_name)
	bone.bone_name = String(skel_bone_name)
	bone.bone_entry = entry
	bone.joint_type = PhysicalBone3D.JOINT_TYPE_6DOF

	# Bake the anatomical frame into joint_rotation. Post-bake, the joint's
	# local +X is literally the flex axis (CLAUDE.md §3). Default path is the
	# signed-axis permutation; bones that fell back to a calculated frame at
	# generate-time (use_calculated_frame=true) bake the non-axis-aligned
	# basis instead, so non-T-pose rigs work without re-export.
	bone.joint_rotation = entry.anatomical_basis_in_bone_local().get_euler()

	# Capsule sized to bone length, oriented along bone-local +Y (the ARP /
	# Blender convention; Godot's CapsuleShape3D defaults to local Y).
	var bone_length: float = _bone_length(skel, skel_index)
	var capsule := CapsuleShape3D.new()
	capsule.radius = max(bone_length * 0.18, 0.02)
	# Capsule height = full extent including hemispherical caps; subtract a
	# bit so adjacent bones' capsules don't perma-overlap at joint origins.
	capsule.height = max(bone_length * 0.9, 2.0 * capsule.radius + 0.01)
	var collider := CollisionShape3D.new()
	collider.shape = capsule
	collider.position = Vector3(0.0, bone_length * 0.5, 0.0)
	# Hide the editor wireframe by default — at ~80 capsules the stack is
	# unreadable. Visibility is purely cosmetic; physics uses the shape RID.
	# Toggle on per-bone in the inspector to inspect individual colliders.
	collider.visible = false
	bone.add_child(collider)

	# Mass: per-bone fraction if authored; else the uniform fallback.
	bone.mass = bone_profile.total_mass * entry.mass_fraction if entry.mass_fraction > 0.0 else fallback_mass

	# Default to invisible in the editor so the 6DOF joint gizmo and capsule
	# don't clutter the viewport (~80 bones at once is unreadable). The user
	# can flip Marionette.show_physics_bones_in_editor to inspect.
	bone.visible = show_physics_bones_in_editor

	return bone


# Walks the active simulator's MarionetteBone children and pushes the current
# `show_physics_bones_in_editor` value into their `visible` flag. Called from
# the export's setter so the toggle works without a rebuild.
func _apply_physics_bone_visibility() -> void:
	var sim: PhysicalBoneSimulator3D = _find_simulator()
	if sim == null:
		return
	for child in sim.get_children():
		if child is MarionetteBone:
			(child as MarionetteBone).visible = show_physics_bones_in_editor


# Sets dynamic 6DOF joint properties. Splitting this out keeps _build_bone
# focused on per-bone shape + state and the joint-baking logic isolated.
#
# Godot 4.6 PhysicalBone3D 6DOF property paths use the form
# `joint_constraints/<axis>/<limit_kind>_<bound>` — verified empirically via
# get_property_list().
static func _apply_joint_constraints(bone: MarionetteBone, entry: BoneEntry) -> void:
	# Anatomical ROM. Joint-axis map (post joint_rotation bake): x=flex,
	# y=medial rotation, z=abduction.
	var anatomical_min: Vector3 = entry.rom_min
	var anatomical_max: Vector3 = entry.rom_max
	for i: int in range(3):
		var axis: String = ["x", "y", "z"][i]
		var lower: float = anatomical_min[i]
		var upper: float = anatomical_max[i]
		# Mirror the abduction limits when the basis chirality flipped that
		# axis (see BoneEntry.mirror_abd). Negate AND swap so the joint
		# permits the anatomically-positive direction even though the joint-
		# local +Z rotation produces motion in the anti-anatomical direction.
		if i == 2 and entry.mirror_abd:
			var temp: float = lower
			lower = -upper
			upper = -temp
		bone.set("joint_constraints/%s/angular_limit_enabled" % axis, true)
		bone.set("joint_constraints/%s/angular_limit_lower" % axis, lower)
		bone.set("joint_constraints/%s/angular_limit_upper" % axis, upper)
		# Lock linear motion across the joint — bones articulate, they don't slide.
		bone.set("joint_constraints/%s/linear_limit_enabled" % axis, true)
		bone.set("joint_constraints/%s/linear_limit_lower" % axis, 0.0)
		bone.set("joint_constraints/%s/linear_limit_upper" % axis, 0.0)


# Bone length = distance to first listed child bone in the skeleton, else a
# small floor so terminal bones still get a visible collider.
static func _bone_length(skel: Skeleton3D, skel_index: int) -> float:
	var bone_world: Transform3D = skel.get_bone_global_rest(skel_index)
	var n: int = skel.get_bone_count()
	for j in range(n):
		if skel.get_bone_parent(j) == skel_index:
			var child_world: Transform3D = skel.get_bone_global_rest(j)
			var d: float = (child_world.origin - bone_world.origin).length()
			if d > 0.001:
				return d
			break
	return 0.05


func _set_owner_for_editor(node: Node) -> void:
	if not Engine.is_editor_hint():
		return
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	var edited_root: Node = tree.edited_scene_root
	if edited_root != null and is_ancestor_of_or_equal(edited_root, self):
		node.owner = edited_root


# True if `ancestor` equals `self` or is an ancestor of `self` in the scene tree.
# Used to gate owner-assignment so we don't pollute scenes the user isn't editing.
static func is_ancestor_of_or_equal(ancestor: Node, descendant: Node) -> bool:
	var n: Node = descendant
	while n != null:
		if n == ancestor:
			return true
		n = n.get_parent()
	return false
