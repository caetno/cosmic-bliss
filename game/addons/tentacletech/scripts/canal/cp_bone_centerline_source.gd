@tool
class_name CPBoneCenterlineSource
extends CanalCenterlineSource

## Centerline source that scans the skeleton for control-point bones
## named `<spline_cp_bone_prefix>_<int>` (e.g. `Vag_CP_0`, `Vag_CP_1`)
## and builds a Catmull spline through their world heads in numeric-
## suffix order. The closed-terminal distal anchor comes from a
## `terminal_pin_bone` lookup with a `terminal_position_in_host_frame`
## fallback.
##
## This is the 5E authoring path, hoisted out of `CanalAutoBaker` so
## the per-tick refresh of centerline rest positions (5F+) can swap
## the source without touching the solver. It will become legacy /
## back-compat once the gizmo-primitive authoring path in
## `body_field` lands a `CanalCenterlinePrimitiveSource`.


func build_spline(p_skeleton: Skeleton3D, p_canal: Node) -> RefCounted:
	if p_canal == null:
		return null
	var params: CanalParameters = p_canal.canal_parameters
	if params == null:
		push_error("CPBoneCenterlineSource: canal has no canal_parameters")
		return null
	return CanalAutoBaker.build_spline_from_cp_bones(
			p_skeleton, String(params.spline_cp_bone_prefix))


func resolve_closed_terminal_anchor(
		p_canal_params: CanalParameters,
		p_skeleton: Skeleton3D,
		p_fallback: Vector3) -> Vector3:
	# Try TerminalPin bone first.
	if p_canal_params != null and not p_canal_params.terminal_pin_bone.is_empty() \
			and p_skeleton != null:
		var bone_idx := p_skeleton.find_bone(String(p_canal_params.terminal_pin_bone))
		if bone_idx >= 0:
			var pose: Transform3D = p_skeleton.get_bone_global_pose(bone_idx)
			return p_skeleton.global_transform * pose.origin
	# Fall back to host-frame position.
	if p_canal_params != null and p_skeleton != null:
		return p_skeleton.global_transform * p_canal_params.terminal_position_in_host_frame
	if p_canal_params != null:
		return p_canal_params.terminal_position_in_host_frame
	return p_fallback


# Per-tick anchor refresh. Proximal = entry orifice Center (via shared
# helper); distal = exit orifice Center (open) OR terminal pin
# (closed). All resolution paths re-evaluate from current bone /
# orifice transforms, so a moving host bone propagates into the chain
# without re-running the bake.
#
# `canal` is expected to be a `Canal` node carrying:
#   * `canal_parameters: CanalParameters`
#   * `orifices_root: Node` (NodePath; resolved by caller). For 5F.B.A
#     we ask `canal.get_orifices_root()` if defined, else fall back to
#     the canal's parent (assumed hero-root convention).
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

	# Orifices root: ask the canal first; fall back to its parent.
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
