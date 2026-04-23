extends SceneTree


func _init() -> void:
	var p := SkeletonProfileHumanoid.new()
	print("root_bone = %s" % p.root_bone)
	print("scale_base_bone = %s" % p.scale_base_bone)
	print("group_size = %d" % p.group_size)
	for i in range(p.group_size):
		print("  group[%d] = %s" % [i, p.get_group_name(i)])
	print("bone_size = %d" % p.bone_size)
	for i in range(p.bone_size):
		var name := p.get_bone_name(i)
		var parent := p.get_bone_parent(i)
		var tail := p.get_bone_tail(i)
		var pose := p.get_reference_pose(i)
		var handle := p.get_handle_offset(i)
		var group := p.get_group(i)
		print("  [%d] %s  parent=%s  tail=%s  group=%s  handle=%s  pose.origin=%s  pose.basis_x=%s" % [
			i, name, parent, tail, group, handle, pose.origin, pose.basis.x,
		])
	quit(0)
