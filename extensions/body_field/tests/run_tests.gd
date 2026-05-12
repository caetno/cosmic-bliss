extends SceneTree

# B0 — body_field scaffolding harness. SceneTree + _process one-shot pattern
# (mirrors TentacleTech 5E). Single bridge test in B0; harness graduates to
# the Marionette internal-`_test_*`-function-list pattern when the test
# surface multiplies in B1+.
#
# Run from repo root:
#   godot --headless --quit-after 5 \
#     --script /home/caetano/desktop/cosmic-bliss/extensions/body_field/tests/run_tests.gd

var _ran: bool = false


func _process(_d: float) -> bool:
	if not _ran:
		_ran = true
		_run()
	return false


func _run() -> void:
	var passed: int = 0
	var failed: int = 0
	for test_name in ["test_body_field_bridge"]:
		var result: bool = call(test_name)
		if result:
			passed += 1
		else:
			failed += 1
	print("\n%d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func test_body_field_bridge() -> bool:
	# Pure-GDScript class_name registers in the global script class
	# cache but NOT in ClassDB (which only tracks engine-native + GDExtension
	# classes). Verify via load() against the deployed res:// path — this
	# bridges the full chain: build.sh deploy → res:// resolution →
	# script parse → instantiate → method call.
	const SCRIPT_PATH := "res://addons/body_field/runtime/body_field.gd"
	var script: GDScript = load(SCRIPT_PATH) as GDScript
	if script == null:
		print("[FAIL] test_body_field_bridge: failed to load %s" % SCRIPT_PATH)
		return false
	var bf: Node3D = script.new() as Node3D
	if bf == null:
		print("[FAIL] test_body_field_bridge: script.new() returned null or non-Node3D")
		return false
	if bf._bridge_test_marker() != "body_field ok":
		print("[FAIL] test_body_field_bridge: _bridge_test_marker() returned %s" % bf._bridge_test_marker())
		bf.free()
		return false
	bf.free()
	print("[PASS] test_body_field_bridge")
	return true
