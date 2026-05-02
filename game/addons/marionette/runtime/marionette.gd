@tool
class_name Marionette
extends Node3D

## Top-level Marionette node. Owns the data resources (BoneProfile,
## BoneStateProfile, CollisionExclusionProfile, BoneCollisionProfile,
## JiggleProfile), resolves the live Skeleton3D, and builds / tears down
## the physical ragdoll on demand.
##
## Inspector layout (slice 5):
##   1 Bind            — skeleton, bone_map, collision_source_mesh
##   2 Anatomy         — bone_profile, total_mass, muscle_frame_forward
##   3 Collision Shapes — bone_collision_profile, hull build buttons
##   4 Build           — state / exclusion / jiggle profiles, Build / Clear
##   5 Tune & Test     — per-region spring/jiggle tuning widget
##
## Gizmos that read off this node:
##   * MarionetteAuthoringGizmo  — muscle frame + per-bone solver tripods
##   * MarionetteJointLimitGizmo — per-bone ROM arcs in joint-local space
##
## Convex-hull / capsule wireframes render via permanent MeshInstance3D
## children of each bone (see _attach_collision_overlay) — bypasses the
## gizmo system's MessageQueue-deferred redraw, so wireframes refresh on
## every editor frame without viewport input.

const _SIMULATOR_NAME: StringName = &"MarionetteSim"

# Inspector layout: properties + tool buttons grouped into five sections by
# user task (Bind, Anatomy, Collision Shapes, Build, Tune & Test). Order
# below = display order in the inspector. Slice 5.

# --- 1. Bind ---------------------------------------------------------------
# What rig is this Marionette attached to?

@export_group("Bind")

## Path to a sibling/child Skeleton3D — the rig this Marionette drives.
@export_node_path("Skeleton3D") var skeleton: NodePath:
	set(value):
		if skeleton == value:
			return
		skeleton = value
		update_gizmos()

## Translates BoneProfile / SkeletonProfile bone names to the rig's
## actual bone names. Optional — when null, build_ragdoll falls back to
## direct name match (which works after Godot's import-time retargeting
## renames bones to canonical profile names).
@export var bone_map: BoneMap:
	set(value):
		if bone_map == value:
			return
		bone_map = value
		update_gizmos()

## Optional source for "Build Convex Colliders". When empty, the build
## auto-discovers every skinned MeshInstance3D under the skeleton's
## parent. Point at a specific node when auto-discovery picks up extra
## accessory meshes that shouldn't contribute to the body hulls.
@export_node_path("Node3D") var collision_source_mesh: NodePath


# --- 2. Anatomy -----------------------------------------------------------
# Per-character anatomical authoring data — joint axes, ROM, mass, springs.

@export_group("Anatomy")

## Per-character anatomical authoring data — joint axes, ROM, mass,
## springs. Populated by "Calibrate Profile from Skeleton".
@export var bone_profile: BoneProfile:
	set(value):
		if bone_profile == value:
			return
		bone_profile = value
		update_gizmos()

## Total ragdoll mass in kg. Distributed via BoneEntry.mass_fraction;
## bones with mass_fraction = 0 split the remainder uniformly. Single
## source of truth — bones inherit, jiggle bones derive their own mass
## from hull volume.
@export_range(0.5, 200.0, 0.1) var total_mass: float = 70.0

## Override for the muscle frame's forward axis at Calibrate time.
## Default Vector3.ZERO autodetects via the foot-bone probe; set to
## e.g. Vector3(0, 0, 1) when autodetect picks the wrong side. Ignored
## at runtime.
@export var muscle_frame_forward_override: Vector3 = Vector3.ZERO

@export_tool_button("Calibrate Profile from Skeleton", "Tools") var _calibrate_btn: Callable = calibrate_bone_profile_from_skeleton

@export_tool_button("Validate Joint Frames", "Reload") var _validate_btn: Callable = validate_joint_frames


# --- 3. Collision Shapes --------------------------------------------------
# Convex hulls harvested from the skinned mesh + soft-region opt-outs.

@export_group("Collision Shapes")

## Per-character convex-hull collider data. When set, build_ragdoll
## uses the stored hulls instead of per-bone capsules for any bone that
## has a hull entry; bones missing from the profile fall back to capsule.
## Setter rebuilds colliders on a live simulator so swapping the
## resource takes effect immediately.
@export var bone_collision_profile: BoneCollisionProfile:
	set(value):
		if bone_collision_profile == value:
			return
		bone_collision_profile = value
		if _find_simulator() != null:
			_rebuild_colliders_on_live_simulator()

@export_tool_button("Build Convex Colliders", "MeshInstance3D") var _build_colliders_btn: Callable = build_convex_colliders

@export_tool_button("Revert to Capsules", "Reload") var _revert_colliders_btn: Callable = revert_to_capsules


# --- 4. Build -------------------------------------------------------------
# State / exclusion / soft-region resources + the Build/Clear actions.

@export_group("Build")

## Per-bone Kinematic / Powered / Unpowered state. Swappable at runtime
## for injury / shock states. Null falls back to defaults
## (everything Powered except jaw + eyes Kinematic).
@export var bone_state_profile: BoneStateProfile

## Bone-pair collision exclusions. Null falls back to parent-child
## defaults derived from the skeleton hierarchy.
@export var collision_exclusion_profile: CollisionExclusionProfile

## Per-character soft-tissue tuning. Optional; when set, JiggleBones
## spawned at Build Ragdoll get reach / damping_ratio from this profile.
## Bones in BoneCollisionProfile.non_cascade_bones but missing here use
## the profile's default_reach_seconds / default_damping_ratio. Null
## profile uses hardcoded code defaults (0.3 / 0.7).
@export var jiggle_profile: JiggleProfile

