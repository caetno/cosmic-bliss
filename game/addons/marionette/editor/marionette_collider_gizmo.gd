@tool
class_name MarionetteColliderGizmo
extends EditorNode3DGizmoPlugin

# Renders each MarionetteBone's CollisionShape3D as a wireframe under
# the Marionette node, independent of `show_physics_bones_in_editor` /
# CollisionShape3D.visible. Lives as its own gizmo plugin so it appears
# in View → Gizmos as a separate "Marionette Colliders" toggle — the
# user can flip *just the colliders* on while leaving the 6DOF joint
# gizmos and the Skeleton3D bone fan off.
#
# Pulls geometry from each shape's `get_debug_mesh()`, which returns a
# wireframe ArrayMesh ready for `gizmo.add_mesh`. Works for capsule,
# sphere, box, etc. — whatever colliders the Marionette is using.
#
# Attach point: Marionette (singleton-style, mirrors JointLimitGizmo).
# Selecting the Marionette node draws every bone's collider in one pass;
# selecting a single MarionetteBone shows nothing here. That matches how
# the joint-limits gizmo already behaves.

const _MAT: StringName = &"collider_capsule"
# Soft cyan — distinct from the joint-limit gizmo's desaturated RGB
# arcs and the authoring tripod's RGB tripod, but transparent enough
# that the mesh underneath stays readable when the Marionette is
# selected. Pre-slice-8a values were (0.2, 0.95, 0.95, 1.0) with
# on_top=true — opaque cyan over the body, very intense.
const _COL: Color = Color(0.35, 0.85, 0.9, 0.35)


func _init() -> void:
	# on_top=false so the body mesh occludes the back-side hull lines —
	# wireframes only read against the front. Material is also semi-
	# transparent so the front lines don't drown the mesh.
	create_material(_MAT, _COL, false, false)


func _get_gizmo_name() -> String:
	return "Marionette Colliders"


# Higher than authoring (1) and joint-limits (2) so collider wireframes
# draw above ROM arcs and tripods at coincident points.
func _get_priority() -> int:
	return 3


func _has_gizmo(for_node_3d: Node3D) -> bool:
	return for_node_3d is Marionette


func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var node: Marionette = gizmo.get_node_3d() as Marionette
	if node == null:
		return
	var skel: Skeleton3D = node.resolve_skeleton()
	if skel == null:
		return
	var sim: PhysicalBoneSimulator3D = null
	for c: Node in skel.get_children():
		if c is PhysicalBoneSimulator3D:
			sim = c as PhysicalBoneSimulator3D
			break
	if sim == null:
		return
	var mat: StandardMaterial3D = get_material(_MAT, gizmo)
	# Gizmo geometry is in the Marionette node's local space; convert each
	# collider's world transform back through Marionette's inverse.
	var marionette_inv: Transform3D = node.global_transform.affine_inverse()
	# Both MarionetteBone and JiggleBone (sibling class post slice 1)
	# carry collision shapes; widen the iteration so jiggle hulls render
	# alongside the regular bone hulls.
	for bone_node: Node in sim.get_children():
		if not (bone_node is MarionetteBone or bone_node is JiggleBone):
			continue
		var bone: PhysicalBone3D = bone_node
		for child: Node in bone.get_children():
			if not (child is CollisionShape3D):
				continue
			var cs: CollisionShape3D = child
			if cs.shape == null:
				continue
			var debug_mesh: ArrayMesh = cs.shape.get_debug_mesh()
			if debug_mesh == null:
				continue
			var col_world: Transform3D = bone.global_transform * cs.transform
			gizmo.add_mesh(debug_mesh, mat, marionette_inv * col_world)
