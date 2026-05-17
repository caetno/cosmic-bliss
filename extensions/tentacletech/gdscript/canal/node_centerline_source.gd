@tool
class_name NodeCenterlineSource
extends CanalCenterlineSource

## Godot-native canal authoring without Blender CP bones.
##
## Each `control_point_paths` entry is a `NodePath` to a `Node3D` marker
## in the scene tree. World positions are sampled each call to
## `build_spline` / `refresh_anchors`. Markers can be:
##
##   (a) **Plain `Node3D` children of the hero root.** Authored by
##       dragging in the 3D viewport. Static against the rest pose;
##       won't follow bones at runtime.
##   (b) **`Node3D` children of a `Skeleton3D` bone** (via
##       `BoneAttachment3D` OR direct re-parenting after
##       `auto_attach_to_nearest_bone`). Follow the bone's world
##       transform automatically — the centerline re-shapes when the
##       skeleton moves.
##
## Order matters — list index 0 is the proximal end (entry-orifice
## side), last is the distal end (exit orifice or closed terminal).
##
## Optional per-CP `host_bone_names` lets the author hint which bone
## each marker should attach to during `auto_attach_to_nearest_bone`.
## Empty entries trigger the "nearest in 3D" auto-pick.
##
## `terminal_pin_path` is the world-space terminal pin for closed-
## terminal sacs (uterus, bladder). When set, overrides
## `CanalParameters.terminal_pin_bone` (which is the CP-bone path).
## When empty, falls back to the bone path, then to
## `terminal_position_in_host_frame`.
##
## This source is the Godot-native authoring path proposed in the
## 2026-05-13 gizmo-primitive amendment §5 step (c), but landed
## without waiting for body_field's `CanalCenterlinePrimitive`. A
## future `CanalCenterlinePrimitiveSource` will live alongside this
## one; both are valid concretes against the `CanalCenterlineSource`
## abstract base.

const _MIN_CONTROL_POINTS := 2


@export var control_point_paths: Array[NodePath] = []

## Optional per-CP override for the bone each marker should attach
## to. Same length as `control_point_paths`; empty entry → nearest-
## in-3D heuristic at `auto_attach_to_nearest_bone` time.
@export var host_bone_names: Array[StringName] = []

## Optional terminal pin marker for closed-terminal sacs. World
## position sampled each refresh. Empty path → fall through to
## `CanalParameters.terminal_pin_bone` (skeleton lookup) → fall through
## to `terminal_position_in_host_frame`.
##
## **Path resolution constraint**: the resource doesn't know its
## owning `Canal` when `resolve_closed_terminal_anchor` fires (bake
## time), so this path is resolved against the **scene tree root** —
## use an absolute path (`/root/HeroRoot/PinMarker`) or a node
## guaranteed to be reachable from `SceneTree.root.get_node_or_null`.
## A relative path will fail and trigger the bone-or-host-frame
## fallback chain.
@export var terminal_pin_path: NodePath


# ─── Source virtuals ───────────────────────────────────────────────


func build_spline(p_skeleton: Skeleton3D, p_canal: Node) -> RefCounted:
	if p_canal == null:
		push_error("NodeCenterlineSource.build_spline: canal is null")
		return null
	var points := _collect_world_positions(p_canal)
	if points.size() < _MIN_CONTROL_POINTS:
		push_error("NodeCenterlineSource: need ≥ %d resolvable control_point_paths (got %d)"
				% [_MIN_CONTROL_POINTS, points.size()])
		return null
	if not ClassDB.class_exists("CatmullSpline"):
		push_error("NodeCenterlineSource: CatmullSpline class not registered (tentacletech extension not loaded)")
		return null
	var spline: RefCounted = ClassDB.instantiate("CatmullSpline")
	spline.build_from_points(points)
	return spline