@export_tool_button("Build Ragdoll", "Skeleton3D") var _build_btn: Callable = build_ragdoll
@export_tool_button("Clear Ragdoll", "Remove") var _clear_btn: Callable = clear_ragdoll

## Show PhysicalBone3D children in the editor (capsule wireframes + the
## built-in 6DOF joint gizmo). Off by default because ~80 bones is
## cluttery. Toggling rewrites visibility on already-built bones — no
## rebuild needed.
@export var show_physics_bones_in_editor: bool = false:
	set(value):
		if show_physics_bones_in_editor == value:
			return
		show_physics_bones_in_editor = value
		_apply_physics_bone_visibility()

## Show convex-hull / capsule wireframes alongside each bone, drawn via
## permanent MeshInstance3D children of the bones (not the gizmo
## system). Updates immediately on Build Ragdoll / Calibrate / profile
## swap — no viewport-input dependency. Toggling rewrites visibility on
## already-built overlays — no rebuild needed.
@export var show_collision_overlay: bool = true:
	set(value):
		if show_collision_overlay == value:
			return
		show_collision_overlay = value
		_apply_collision_overlay_visibility()


# --- 5. Tune & Test -------------------------------------------------------
# Per-region jiggle / spring tuning + per-region simulation control.
# The widget that drives this section is hosted by MarionetteInspectorPlugin
# (slice 7) and writes back to BoneProfile.bones[…].spring_stiffness/damping
# and JiggleProfile.entries[…] on user input.

@export_group("Tune & Test")

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


## Builds a physical ragdoll from the configured profiles. Spawns a
## PhysicalBoneSimulator3D + one MarionetteBone per BoneProfile entry +
## one JiggleBone per BoneCollisionProfile.non_cascade_bones entry.
##
## Idempotent — any existing simulator is cleared first. Skeleton bones
## not in the BoneProfile are silently skipped (cosmetic bones survive).
## Bones in collision_exclusion_profile.disabled_bones are also skipped.
##
## Spawned bones get owner-set to the scene root so they bake into the
## .tscn on Save (slice 6).
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
		# Collider added as a separate child so the owner can be set after
		# the bone is parented. Both shape kinds (capsule fallback +
		# convex hull) get owner-set so they bake into the .tscn. ~60 KB
		# of hull-point data per kasumi-class scene; accepted in slice 6
		# in exchange for "Build = persist" instead of runtime self-heal.
		var collider: CollisionShape3D = _build_collider_for_bone(bone, skel, i)
		bone.add_child(collider)
		_set_owner_for_editor(collider)
		_attach_collision_overlay(bone, collider)
		_apply_joint_constraints(bone, entry)
		bones_by_skel_index[i] = bone
		if state != BoneStateProfile.State.KINEMATIC:
			dynamic_bone_names.append(skel_bone_name)

	# Pass 3: soft-region jiggle bones. Iterate the BoneCollisionProfile's
	# non-cascade list and spawn a JiggleBone for any entry whose hull is
	# present and whose skeleton bone exists. CLAUDE.md §15. Each jiggle
	# bone goes into the dynamic list (spring physics drives translation)
	# but its rotation is joint-locked so the host's pose orientation is
	# preserved.
	if bone_collision_profile != null:
		for jiggle_name: StringName in bone_collision_profile.non_cascade_bones:
			var skel_idx: int = skel.find_bone(jiggle_name)
			if skel_idx < 0:
				push_warning("Marionette.build_ragdoll: jiggle bone '%s' not in skeleton — skipped" % jiggle_name)
				continue
			if not bone_collision_profile.has_hull(jiggle_name):
				push_warning("Marionette.build_ragdoll: jiggle bone '%s' has no hull in profile — skipped" % jiggle_name)
				continue
			var host_idx: int = skel.get_bone_parent(skel_idx)
			var host_name: StringName = StringName(skel.get_bone_name(host_idx)) if host_idx >= 0 else &""
			var jb := _build_jiggle_bone(skel, skel_idx, jiggle_name, host_name)
			sim.add_child(jb)
			_set_owner_for_editor(jb)
			var collider: CollisionShape3D = _build_collider_for_bone(jb, skel, skel_idx)
			jb.add_child(collider)
			_set_owner_for_editor(collider)
			_attach_collision_overlay(jb, collider)
			# Cache skel + indices on the bone so _integrate_forces avoids
			# string lookups per tick. Host idx ≥ 0 is guaranteed for any
			# bone with a parent; jiggle bones at the root would be weird
			# but the spring just no-ops in that case.
			if host_idx >= 0:
				jb.configure_spring(skel, host_idx, skel.get_bone_rest(skel_idx))
			# Dynamic so the simulator runs _integrate_forces. Without this
			# the bone would track the skeleton kinematically and the spring
			# code would never execute.
			dynamic_bone_names.append(jiggle_name)

	_dynamic_bone_names = dynamic_bone_names

	# Collision exclusions are intentionally NOT applied here. add_collision_exception_with
	# writes runtime-only state on PhysicsBody3D (no serializable property exposes it),
	# so any call here would be lost on scene save. start_simulation() re-applies the
	# full exclusion set every time it's called, which covers both editor preview and
	# play-mode runs without scene-save coupling.

	# Drive editor gizmos from the live skeleton: pose changes (slider drags,
	# animation, IK) emit pose_updated, which queues a gizmo redraw so the ROM
	# arcs / authoring tripods follow the armature instead of frozen at rest.
	# is_connected check keeps repeated build_ragdoll calls idempotent.
	if not skel.pose_updated.is_connected(update_gizmos):
		skel.pose_updated.connect(update_gizmos)

	# Force an immediate gizmo refresh: the collider gizmo enumerates the
	# simulator's children at _redraw time, and without an explicit kick the
	# editor doesn't re-fire _redraw for purely structural changes (new
	# child nodes). Without this, the user has to deselect-and-reselect
	# the Marionette to see hulls appear after Build Ragdoll.
	update_gizmos()
	request_gizmo_refresh()


