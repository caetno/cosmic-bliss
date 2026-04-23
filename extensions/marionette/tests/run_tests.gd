extends SceneTree


func _init() -> void:
	var passed: int = 0
	var failed: int = 0

	if _test_smoke():
		passed += 1
	else:
		failed += 1

	print("\n%d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _test_smoke() -> bool:
	if 1 + 1 == 2:
		print("[PASS] test_smoke")
		return true
	push_error("[FAIL] test_smoke: 1 + 1 != 2")
	return false