func resolve_closed_terminal_anchor(
		p_canal_params: CanalParameters,
		p_skeleton: Skeleton3D,
		p_fallback: Vector3) -> Vector3:
	# 1. Explicit terminal_pin_path wins when set + resolvable.
	if not terminal_pin_path.is_empty():
		var pin_node := _resolve_terminal_pin_node()
		if pin_node != null:
			return pin_node.global_position
	# 2. Fall through to the CP-bone path on the skeleton (matches
	#    `CPBoneCenterlineSource.resolve_closed_terminal_anchor`).
	if p_canal_params != null and not p_canal_params.terminal_pin_bone.is_empty() \
			and p_skeleton != null:
		var bone_idx := p_skeleton.find_bone(String(p_canal_params.terminal_pin_bone))
		if bone_idx >= 0:
			var pose: Transform3D = p_skeleton.get_bone_global_pose(bone_idx)
			return p_skeleton.global_transform * pose.origin
	# 3. Host-frame fallback.
	if p_canal_params != null and p_skeleton != null:
		return p_skeleton.global_transform * p_canal_params.terminal_position_in_host_frame
	if p_canal_params != null:
		return p_canal_params.terminal_position_in_host_frame
	return p_fallback


func refresh_anchors(
		p_skeleton: Skeleton3D,
		p_canal: Node,
		p_fallback_proximal: Vector3,
		p_fallback_distal: Vector3) -> Dictionary:
	if p_canal == null:
		return {"proximal": p_fallback_proximal, "distal": p_fallback_distal}
	var params: CanalParameters = p_canal.canal_parameters
	if params == null:
		return {"proximal": p_fallback_proximal, "distal": p_fallback_distal}

	var orifices_root: Node = null
	if p_canal.has_method("get_orifices_root"):
		orifices_root = p_canal.call("get_orifices_root")
	if orifices_root == null and p_canal is Node:
		orifices_root = (p_canal as Node).get_parent()

	var proximal := CanalAutoBaker.resolve_entry_orifice_anchor(
			params, orifices_root, p_fallback_proximal)

	var distal: Vector3
	if params.closed_terminal:
		distal = resolve_closed_terminal_anchor(params, p_skeleton, p_fallback_distal)
	else:
		distal = CanalAutoBaker.resolve_exit_orifice_anchor(
				params, orifices_root, p_fallback_distal)

	return {"proximal": proximal, "distal": distal}


# ─── Bake / authoring helpers ──────────────────────────────────────


## Resolve all control-point markers to their current world positions
## (in scene-root space). Skips empty paths and unresolvable paths
## with a `push_warning`. Returns a `PackedVector3Array` in
## `control_point_paths` order.
##
## `p_canal` is the `Canal` node — used as the lookup base so
## `NodePath` entries can be either absolute or relative to the canal.
func _collect_world_positions(p_canal: Node) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in control_point_paths.size():
		var path: NodePath = control_point_paths[i]
		if path.is_empty():
			push_warning("NodeCenterlineSource: control_point_paths[%d] is empty" % i)
			continue
		var n := p_canal.get_node_or_null(path)
		if n == null:
			push_warning("NodeCenterlineSource: control_point_paths[%d] '%s' did not resolve"
					% [i, String(path)])
			continue
		if not (n is Node3D):
			push_warning("NodeCenterlineSource: control_point_paths[%d] '%s' is not Node3D"
					% [i, String(path)])
			continue
		out.append((n as Node3D).global_position)
	return out


## Resolve the terminal pin marker. Returns `null` if path is empty
## or unresolvable. Called from `resolve_closed_terminal_anchor`.
## Resolution base is the canal's parent (hero root); falls back to
## a tree-root search if the path is absolute.
func _resolve_terminal_pin_node() -> Node3D:
	if terminal_pin_path.is_empty():
		return null
	# Try via the resource's `get_local_scene` (returns null when the
	# resource isn't attached to a scene). For our case (resource on a
	# Canal node), use the canal's tree to resolve — but the source
	# resource doesn't know its owning Canal. The cleanest contract:
	# accept terminal_pin_path as a path that's resolved by the canal
	# at refresh time. To keep the helper standalone, walk the global
	# scene tree via `Engine.get_main_loop().get_root().get_node_or_null`.
	var tree := Engine.get_main_loop()
	if tree == null or not (tree is SceneTree):
		return null
	var root := (tree as SceneTree).root
	if root == null:
		return null
	var n := root.get_node_or_null(terminal_pin_path)
	if n is Node3D:
		return n
	return null