## Tears down the active PhysicalBoneSimulator3D under the skeleton.
## Safe to call when no ragdoll exists. Used by Build's idempotency
## (Build calls Clear first) and the "Clear Ragdoll" tool button.
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


## Starts physics simulation on the dynamic bones (Powered + Unpowered
## + every JiggleBone). Kinematic bones (Jaw, eyes, FIXED archetypes,
## anything explicitly Kinematic in the BoneStateProfile) follow the
## skeleton instead. Must be called after build_ragdoll. Editor builds
## typically don't call this — it's the gameplay-runtime entry point.
func start_simulation() -> void:
	var sim: PhysicalBoneSimulator3D = _find_simulator()
	if sim == null:
		push_error("Marionette.start_simulation: no ragdoll built")
		return
	var skel: Skeleton3D = resolve_skeleton()
	if skel == null:
		push_error("Marionette.start_simulation: skeleton not resolvable from %s" % skeleton)
		return
	# Apply collision exception pairs at sim start. add_collision_exception_with
	# writes runtime-only state on PhysicsBody3D (not serializable), so it
	# can't be baked into the scene like the colliders are — must run on
	# every start. Idempotent: repeat calls add the same pairs without
	# effect.
	_apply_collision_exclusions(sim, skel)

	# Pick which bones go dynamic. `_dynamic_bone_names` is populated by
	# build_ragdoll but lives in @tool memory only — it's empty after a
	# scene reload, even though the simulator hierarchy is intact. In that
	# case, derive the list from each bone's BoneEntry archetype + the active
	# BoneStateProfile so FIXED (jaw/eyes) and KINEMATIC bones stay still
	# instead of becoming dynamic when the user hits play.
	var dynamic: Array[StringName] = _dynamic_bone_names
	if dynamic.is_empty():
		dynamic = _derive_dynamic_bone_names(sim)
	if dynamic.is_empty():
		sim.physical_bones_start_simulation()
	else:
		sim.physical_bones_start_simulation(dynamic)


# True if the bone has a usable hull in the active `bone_collision_profile`.
# Resolves the bone's skeleton name to a profile key the same way
# build_ragdoll does (BoneMap reverse, then direct), so the same name
# convention works in both directions.
func _profile_has_hull_for_bone(bone: PhysicalBone3D) -> bool:
	if bone_collision_profile == null:
		return false
	var skel_bone_name: StringName = StringName(bone.bone_name)
	var profile_name: StringName = _resolve_profile_name(skel_bone_name)
	if profile_name != &"" and bone_collision_profile.has_hull(profile_name):
		return true
	return bone_collision_profile.has_hull(skel_bone_name)


# Re-applies the configured CollisionExclusionProfile (or parent-child
# defaults if none is set) at runtime. add_collision_exception_with is
# runtime-only state on PhysicsBody3D, so this must run every time
# simulation starts. Idempotent — repeat calls add the same exception
# pairs without effect.
func _apply_collision_exclusions(sim: PhysicalBoneSimulator3D, skel: Skeleton3D) -> void:
	var exclusions: CollisionExclusionProfile = collision_exclusion_profile
	if exclusions == null:
		exclusions = CollisionExclusionProfile.parent_child_defaults(skel)
	# Index every simulator-managed bone by skeleton bone index so we can
	# resolve the profile's Vector2i pairs in one pass. Both MarionetteBone
	# and JiggleBone participate — jiggle hulls touch their UpperChest host's
	# hull and would fight without an explicit exception (auto_exclusions
	# already covers the breast↔chest pair via AABB overlap at build time).
	var by_skel_index: Dictionary[int, PhysicalBone3D] = {}
	for child: Node in sim.get_children():
		if child is MarionetteBone or child is JiggleBone:
			var idx: int = skel.find_bone((child as PhysicalBone3D).bone_name)
			if idx >= 0:
				by_skel_index[idx] = child
	# Profile-driven pairs first.
	for pair: Vector2i in exclusions.excluded_pairs:
		var a: PhysicalBone3D = by_skel_index.get(pair.x)
		var b: PhysicalBone3D = by_skel_index.get(pair.y)
		if a != null and b != null:
			a.add_collision_exception_with(b)
	# Hull-overlap pairs from BoneCollisionProfile (Vector2i indices into
	# the same Skeleton3D, written by ColliderBuilder.compute_overlap_pairs
	# at build time). Convex hulls overlap more aggressively than the
	# default capsules at joints — without these, neighboring hulls fight
	# at the bind seams and the chain explodes.
	if bone_collision_profile != null:
		for pair: Vector2i in bone_collision_profile.auto_exclusions:
			var a_h: PhysicalBone3D = by_skel_index.get(pair.x)
			var b_h: PhysicalBone3D = by_skel_index.get(pair.y)
			if a_h != null and b_h != null:
				a_h.add_collision_exception_with(b_h)
	# Always-applied digit-sibling pairs. Adjacent fingers / toes touch
	# when the hand or foot closes, and without these pairs the per-phalanx
	# capsules push apart and freeze the digit chain. Cheap (~100 pairs
	# total) and never wrong for a humanoid rig — there is no use case for
	# leaving them out, so this isn't a profile flag.
	for pair: Vector2i in CollisionExclusionProfile.digit_sibling_exclusions(skel):
		var a: PhysicalBone3D = by_skel_index.get(pair.x)
		var b: PhysicalBone3D = by_skel_index.get(pair.y)
		if a != null and b != null:
			a.add_collision_exception_with(b)


