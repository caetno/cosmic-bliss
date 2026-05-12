@tool
extends EditorPlugin

# B0 scaffolding — empty entry/exit. Editor surface (inspectors, gizmos,
# docks) earns its place from B1+ when there's something to inspect or
# visualize. plugin.gd exists in B0 only so plugin.cfg's `script=` field
# resolves to a real EditorPlugin subclass.


func _enter_tree() -> void:
	pass


func _exit_tree() -> void:
	pass