## `@tool`-callable utility. For each entry in `control_point_paths`,
## walks `p_skeleton`'s bones, picks the nearest in 3D (or honors a
## non-empty `host_bone_names[i]`), and re-parents the Node3D under a
## fresh `BoneAttachment3D` for that bone. The marker now follows the
## bone's world transform; the canal's centerline reshapes as the
## skeleton animates.
##
## Returns the count of markers successfully attached. Markers already
## under a `BoneAttachment3D` are skipped (idempotent).
##
## Run this once at authoring time (editor tool button or `@onready`
## helper). The result is persistent across saves because the scene-
## tree change is durable.
##
## Limitation: assumes the canal has a Skeleton3D ancestor or sibling.
## Markers must be reachable from the skeleton's parent via NodePath.
func auto_attach_to_nearest_bone(
		p_canal: Node,
		p_skeleton: Skeleton3D) -> int:
	if p_canal == null or p_skeleton == null:
		push_error("NodeCenterlineSource.auto_attach_to_nearest_bone: null canal or skeleton")
		return 0
	var attached := 0
	for i in control_point_paths.size():
		var path: NodePath = control_point_paths[i]
		if path.is_empty():
			continue
		var marker := p_canal.get_node_or_null(path)
		if marker == null or not (marker is Node3D):
			continue
		# Skip if already a child of a BoneAttachment3D — idempotent.
		var current_parent := (marker as Node3D).get_parent()
		if current_parent is BoneAttachment3D:
			continue
		# Resolve bone name: explicit override > nearest-in-3D.
		var bone_name: StringName = StringName()
		if i < host_bone_names.size():
			bone_name = host_bone_names[i]
		if bone_name.is_empty():
			bone_name = _nearest_bone_name(p_skeleton, (marker as Node3D).global_position)
		if bone_name.is_empty():
			push_warning("NodeCenterlineSource.auto_attach: marker[%d] could not resolve a bone" % i)
			continue
		var bone_idx := p_skeleton.find_bone(String(bone_name))
		if bone_idx < 0:
			push_warning("NodeCenterlineSource.auto_attach: bone '%s' not in skeleton" % bone_name)
			continue
		# Build the attachment, parent the marker under it. We preserve
		# the marker's current `global_position` by setting it post-
		# reparent (BoneAttachment3D would otherwise snap the marker to
		# the bone's origin).
		var attachment := BoneAttachment3D.new()
		attachment.name = "Attach_%s_%d" % [String(bone_name), i]
		attachment.bone_name = String(bone_name)
		attachment.bone_idx = bone_idx
		p_skeleton.add_child(attachment)
		var world_before: Vector3 = (marker as Node3D).global_position
		var marker_parent := (marker as Node3D).get_parent()
		if marker_parent != null:
			marker_parent.remove_child(marker)
		attachment.add_child(marker)
		(marker as Node3D).global_position = world_before
		# Update the path so the source still resolves to the marker.
		control_point_paths[i] = p_canal.get_path_to(marker)
		attached += 1
	return attached


# Nearest bone in 3D — simplest heuristic. Skin-weighted-LBS proximity
# (per the 2026-05-13 amendment Q3) is a more sophisticated alternative
# that lives in body_field's gizmo plugin path; nearest-in-3D is the
# good-enough default here.
static func _nearest_bone_name(
		p_skeleton: Skeleton3D,
		p_world_pos: Vector3) -> StringName:
	var best_name: StringName = StringName()
	var best_d2 := INF
	var skel_xform: Transform3D = p_skeleton.global_transform
	for b in p_skeleton.get_bone_count():
		var pose: Transform3D = p_skeleton.get_bone_global_pose(b)
		var bone_world: Vector3 = skel_xform * pose.origin
		var d2 := (bone_world - p_world_pos).length_squared()
		if d2 < best_d2:
			best_d2 = d2
			best_name = StringName(p_skeleton.get_bone_name(b))
	return best_name