# Mirrors the dynamic/kinematic split logic from `build_ragdoll` so a
# freshly-loaded scene gets the same simulation membership without needing
# the cached list.
func _derive_dynamic_bone_names(sim: PhysicalBoneSimulator3D) -> Array[StringName]:
	var states: BoneStateProfile = bone_state_profile
	if states == null and bone_profile != null:
		states = BoneStateProfile.default_for_skeleton_profile(bone_profile.skeleton_profile)
	var dynamic: Array[StringName] = []
	for child: Node in sim.get_children():
		# JiggleBones are always dynamic — their spring physics is the only
		# motion they have. No state lookup, no archetype check.
		if child is JiggleBone:
			dynamic.append(StringName((child as JiggleBone).bone_name))
			continue
		if not (child is MarionetteBone):
			continue
		var bone: MarionetteBone = child
		if bone.bone_entry == null:
			continue
		if bone.bone_entry.archetype == BoneArchetype.Type.FIXED:
			continue
		if states != null:
			var profile_name: StringName = _resolve_profile_name(StringName(bone.bone_name))
			if profile_name != &"" and states.get_state(profile_name) == BoneStateProfile.State.KINEMATIC:
				continue
		dynamic.append(StringName(bone.bone_name))
	return dynamic


## Stops simulation; bones revert to kinematic-follows-skeleton until
## start_simulation is called again.
func stop_simulation() -> void:
	var sim: PhysicalBoneSimulator3D = _find_simulator()
	if sim == null:
		return
	sim.physical_bones_stop_simulation()


## Re-runs the BoneProfile pipeline against this Marionette's live
## skeleton + bone_map. Each bone's permutation, ROM, mass-fraction,
## and spring defaults are regenerated; user-tuned spring values are
## preserved (per-axis non-zeros survive). Use when per-rig roll
## differences leave joint frames mis-aligned on the live skeleton.
## Mutates `bone_profile` in place — Ctrl+S to persist.
func calibrate_bone_profile_from_skeleton() -> void:
	_calibrate_with_method(BoneProfileGenerator.Method.ARCHETYPE)


func calibrate_bone_profile_from_skeleton_tpose() -> void:
	_calibrate_with_method(BoneProfileGenerator.Method.TPOSE)


# Shared body of both calibrate buttons. Only the target_basis derivation
# differs between methods; everything else (validation, save, post-report
# logging, gizmo refresh) is identical.
func _calibrate_with_method(method: BoneProfileGenerator.Method) -> void:
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
	var method_label: String = "archetype" if method == BoneProfileGenerator.Method.ARCHETYPE else "t-pose"
	print("[Marionette] calibrating %s against live skeleton (method=%s) — per-bone log:" % [path, method_label])
	var report: BoneProfileGenerator.GenerateReport = BoneProfileGenerator.generate_with_method(
			bone_profile, method, skel, bone_map, true, muscle_frame_forward_override)
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
	# `BoneProfileGenerator.generate_with_method` deep-duplicates each
	# preserved BoneEntry into a fresh dict (so ResourceSaver doesn't drop
	# them on save), which orphans every reference any already-built
	# MarionetteBone is holding via `bone.bone_entry`. The muscle-test
	# slider widgets read `_bone.bone_entry` per pose-apply, so without
	# this refresh they'd keep rotating around the pre-calibrate axes
	# while the gizmos (which read `bone_profile.bones[name]` afresh
	# each redraw) jump to the new ones — the exact split caused by
	# Calibrate-after-Build-Ragdoll. Re-bake joint_rotation/limits too
	# in case physics is exercised before a rebuild.
	_refresh_marionette_bones_after_calibrate()
	update_gizmos()


# Walks every MarionetteBone under the simulator and re-points its
# `bone_entry` at the freshly-calibrated entry in `bone_profile.bones`.
# Also re-bakes `joint_rotation` and joint limits from the new entry so a
# rebuilt ragdoll isn't required for physics correctness either.
func _refresh_marionette_bones_after_calibrate() -> void:
	var sim: PhysicalBoneSimulator3D = _find_simulator()
	if sim == null:
		return
	for child: Node in sim.get_children():
		if not (child is MarionetteBone):
			continue
		var mb: MarionetteBone = child as MarionetteBone
		var bone_name := StringName(mb.bone_name)
		if not bone_profile.bones.has(bone_name):
			continue
		var fresh: BoneEntry = bone_profile.bones[bone_name]
		if fresh == null:
			continue
		mb.bone_entry = fresh
		mb.joint_rotation = fresh.anatomical_basis_in_bone_local().get_euler()
		_apply_joint_constraints(mb, fresh)
		# Refresh mass too — Calibrate may have updated mass_fraction
		# (e.g. seeding anatomical defaults via MarionetteMassDefaults).
		# Without this, live bones stay at their build-time mass while
		# the profile says otherwise — visible as stale per-bone weights.
		var fallback_mass: float = total_mass / max(sim.get_child_count(), 1)
		mb.mass = total_mass * fresh.mass_fraction if fresh.mass_fraction > 0.0 else fallback_mass


## Per-bone diagnostic comparing the BoneEntry-baked anatomical frame
## against the solver's recomputed target frame in world space. Prints
## OK / FLIPPED / SWAPPED / BAD per bone so misaligned archetypes /
## matcher results can be pinpointed without test-driving every joint
## by hand. Read-only — does not mutate the profile.
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

	# Mass: per-bone fraction if authored; else the uniform fallback.
	# Total ragdoll mass lives on this Marionette node (single source — the
	# old BoneProfile.total_mass duplicate was removed in slice 5).
	bone.mass = total_mass * entry.mass_fraction if entry.mass_fraction > 0.0 else fallback_mass

	# Default to invisible in the editor so the 6DOF joint gizmo and capsule
	# don't clutter the viewport (~80 bones at once is unreadable). The user
	# can flip Marionette.show_physics_bones_in_editor to inspect.
	bone.visible = show_physics_bones_in_editor

	return bone


