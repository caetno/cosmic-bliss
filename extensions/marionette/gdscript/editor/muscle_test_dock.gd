@tool
class_name MarionetteMuscleTestDock
extends VBoxContainer

# Right-dock muscle-test panel (P4.1–P4.3 + P4.6).
#
# Auto-targets the active Marionette via EditorSelection: walks up the parent
# chain from selected nodes; first Marionette ancestor wins. Lists every
# MarionetteBone child of that ragdoll grouped by anatomical region
# (MarionetteBoneRegion). Each region is a collapsible Button + VBoxContainer
# pair. Reuses MarionetteBoneSliders unchanged for per-bone UI.
#
# Refresh button is the deliberate way to pick up a rebuilt ragdoll —
# selection_changed doesn't fire when the same Marionette is reselected
# after Build Ragdoll, and we don't try to outsmart that here.
#
# Lifecycle: each MarionetteBoneSliders snapshots rest in _ready and restores
# in _exit_tree. Replacing the dock contents (queue_free) propagates
# _exit_tree to every widget, so rest poses always restore.

const _DOCK_TITLE: String = "Muscle Test"

# Dock mode (P5.8 / slice 8a). Preview = P4 kinematic-write authoring. Ragdoll
# Test = physics active, sliders drive SPD via `Marionette.set_bone_target`
# (slice 8c wires the slider rewire; 8a only gates the kinematic write and
# flips physics state). Mode lives on the dock — runtime stays mode-agnostic
# so the public Marionette API doesn't pick up an authoring concern.
enum Mode { SKELETON3D_PREVIEW, RAGDOLL_TEST }

var _selection: EditorSelection
var _active_marionette: Marionette
var _header: Label
var _mode_option: OptionButton
var _reset_all_btn: Button
var _refresh_btn: Button
var _scroll: ScrollContainer
var _content: VBoxContainer
var _mode: int = Mode.SKELETON3D_PREVIEW
# Cached pre-entry gravity_scale so Ragdoll-Test exit restores whatever the
# user had dialed in. We always set zero-g on entry; the value at exit is
# whatever Ragdoll Test left it at, but the user's intent for Preview was
# the pre-entry number.
var _saved_gravity_scale: float = 1.0
# Whether *we* built the ragdoll on entry. Determines whether exit calls
# `clear_ragdoll`. If the user had already built the ragdoll, we leave it
# in place (only restore mode/gravity, not the simulator hierarchy).
var _built_ragdoll_on_entry: bool = false
# Bone widgets currently mounted, keyed by bone_name.
var _bone_widgets: Dictionary[StringName, MarionetteBoneSliders] = {}
# Cached BoneEntry per mounted widget — read every macro frame so we don't
# walk the bone graph just to reach ROM. Keyed by bone_name.
var _bone_entries: Dictionary[StringName, BoneEntry] = {}
# Current macro slider values, keyed by macro key. Floats in [-1, 1].
var _macro_values: Dictionary[StringName, float] = {}
# Macro slider widgets, keyed by macro key. Used by Reset All.
var _macro_sliders: Dictionary[StringName, HSlider] = {}
# Per-macro value-readout labels. set_value_no_signal skips the connected
# callback that normally updates these, so Reset All has to refresh them
# explicitly — otherwise sliders snap to 0 but the readout still shows the
# pre-reset value, which is the most-reported "Reset All didn't reset" cue.
var _macro_value_labels: Dictionary[StringName, Label] = {}


func _init() -> void:
	name = _DOCK_TITLE
	custom_minimum_size = Vector2(280, 0)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build_chrome()


func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		return
	_selection = EditorInterface.get_selection()
	if _selection != null and not _selection.selection_changed.is_connected(_on_selection_changed):
		_selection.selection_changed.connect(_on_selection_changed)
	_on_selection_changed()


func _exit_tree() -> void:
	if _selection != null and _selection.selection_changed.is_connected(_on_selection_changed):
		_selection.selection_changed.disconnect(_on_selection_changed)
	_selection = null


