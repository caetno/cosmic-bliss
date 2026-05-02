@tool
class_name MarionetteBoneListProperty
extends EditorProperty

# Custom inspector property for `Array[StringName]` fields that name
# skeleton bones — currently `BoneCollisionProfile.non_cascade_bones`,
# extensible to any future bone-list field. Replaces Godot's default
# array editor (raw text input per row) with a list of bone names + an
# "Add Bone" OptionButton populated from the active rig's Skeleton3D.
#
# The skeleton is sourced from the currently-selected Marionette in the
# editor's scene selection. When no Marionette is selected (e.g. opening
# the resource standalone via FileSystem), the dropdown shows an
# explanatory placeholder and falls back to manual entry behavior would
# need a TODO; for v1 we accept the limitation.

var _list: VBoxContainer
var _add_button: OptionButton
var _empty_hint: Label
var _current_value: Array[StringName] = []
var _suppress_update: bool = false


func _init() -> void:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override(&"separation", 2)
	add_child(vbox)
	set_bottom_editor(vbox)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override(&"separation", 2)
	vbox.add_child(_list)
	_empty_hint = Label.new()
	_empty_hint.text = "(no bones — select one to add below)"
	_empty_hint.add_theme_color_override(&"font_color", Color(0.6, 0.6, 0.6))
	vbox.add_child(_empty_hint)
	_add_button = OptionButton.new()
	_add_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_add_button.item_selected.connect(_on_add_bone_selected)
	vbox.add_child(_add_button)


# Inspector tells us when the property's value (re)loads. Store and
# rebuild the UI; suppress the resulting emit_changed echoes.
func _update_property() -> void:
	if _suppress_update:
		return
	var raw: Variant = get_edited_object().get(get_edited_property())
	var value: Array[StringName] = []
	if raw is Array:
		for entry in raw:
			value.append(StringName(entry))
	_current_value = value
	_refresh_list()
	_refresh_dropdown()


func _refresh_list() -> void:
	for child in _list.get_children():
		child.queue_free()
	_empty_hint.visible = _current_value.is_empty()
	for bone_name: StringName in _current_value:
		var row := HBoxContainer.new()
		row.add_theme_constant_override(&"separation", 4)
		var label := Label.new()
		label.text = String(bone_name)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		var remove := Button.new()
		remove.text = "×"
		remove.tooltip_text = "Remove %s" % bone_name
		remove.pressed.connect(_on_remove_bone.bind(bone_name))
		row.add_child(remove)
		_list.add_child(row)


# Builds the OptionButton items: placeholder at index 0 ("Add Bone …"
# or a hint label), then every skeleton bone not already in the list.
# Sorted by bone hierarchy index for stable, parent-before-child order
# rather than alphabetical (which scatters fingers/toes confusingly).
func _refresh_dropdown() -> void:
	_add_button.clear()
	var skel: Skeleton3D = _find_skeleton()
	if skel == null:
		_add_button.add_item("(no Marionette selected)")
		_add_button.disabled = true
		return
	_add_button.disabled = false
	_add_button.add_item("+ Add Bone…")
	_add_button.set_item_disabled(0, true)
	var added: int = 0
	for i: int in skel.get_bone_count():
		var bn: StringName = StringName(skel.get_bone_name(i))
		if _current_value.has(bn):
			continue
		_add_button.add_item(String(bn))
		added += 1
	if added == 0:
		_add_button.set_item_text(0, "(every bone already in list)")


# Finds the Skeleton3D the active Marionette resolves to. Walks the
# editor's scene-tree selection looking for a Marionette; falls back to
# null if none. Resolved per-call so the picker tracks the user's
# selection without needing change signals.
func _find_skeleton() -> Skeleton3D:
	if not Engine.is_editor_hint():
		return null
	var selection := EditorInterface.get_selection()
	if selection == null:
		return null
	for node: Node in selection.get_selected_nodes():
		if node is Marionette:
			return (node as Marionette).resolve_skeleton()
	return null


func _on_add_bone_selected(idx: int) -> void:
	if idx <= 0:
		return  # placeholder
	var bone_name: StringName = StringName(_add_button.get_item_text(idx))
	# Reset the dropdown selection so the same bone can be re-picked
	# after a remove (Godot's OptionButton doesn't fire item_selected on
	# the same index twice).
	_add_button.select(0)
	var new_value := _current_value.duplicate()
	new_value.append(bone_name)
	_emit_value(new_value)


func _on_remove_bone(bone_name: StringName) -> void:
	var new_value := _current_value.duplicate()
	new_value.erase(bone_name)
	_emit_value(new_value)


# Pushes the new array via emit_changed and triggers an immediate UI
# rebuild. emit_changed runs through the inspector's undo/redo stack so
# the user can Ctrl+Z each add/remove.
func _emit_value(new_value: Array[StringName]) -> void:
	_suppress_update = true
	emit_changed(get_edited_property(), new_value)
	_suppress_update = false
	_current_value = new_value
	_refresh_list()
	_refresh_dropdown()