# Soft-region jiggle body. Distinct from `_build_bone`: no anatomical
# basis bake (jiggle bones don't carry a BoneEntry), all 3 angular axes
# locked at 0 (rotation follows the host), and a small linear excursion
# budget on each axis. Mass derived from the hull AABB volume × tissue
# density (~1000 kg/m³, water-equivalent for soft tissue) so the spring
# physics that lands later has a sane starting point. CLAUDE.md §15.
func _build_jiggle_bone(
		skel: Skeleton3D,
		skel_index: int,
		skel_bone_name: StringName,
		host_bone_name: StringName) -> JiggleBone:
	var bone := JiggleBone.new()
	bone.name = String(skel_bone_name)
	bone.bone_name = String(skel_bone_name)
	bone.host_bone_name = host_bone_name
	bone.joint_type = PhysicalBone3D.JOINT_TYPE_6DOF

	# Rotation locked: lower=upper=0 on every axis. The body inherits the
	# host bone's orientation; jiggle is translation-only.
	for i: int in range(3):
		var axis: String = ["x", "y", "z"][i]
		bone.set("joint_constraints/%s/angular_limit_enabled" % axis, true)
		bone.set("joint_constraints/%s/angular_limit_lower" % axis, 0.0)
		bone.set("joint_constraints/%s/angular_limit_upper" % axis, 0.0)
		# Translation budget — wide enough that the SPD spring can swing
		# without immediately hitting the hard limit, narrow enough that
		# nothing wanders away from the host on a stiffness underflow.
		bone.set("joint_constraints/%s/linear_limit_enabled" % axis, true)
		bone.set("joint_constraints/%s/linear_limit_lower" % axis, -0.05)
		bone.set("joint_constraints/%s/linear_limit_upper" % axis, 0.05)

	bone.mass = _estimate_jiggle_mass(skel_bone_name)
	# Spring tuning: per-bone JiggleEntry > profile defaults > code defaults.
	# Mass-portable SPD math so a 5 kg breast and a 0.5 kg jowl share the
	# same feel for the same reach/damping params:
	#   omega = 2π / reach_seconds
	#   k     = m · omega²
	#   c     = 2 · ζ · ω · m         (ζ = damping ratio)
	var params: Vector2 = _resolve_jiggle_params(skel_bone_name)
	var reach_seconds: float = params.x
	var damping_ratio: float = params.y
	var omega: float = TAU / max(reach_seconds, 0.001)
	bone.stiffness = bone.mass * omega * omega
	bone.damping = 2.0 * damping_ratio * omega * bone.mass
	# Custom integrator so the spring's apply_central_force takes effect.
	# Without this the simulator's default integration would still run
	# gravity but ignore _integrate_forces.
	bone.custom_integrator = true
	bone.visible = show_physics_bones_in_editor
	return bone


# Resolves (reach_seconds, damping_ratio) for `skel_bone_name`. Per-bone
# JiggleEntry wins; absent that the profile-level defaults; absent the
# whole profile, the hardcoded code constants (0.3 s reach / 0.7 ζ —
# critically-soft baseline that's worked well for breast tissue).
func _resolve_jiggle_params(skel_bone_name: StringName) -> Vector2:
	if jiggle_profile != null:
		return jiggle_profile.params_for(skel_bone_name)
	return Vector2(0.3, 0.7)


# Hull AABB volume × water-equivalent density. Crude but defensible —
# breast / glute tissue is ~94–104% the density of water, so 1000 kg/m³
# is within a few percent for any soft region. Returns a small fallback
# when no hull is available (jiggle bone gets spawned anyway with a
# capsule, so it still needs a non-zero mass).
func _estimate_jiggle_mass(skel_bone_name: StringName) -> float:
	if bone_collision_profile == null or not bone_collision_profile.has_hull(skel_bone_name):
		return 0.5
	var pts: PackedVector3Array = bone_collision_profile.hulls[skel_bone_name]
	var aabb := AABB(pts[0], Vector3.ZERO)
	for i: int in range(1, pts.size()):
		aabb = aabb.expand(pts[i])
	var volume: float = aabb.size.x * aabb.size.y * aabb.size.z
	# 1000 kg/m³ × volume; floor at 0.1 kg so a degenerate AABB doesn't
	# produce a near-zero-mass body that physics chokes on.
	return max(volume * 1000.0, 0.1)


# Walks the active simulator's bone children (MarionetteBone + JiggleBone)
# and pushes the current `show_physics_bones_in_editor` value into their
# `visible` flag. Called from the export's setter so the toggle works
# without a rebuild.
func _apply_physics_bone_visibility() -> void:
	var sim: PhysicalBoneSimulator3D = _find_simulator()
	if sim == null:
		return
	for child in sim.get_children():
		if child is MarionetteBone or child is JiggleBone:
			(child as PhysicalBone3D).visible = show_physics_bones_in_editor


# --- Collision overlay (replaces the old EditorNode3DGizmoPlugin path) -----
# Permanent MeshInstance3D children of each bone, drawn through the regular
# Node3D pipeline so wireframes refresh on every editor frame regardless of
# viewport input. The gizmo plugin's _redraw was MessageQueue-deferred and
# only flushed on viewport interaction (memory:reference_godot_tool_gizmo_redraw),
# which made hulls invisible until the user clicked.
#
# Owner is intentionally NOT set on the overlay nodes — they're editor-only
# debug visualization, regenerated every Build Ragdoll, never baked into
# the .tscn (avoids a few hundred KB of debug-mesh duplication on top of
# the colliders themselves).