func _build_chrome() -> void:
	_header = Label.new()
	_header.text = "(no Marionette selected)"
	add_child(_header)

	# Mode toggle: Skeleton3D Preview (P4 kinematic authoring) vs Ragdoll Test
	# (physics + SPD-driven targets). Lives in the dock header so it's
	# discoverable while a Marionette is selected.
	var mode_row := HBoxContainer.new()
	add_child(mode_row)
	var mode_label := Label.new()
	mode_label.text = "Mode:"
	mode_row.add_child(mode_label)
	_mode_option = OptionButton.new()
	_mode_option.add_item("Skeleton3D Preview", Mode.SKELETON3D_PREVIEW)
	_mode_option.add_item("Ragdoll Test", Mode.RAGDOLL_TEST)
	_mode_option.selected = 0
	_mode_option.tooltip_text = (
			"Skeleton3D Preview: sliders write the skeleton pose directly.\n"
			+ "Ragdoll Test: physics active, sliders drive SPD targets.")
	_mode_option.item_selected.connect(_on_mode_changed)
	_mode_option.disabled = true
	mode_row.add_child(_mode_option)

	var btn_row := HBoxContainer.new()
	add_child(btn_row)

	_refresh_btn = Button.new()
	_refresh_btn.text = "Refresh"
	_refresh_btn.tooltip_text = "Re-read bones (use after Build Ragdoll)"
	_refresh_btn.pressed.connect(_on_refresh_pressed)
	_refresh_btn.disabled = true
	btn_row.add_child(_refresh_btn)

	_reset_all_btn = Button.new()
	_reset_all_btn.text = "Reset All to Rest"
	_reset_all_btn.pressed.connect(_on_reset_all_pressed)
	_reset_all_btn.disabled = true
	btn_row.add_child(_reset_all_btn)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_scroll)

	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_content)


func _on_selection_changed() -> void:
	if _selection == null:
		return
	var found: Marionette = null
	for n: Node in _selection.get_selected_nodes():
		var m: Marionette = _resolve_marionette(n)
		if m != null:
			found = m
			break
	_set_active_marionette(found)


func _on_refresh_pressed() -> void:
	if _active_marionette == null:
		return
	_clear_content()
	_populate_for(_active_marionette)


func _on_reset_all_pressed() -> void:
	for slider: HSlider in _macro_sliders.values():
		if is_instance_valid(slider):
			slider.set_value_no_signal(0.0)
	for label: Label in _macro_value_labels.values():
		if is_instance_valid(label):
			label.text = "0.00"
	_macro_values.clear()
	for widget: MarionetteBoneSliders in _bone_widgets.values():
		if is_instance_valid(widget):
			widget.reset_to_rest()


# Walks up the parent chain to find an enclosing Marionette node. Lets the
# user select any descendant (a MarionetteBone, the Skeleton3D, etc.) and
# still target the right ragdoll.
static func _resolve_marionette(n: Node) -> Marionette:
	var cur: Node = n
	while cur != null:
		if cur is Marionette:
			return cur as Marionette
		cur = cur.get_parent()
	return null


func _set_active_marionette(m: Marionette) -> void:
	if _active_marionette == m:
		return
	# Always exit Ragdoll Test before switching Marionettes — otherwise the
	# previous character is left with physics on and a dangling tether (8b).
	if _mode == Mode.RAGDOLL_TEST and _active_marionette != null:
		_exit_mode(Mode.RAGDOLL_TEST)
		_mode = Mode.SKELETON3D_PREVIEW
		if _mode_option != null:
			_mode_option.select(0)
	_clear_content()
	_active_marionette = m
	if m == null:
		_header.text = "(no Marionette selected)"
		_reset_all_btn.disabled = true
		_refresh_btn.disabled = true
		if _mode_option != null:
			_mode_option.disabled = true
		return
	_header.text = "Active: %s" % m.name
	_reset_all_btn.disabled = false
	_refresh_btn.disabled = false
	if _mode_option != null:
		_mode_option.disabled = false
	_populate_for(m)


# Public for slice 8c tests + future callers. Tracks current dock mode.
func get_mode() -> int:
	return _mode


func _on_mode_changed(idx: int) -> void:
	var new_mode: int = _mode_option.get_item_id(idx)
	if new_mode == _mode:
		return
	var old_mode: int = _mode
	# Exit old before entering new — gravity restore and clear_ragdoll need
	# to run before we tear into build_ragdoll for the new mode.
	_exit_mode(old_mode)
	_mode = new_mode
	_enter_mode(new_mode)
	_propagate_mode_to_widgets()


func _propagate_mode_to_widgets() -> void:
	for widget: MarionetteBoneSliders in _bone_widgets.values():
		if is_instance_valid(widget):
			widget.set_mode(_mode)


