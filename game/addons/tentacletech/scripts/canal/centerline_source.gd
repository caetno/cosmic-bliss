@tool
class_name CanalCenterlineSource
extends Resource

## Abstract source of rest-pose data for a `Canal`'s centerline.
##
## Decouples the centerline solver / per-vert baker from where the
## control points come from. Two concrete sources live in 5F.A.0:
##
##   * `CPBoneCenterlineSource` — scans `<spline_cp_bone_prefix>_*`
##     skeleton bones (the 5E path).
##   * `CanalCenterlinePrimitiveSource` (future, body_field-side) —
##     samples a `CanalCenterlinePrimitive` resource where each control
##     point's world transform is `host_bone_world × ctrl_local_offset`.
##
## Per the 2026-05-13 gizmo-primitive authoring amendment, the bone
## source path is back-compat scaffolding; production canals will
## migrate to the primitive source once `body_field` ships its
## primitive resource family + gizmo plugin. The solver and the
## per-tick rest-pose refresh path consume only this abstraction —
## neither knows which source is plugged in.
##
## Sources own two source-coupled concerns:
##   1. spline construction (rest-pose CP geometry)
##   2. closed-terminal distal anchor (currently a `TerminalPin` bone,
##      future: a `Vector3` offset on `Canal`)
##
## Entry/exit orifice anchor lookup is canal-state plumbing (NodePath
## resolution + Center frame query) and stays in `CanalAutoBaker`
## across both source variants — it is not authoring-source-coupled.


## Build the rest-pose Catmull spline through the source's control
## points. Returns a `CatmullSpline` (via `ClassDB.instantiate`) or
## `null` on failure. Override in concrete subclasses.
##
## `skeleton` and `canal` are provided in case the source wants to
## resolve bone-relative offsets or read canal-local data; sources
## that don't need either may ignore them.
func build_spline(_skeleton: Skeleton3D, _canal: Node) -> RefCounted:
	push_error("CanalCenterlineSource.build_spline: abstract — override in subclass")
	return null


## Resolve the closed-terminal distal anchor in world space.
## Called only when `canal_parameters.closed_terminal == true`.
## `fallback` is the spline endpoint, returned by base implementations
## that have no terminal data available.
func resolve_closed_terminal_anchor(
		_canal_params: CanalParameters,
		_skeleton: Skeleton3D,
		fallback: Vector3) -> Vector3:
	return fallback