const _OVERLAY_NAME: StringName = &"_CollisionOverlay"
const _OVERLAY_COLOR: Color = Color(0.35, 0.85, 0.9, 0.35)
static var _overlay_material_cache: StandardMaterial3D = null


# Spawns a MeshInstance3D under `bone` at the same local transform as the
# collider, with the collider shape's debug mesh and the soft-cyan material.
# No-op when the collider has no shape (degenerate hull etc.).
func _attach_collision_overlay(bone: PhysicalBone3D, collider: CollisionShape3D) -> void:
	if collider == null or collider.shape == null:
		return
	var debug_mesh: ArrayMesh = collider.shape.get_debug_mesh()
	if debug_mesh == null:
		return
	var mi := MeshInstance3D.new()
	mi.name = String(_OVERLAY_NAME)
	mi.mesh = debug_mesh
	mi.material_override = _collision_overlay_material()
	mi.transform = collider.transform
	mi.visible = show_collision_overlay
	bone.add_child(mi)
	# Owner deliberately not set — overlay is editor-only debug, not
	# persisted into the scene.


# Walks the active simulator and toggles every overlay's `visible` flag.
# Called from the show_collision_overlay setter so the toggle works
# without rebuilding the ragdoll.
func _apply_collision_overlay_visibility() -> void:
	var sim: PhysicalBoneSimulator3D = _find_simulator()
	if sim == null:
		return
	for bone: Node in sim.get_children():
		if not (bone is MarionetteBone or bone is JiggleBone):
			continue
		for child: Node in bone.get_children():
			if child is MeshInstance3D and StringName(child.name) == _OVERLAY_NAME:
				(child as MeshInstance3D).visible = show_collision_overlay


# Single shared material for all overlays — soft cyan, semi-transparent,
# not on-top so the body mesh occludes back-side hull edges. Cached because
# the same material reference works for every overlay (CLAUDE.md "Per-frame
# ShaderMaterial allocation" — built once, reused).
static func _collision_overlay_material() -> StandardMaterial3D:
	if _overlay_material_cache != null:
		return _overlay_material_cache
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _OVERLAY_COLOR
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Render as wireframe lines — the debug_mesh from get_debug_mesh()
	# is already line topology, so this is just material-side bookkeeping.
	mat.no_depth_test = false
	_overlay_material_cache = mat
	return mat


# Sets dynamic 6DOF joint properties. Splitting this out keeps _build_bone
# focused on per-bone shape + state and the joint-baking logic isolated.
#
# Godot 4.6 PhysicalBone3D 6DOF property paths use the form
# `joint_constraints/<axis>/<limit_kind>_<bound>` — verified empirically via
# get_property_list().
#
# Two Jolt-specific quirks (memory:reference_godot_physicalbone_jolt_angle_units):
#
# 1. The `angular_limit_lower/upper` properties carry the `radians_as_degrees`
#    hint (inspector displays in degrees, converts on input — implying stored
#    radians) but Jolt actually consumes the stored number AS DEGREES. So we
#    rad_to_deg() before writing.
#
# 2. HINGE-only X-axis sign mirroring. Authoring `rom_min.x = -20°,
#    rom_max.x = +120°` on an elbow produces motion `(-120°, +20°)` (bone
#    hyperextends, can't curl) without a swap-and-negate flip. Suspected
#    cause: HINGE is the only archetype that produces a non-zero
#    `rest_anatomical_offset.x` (carrying-angle offset from
#    `_compute_rest_offset`); the offset combines with Jolt's X-axis
#    decomposition in a way that mirrors the limit. SADDLE / BALL / SPINE_
#    SEGMENT / CLAVICLE all read correctly without the flip.
static func _apply_joint_constraints(bone: MarionetteBone, entry: BoneEntry) -> void:
	# Anatomical ROM, shifted by `-rest_anatomical_offset` so canonical-anatomy
	# bounds (rom_min/rom_max) map to joint-local Jolt limits. Joint identity
	# is the rest pose orientation; canonical zero sits at joint angle
	# `-rest_offset`, which is allowed only if `rom_min - rest_offset` reaches
	# that low. Joint-axis map (post joint_rotation bake): x=flex, y=medial
	# rotation, z=abduction.
	var anatomical_min: Vector3 = entry.rom_min - entry.rest_anatomical_offset
	var anatomical_max: Vector3 = entry.rom_max - entry.rest_anatomical_offset
	for i: int in range(3):
		var axis: String = ["x", "y", "z"][i]
		var lower_rad: float = anatomical_min[i]
		var upper_rad: float = anatomical_max[i]
		# Mirror the abduction limits when the basis chirality flipped that
		# axis (see BoneEntry.mirror_abd). Negate AND swap so the joint
		# permits the anatomically-positive direction even though the joint-
		# local +Z rotation produces motion in the anti-anatomical direction.
		if i == 2 and entry.mirror_abd:
			var t: float = lower_rad
			lower_rad = -upper_rad
			upper_rad = -t
		# HINGE X-axis flip (quirk #2 above).
		if i == 0 and entry.archetype == BoneArchetype.Type.HINGE:
			var t2: float = lower_rad
			lower_rad = -upper_rad
			upper_rad = -t2
		bone.set("joint_constraints/%s/angular_limit_enabled" % axis, true)
		bone.set("joint_constraints/%s/angular_limit_lower" % axis, rad_to_deg(lower_rad))
		bone.set("joint_constraints/%s/angular_limit_upper" % axis, rad_to_deg(upper_rad))

		# 6DOF angular spring (slice 3). Per-axis: a positive stiffness
		# enables the spring on that axis. Zero stiffness disables — Jolt
		# skips the constraint, keeping joint solve cheap on locked-DOF
		# axes (Hinge Y/Z, Saddle Y, etc.). Damping is meaningful only when
		# the spring is enabled.
		#
		# Property paths are `angular_spring_{enabled,stiffness,damping}` —
		# NOT `angular_limit_spring_*` despite the limit fields above using
		# `angular_limit_*`. Empirically verified via get_property_list.
		var k: float = entry.spring_stiffness[i]
		var c: float = entry.spring_damping[i]
		var spring_on: bool = k > 0.0
		bone.set("joint_constraints/%s/angular_spring_enabled" % axis, spring_on)
		if spring_on:
			bone.set("joint_constraints/%s/angular_spring_stiffness" % axis, k)
			bone.set("joint_constraints/%s/angular_spring_damping" % axis, c)

		# Lock linear motion across the joint — bones articulate, they don't
		# slide. 0 is unit-agnostic (the rad-as-deg quirk doesn't matter for
		# zero values).
		bone.set("joint_constraints/%s/linear_limit_enabled" % axis, true)
		bone.set("joint_constraints/%s/linear_limit_lower" % axis, 0.0)
		bone.set("joint_constraints/%s/linear_limit_upper" % axis, 0.0)