# Entering Ragdoll Test: build ragdoll if needed, snapshot gravity, zero-g,
# then propagate the mode bit to per-bone widgets (suppresses the kinematic
# write — slice 8c adds the SPD-target rewire). Tether/strength slider/seed
# come in 8b/8c.
#
# Entering Preview: no-op (the prior exit already restored the skeleton).
func _enter_mode(mode: int) -> void:
	if _active_marionette == null:
		return
	match mode:
		Mode.RAGDOLL_TEST:
			_built_ragdoll_on_entry = false
			# Re-use the simulator if the user already built the ragdoll; otherwise
			# build now. Validator (slice 7) runs as part of build_ragdoll.
			if _find_simulator(_active_marionette) == null:
				_active_marionette.build_ragdoll()
				_built_ragdoll_on_entry = true
				# Build wipes existing widget bindings — repopulate so 8c can
				# seed SPD targets and tests see live widgets.
				_clear_content()
				_populate_for(_active_marionette)
			_saved_gravity_scale = _active_marionette.get_gravity_scale()
			_active_marionette.set_gravity_scale(0.0)
		Mode.SKELETON3D_PREVIEW:
			pass


# Exiting Ragdoll Test (P5.9 fold-in): clear the ragdoll if we built it on
# entry, restore the user's gravity_scale, and reset every widget back to
# rest pose. Rest-pose guard contract: leaving Ragdoll Test never leaves
# the skeleton in physics-driven state.
func _exit_mode(mode: int) -> void:
	if _active_marionette == null:
		return
	match mode:
		Mode.RAGDOLL_TEST:
			# Restore gravity first — clear_ragdoll frees the registered bones,
			# but set_gravity_scale only touches what's still alive.
			_active_marionette.set_gravity_scale(_saved_gravity_scale)
			if _built_ragdoll_on_entry:
				_active_marionette.clear_ragdoll()
				_built_ragdoll_on_entry = false
				# Tear down widgets too — the bones they pointed at are gone.
				_clear_content()
				_populate_for(_active_marionette)
			else:
				# Ragdoll stays built. Reset all slider widgets back to rest;
				# they restore Skeleton3D pose via the kinematic path (now
				# re-enabled because mode flipped back to Preview before this
				# call propagates).
				for widget: MarionetteBoneSliders in _bone_widgets.values():
					if is_instance_valid(widget):
						widget.reset_to_rest()
		Mode.SKELETON3D_PREVIEW:
			pass


func _populate_for(m: Marionette) -> void:
	var sim := _find_simulator(m)
	if sim == null:
		var lbl := Label.new()
		lbl.text = "(ragdoll not built — press 'Build Ragdoll' on the Marionette)"
		_content.add_child(lbl)
		return

	# Bucket MarionetteBone children by region.
	var by_region: Dictionary[int, Array] = {}
	for child: Node in sim.get_children():
		if child is MarionetteBone:
			var bone: MarionetteBone = child as MarionetteBone
			var region: int = MarionetteBoneRegion.region_for(StringName(bone.bone_name))
			if not by_region.has(region):
				by_region[region] = []
			by_region[region].append(bone)

	# Sort each region's bones alphabetically for deterministic order.
	for region: int in by_region.keys():
		var bones: Array = by_region[region]
		bones.sort_custom(func(a: MarionetteBone, b: MarionetteBone) -> bool:
			return a.bone_name < b.bone_name)

	# Macros first — they drive every bone in the ragdoll, not a single region.
	_add_macro_section()

	# Render in canonical region order; skip empty regions.
	for region: int in MarionetteBoneRegion.ORDER:
		if not by_region.has(region):
			continue
		var bones: Array = by_region[region]
		if bones.is_empty():
			continue
		_add_region_section(region, bones)


# Renders one collapsible section per macro group at the top of the dock.
# Group order matches MarionetteMacroPresets.GROUP_ORDER (Unity-style first,
# then anatomical-axis macros for All / Arms / Legs / Hands / Feet / Body).
# Within a section: one slider per macro key, value [-1, 1] composes through
# every mounted bone widget at the bone-slider's _apply_pose path. Slider
# step is 0.01 — fine enough to scrub, coarse enough to dodge per-pixel pose
# updates. Unity section starts expanded; the anatomical sections collapse by
# default so the dock chrome doesn't dominate the viewport.
func _add_macro_section() -> void:
	# All macro subsections start collapsed — at 7 groups with up to 7 sliders
	# each, expanded-by-default fills the dock before the user picks a region
	# they actually want to drive.
	for group: StringName in MarionetteMacroPresets.GROUP_ORDER:
		var keys: Array = MarionetteMacroPresets.keys_for_group(group)
		if keys.is_empty():
			continue
		_add_macro_subsection(group, keys, false)


