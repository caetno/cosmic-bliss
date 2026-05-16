@tool
extends Node
## Phase 6 — Stimulus Bus autoload wrapper.
##
## Production projects add this script to project.godot's [autoload]
## section so the C++ `StimulusBus` singleton is alive for the full
## session. Tests instantiate the C++ class directly via
## `ClassDB.instantiate("StimulusBus")` and call `install_as_singleton`.
##
## Cross-cutting registration (adding to project.godot autoload list) is
## the supervisor's responsibility — this script just provides the seam.

var _bus: Object = null


func _enter_tree() -> void:
	if not ClassDB.class_exists("StimulusBus"):
		push_error("[StimulusBusAutoload] StimulusBus class not registered (extension not loaded)")
		return
	_bus = ClassDB.instantiate("StimulusBus")
	if _bus != null and _bus.has_method("install_as_singleton"):
		_bus.install_as_singleton()


func _exit_tree() -> void:
	if _bus != null and _bus.has_method("uninstall_as_singleton"):
		_bus.uninstall_as_singleton()
	_bus = null


func get_bus() -> Object:
	return _bus