# Capsule sized to bone length, oriented along bone-local +Y (the ARP /
# Blender convention; Godot's CapsuleShape3D defaults to local Y). Pulled
# out of `_build_bone` so build_ragdoll and the live-rebuild path
# (_rebuild_colliders_on_live_simulator) construct the same shape.
#
# Sizing rationale:
#   radius coefficient 0.12 — makes upper-arm/leg capsules ~3.5 cm radius
#       (7 cm diameter), which is roughly anatomical without being so fat
#       that grandparent↔grandchild pairs overlap at joint corners.
#   minimum radius 0.005 (5 mm) — the previous 2 cm floor pinned every
#       short bone (finger distal, toe distal, all phalanges) to a 4 cm
#       diameter capsule, which is wider than the actual digit. Adjacent
#       digits then collided regardless of digit-sibling exclusions and
#       blew the hand/foot apart. 5 mm is thin but doesn't explode.
static func _make_capsule_collider(bone_length: float) -> CollisionShape3D:
	var capsule := CapsuleShape3D.new()
	capsule.radius = max(bone_length * 0.12, 0.005)
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
	return collider


# Returns the right collider for `bone`: a ConvexPolygonShape3D from
# `bone_collision_profile` when the profile has a hull for this bone,
# else a capsule fallback. Used by build_ragdoll and the live-rebuild
# path triggered by setting `bone_collision_profile` on a Marionette
# whose simulator already exists.
func _build_collider_for_bone(
		bone: PhysicalBone3D,
		skel: Skeleton3D,
		skel_index: int) -> CollisionShape3D:
	if bone_collision_profile != null:
		var skel_bone_name: StringName = StringName(bone.bone_name)
		var profile_name: StringName = _resolve_profile_name(skel_bone_name)
		var key: StringName = profile_name if profile_name != &"" else skel_bone_name
		if bone_collision_profile.has_hull(key):
			var shape: ConvexPolygonShape3D = bone_collision_profile.make_shape(key)
			var collider := CollisionShape3D.new()
			collider.shape = shape
			# Hulls live in bone-local space (Skin bind pose × mesh vertex);
			# no extra offset, in contrast to the capsule which gets shifted
			# half its length along +Y to hug the bone segment.
			collider.position = Vector3.ZERO
			collider.visible = false
			return collider
	return _make_capsule_collider(_bone_length(skel, skel_index))


## Harvests skinned vertices off `collision_source_mesh` (or auto-
## discovered skinned meshes under the skeleton's parent), buckets per
## bone, decimates each bucket, and assigns the result to
## `bone_collision_profile`. Auto-saves the .tres when the profile has
## a resource_path; otherwise the new profile lives in scene memory
## until the user "Save As"s it.
func build_convex_colliders() -> void:
	var skel: Skeleton3D = resolve_skeleton()
	if skel == null:
		push_error("Marionette.build_convex_colliders: skeleton not resolvable from %s" % skeleton)
		return
	var meshes: Array[MeshInstance3D] = _resolve_collision_source_meshes(skel)
	if meshes.is_empty():
		push_warning("Marionette.build_convex_colliders: no skinned MeshInstance3D found under %s"
				% (collision_source_mesh if not collision_source_mesh.is_empty() else NodePath("<auto>")))
		return

	# Inherit knobs from the existing profile when present so re-builds use
	# the user's tuned values; new profiles get the resource defaults.
	var template: BoneCollisionProfile = bone_collision_profile if bone_collision_profile != null else BoneCollisionProfile.new()
	var merged := BoneCollisionProfile.new()
	merged.weight_threshold = template.weight_threshold
	merged.max_points_per_hull = template.max_points_per_hull
	merged.shrink_factor = template.shrink_factor
	merged.non_cascade_bones = template.non_cascade_bones.duplicate()

	for mi: MeshInstance3D in meshes:
		if mi.mesh == null or mi.skin == null:
			continue
		var per: BoneCollisionProfile = ColliderBuilder.build_profile(mi, skel, bone_map, merged)
		_merge_collision_profile_into(merged, per)

	# Recompute overlaps against the merged hulls — per-mesh exclusion sets
	# would miss pairs that only overlap once accessory meshes are added.
	merged.auto_exclusions = ColliderBuilder.compute_overlap_pairs(merged, skel, bone_map)

	# Auto-save when the existing profile has a path on disk; mirrors
	# Calibrate's persist behavior. Otherwise leave the new profile in
	# scene memory — user "Save As"s from the inspector.
	var save_path: String = bone_collision_profile.resource_path if bone_collision_profile != null else ""
	bone_collision_profile = merged
	if save_path != "":
		merged.take_over_path(save_path)
		var err: int = ResourceSaver.save(merged, save_path)
		if err != OK:
			push_warning("Marionette.build_convex_colliders: ResourceSaver returned %d for %s" % [err, save_path])
	print("[Marionette] built %d hulls (%d auto-exclusion pairs) from %d mesh(es)"
			% [merged.hulls.size(), merged.auto_exclusions.size(), meshes.size()])


