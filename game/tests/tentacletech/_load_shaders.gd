extends SceneTree

# Shader-parse smoke test for TentacleTech.
#
# Run via:
#   godot --path game --headless --quit-after 1 \
#       --script res://tests/tentacletech/_load_shaders.gd
#
# Loads every Phase-3 .gdshader file via ResourceLoader. A parse error makes
# Godot print to stderr and the load() returns null; this script reports the
# count of successes and fails fast on any failure.

const SHADERS := [
	"res://addons/tentacletech/shaders/tentacle.gdshader",
]


func _init() -> void:
	var failed := 0
	for path in SHADERS:
		if not ResourceLoader.exists(path):
			push_error("[FAIL] missing shader: %s" % path)
			failed += 1
			continue
		var res = ResourceLoader.load(path)
		if res == null:
			push_error("[FAIL] failed to load: %s" % path)
			failed += 1
			continue
		print("[PASS] loaded: %s" % path)
	if failed > 0:
		quit(1)
	else:
		quit(0)
