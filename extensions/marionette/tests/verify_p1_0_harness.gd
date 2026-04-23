extends SceneTree


func _init() -> void:
	var failed: int = 0

	var profile: SkeletonProfile = load("res://addons/marionette/data/bone_map_icon_test_profile.tres")
	if profile == null:
		push_error("[FAIL] profile .tres did not load")
		failed += 1
	else:
		print("[OK] profile loaded: %s" % profile)
		print("     group_size = %d" % profile.group_size)
		print("     bone_size  = %d" % profile.bone_size)
		for i in range(profile.group_size):
			var tex := profile.get_texture(i)
			print("     group[%d] name=%s texture=%s" % [i, profile.get_group_name(i), tex])
			if tex == null:
				push_error("[FAIL] group[%d] (%s) has null texture" % [i, profile.get_group_name(i)])
				failed += 1
		if profile.group_size != 6:
			push_error("[FAIL] expected 6 groups, got %d" % profile.group_size)
			failed += 1
		if profile.bone_size != 6:
			push_error("[FAIL] expected 6 bones, got %d" % profile.bone_size)
			failed += 1

	var bone_map: BoneMap = load("res://addons/marionette/data/bone_map_icon_test.tres")
	if bone_map == null:
		push_error("[FAIL] bone_map .tres did not load")
		failed += 1
	elif bone_map.profile == null:
		push_error("[FAIL] bone_map.profile is null")
		failed += 1
	else:
		print("[OK] bone_map loaded with profile: %s" % bone_map.profile)

	if failed == 0:
		print("\nP1.0 harness: ALL CHECKS PASSED")
		quit(0)
	else:
		print("\nP1.0 harness: %d checks failed" % failed)
		quit(1)