## Drops the bone_collision_profile reference. Bones revert to per-bone
## capsules sized from bone length on the next live-rebuild. Useful
## when iterating on the rig and the cached hulls don't match the
## current mesh anymore.
func revert_to_capsules() -> void:
	bone_collision_profile = null


# Resolves the source-mesh search roots and walks them for skinned
# MeshInstance3D nodes targeting `skel`. Explicit `collision_source_mesh`
# wins; otherwise the skeleton's parent is searched (which is where ARP
# rigs typically place the body mesh as a sibling of Skeleton3D).
func _resolve_collision_source_meshes(skel: Skeleton3D) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var roots: Array[Node] = []
	if not collision_source_mesh.is_empty():
		var n: Node = get_node_or_null(collision_source_mesh)
		if n != null:
			roots.append(n)
	if roots.is_empty():
		var parent: Node = skel.get_parent()
		if parent != null:
			roots.append(parent)
	for r: Node in roots:
		_collect_skinned_meshes(r, skel, out)
	return out


# Recursively appends every MeshInstance3D under `from` whose `skeleton`
# NodePath resolves to `target_skel`. A direct hit (when `from` itself
# is the mesh) is included.
static func _collect_skinned_meshes(from: Node, target_skel: Skeleton3D, out: Array[MeshInstance3D]) -> void:
	if from == null:
		return
	if from is MeshInstance3D:
		var mi: MeshInstance3D = from
		if mi.skin != null and not mi.skeleton.is_empty():
			var resolved: Node = mi.get_node_or_null(mi.skeleton)
			if resolved == target_skel:
				out.append(mi)
	for c: Node in from.get_children():
		_collect_skinned_meshes(c, target_skel, out)


# Folds `src.hulls` into `dst.hulls`. Coincident keys (e.g. an accessory
# mesh contributing extra geometry to the chest) get their points
# concatenated and re-decimated to the cap so merged hulls stay
# comparable to single-source ones.
static func _merge_collision_profile_into(
		dst: BoneCollisionProfile,
		src: BoneCollisionProfile) -> void:
	for bone_name: StringName in src.hulls.keys():
		var src_pts: PackedVector3Array = src.hulls[bone_name]
		if src_pts.is_empty():
			continue
		if not dst.hulls.has(bone_name):
			dst.hulls[bone_name] = src_pts
			continue
		var combined: PackedVector3Array = dst.hulls[bone_name]
		combined.append_array(src_pts)
		dst.hulls[bone_name] = ColliderBuilder.find_optimal_decimation(
				combined, dst.max_points_per_hull)


# Walks the live simulator and re-creates each bone's CollisionShape3D
# according to the current `bone_collision_profile`. Fired by the export
# setter so changing the profile in the inspector takes effect without
# Build/Clear Ragdoll. No-op when no simulator exists.
func _rebuild_colliders_on_live_simulator() -> void:
	var sim: PhysicalBoneSimulator3D = _find_simulator()
	if sim == null:
		return
	var skel: Skeleton3D = resolve_skeleton()
	if skel == null:
		return
	for child: Node in sim.get_children():
		if not (child is MarionetteBone or child is JiggleBone):
			continue
		var bone: PhysicalBone3D = child
		var skel_index: int = skel.find_bone(bone.bone_name)
		if skel_index < 0:
			continue
		# Collect first, free after — mutating children during iteration
		# invalidates the iterator. Sweep both colliders and overlay
		# wireframes since the new collider's debug mesh differs from
		# the old.
		var stale: Array[Node] = []
		for c: Node in bone.get_children():
			if c is CollisionShape3D:
				stale.append(c)
			elif c is MeshInstance3D and StringName(c.name) == _OVERLAY_NAME:
				stale.append(c)
		for c: Node in stale:
			bone.remove_child(c)
			c.free()
		var collider: CollisionShape3D = _build_collider_for_bone(bone, skel, skel_index)
		bone.add_child(collider)
		# Both shape kinds bake into the scene now (slice 6); the bloat
		# concern is accepted in exchange for explicit Build = persist.
		_set_owner_for_editor(collider)
		_attach_collision_overlay(bone, collider)


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
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	# Editor: edited_scene_root is the .tscn currently open. Setting owner
	# there packs the node into the saved scene on Ctrl+S.
	# Test / packed-instantiate context: edited_scene_root is null. Fall
	# back to this Marionette's own scene root via its owner — that's
	# whatever node packed *us* into the scene we live in. PackedScene.pack
	# captures any descendant whose owner is the packed node, so this
	# fallback makes test-driven Build → save → reload round-trip work
	# exactly the way the editor flow does.
	var owner_node: Node = tree.edited_scene_root
	var ok: bool = owner_node != null and is_ancestor_of_or_equal(owner_node, self)
	if not ok:
		owner_node = self.owner
		ok = owner_node != null and is_ancestor_of_or_equal(owner_node, self)
	if ok:
		node.owner = owner_node


# True if `ancestor` equals `self` or is an ancestor of `self` in the scene tree.
# Used to gate owner-assignment so we don't pollute scenes the user isn't editing.
static func is_ancestor_of_or_equal(ancestor: Node, descendant: Node) -> bool:
	var n: Node = descendant
	while n != null:
		if n == ancestor:
			return true
		n = n.get_parent()
	return false