func _add_macro_subsection(group: StringName, keys: Array, expanded: bool) -> void:
	var label_text: String = MarionetteMacroPresets.group_label_for(group)
	var section := VBoxContainer.new()
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var header_btn := Button.new()
	header_btn.toggle_mode = true
	header_btn.button_pressed = expanded
	header_btn.flat = true
	header_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header_btn.text = _macro_section_label(label_text, keys.size(), expanded)
	section.add_child(header_btn)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.visible = expanded
	section.add_child(content)

	header_btn.toggled.connect(func(pressed: bool) -> void:
		content.visible = pressed
		header_btn.text = _macro_section_label(label_text, keys.size(), pressed))

	for key: StringName in keys:
		_add_macro_row(content, key)
		var divider := HSeparator.new()
		content.add_child(divider)

	_content.add_child(section)


static func _macro_section_label(label_text: String, count: int, expanded: bool) -> String:
	return "%s Macros — %s (%d)" % ["▼" if expanded else "▶", label_text, count]


func _add_macro_row(parent: VBoxContainer, key: StringName) -> void:
	var label := Label.new()
	label.text = MarionetteMacroPresets.label_for(key)
	parent.add_child(label)

	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 4)
	parent.add_child(row)

	var value_label := Label.new()
	value_label.text = "0.00"
	value_label.custom_minimum_size = Vector2(38, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value_label)

	var slider := HSlider.new()
	slider.min_value = -1.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.value = 0.0
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(60, 0)
	slider.value_changed.connect(_on_macro_changed.bind(key, value_label))
	row.add_child(slider)

	_macro_sliders[key] = slider
	_macro_value_labels[key] = value_label


func _on_macro_changed(v: float, key: StringName, value_label: Label) -> void:
	value_label.text = "%.2f" % v
	if absf(v) < 0.0001:
		_macro_values.erase(key)
	else:
		_macro_values[key] = v
	_apply_macros_to_bones()


# Recomputes the per-bone anatomical target from the current macro slider
# state and writes it into every mounted bone widget's per-axis sliders.
# Macros remote-control the per-bone sliders (no separate macro layer); the
# slider knobs visibly move, then the existing slider→pose path applies.
# Cheap: ~80 bones × 7 macros of dictionary lookups per slider step, well
# under a frame.
func _apply_macros_to_bones() -> void:
	for bone_name: StringName in _bone_widgets.keys():
		var widget: MarionetteBoneSliders = _bone_widgets[bone_name]
		if not is_instance_valid(widget):
			continue
		var entry: BoneEntry = _bone_entries.get(bone_name)
		if entry == null:
			continue
		var offset: Vector3 = MarionetteMacroPresets.compose_offset(
				bone_name, entry.rom_min, entry.rom_max, _macro_values)
		widget.set_anatomical_target(entry.rest_anatomical_offset + offset)


func _add_region_section(region: int, bones: Array) -> void:
	var label_text: String = MarionetteBoneRegion.label_for(region)
	var section := VBoxContainer.new()
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var header_btn := Button.new()
	header_btn.toggle_mode = true
	header_btn.button_pressed = false  # start collapsed
	header_btn.flat = true
	header_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header_btn.text = _section_label(label_text, bones.size(), false)
	section.add_child(header_btn)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.visible = false
	section.add_child(content)

	header_btn.toggled.connect(func(pressed: bool) -> void:
		content.visible = pressed
		header_btn.text = _section_label(label_text, bones.size(), pressed))

	for bone: MarionetteBone in bones:
		var widget := MarionetteBoneSliders.new(bone)
		content.add_child(widget)
		var key := StringName(bone.bone_name)
		_bone_widgets[key] = widget
		if bone.bone_entry != null:
			_bone_entries[key] = bone.bone_entry

		var divider := HSeparator.new()
		content.add_child(divider)

	_content.add_child(section)


static func _section_label(label_text: String, count: int, expanded: bool) -> String:
	return "%s %s (%d)" % ["▼" if expanded else "▶", label_text, count]


func _clear_content() -> void:
	# queue_free propagates _exit_tree to each MarionetteBoneSliders → restores
	# rest pose for every bone before the dock loses references.
	for child: Node in _content.get_children():
		child.queue_free()
	_bone_widgets.clear()
	_bone_entries.clear()
	_macro_sliders.clear()
	_macro_value_labels.clear()
	_macro_values.clear()


func _find_simulator(m: Marionette) -> PhysicalBoneSimulator3D:
	var skel: Skeleton3D = m.resolve_skeleton()
	if skel == null:
		return null
	for child: Node in skel.get_children():
		if child is PhysicalBoneSimulator3D:
			return child as PhysicalBoneSimulator3D
	return null
