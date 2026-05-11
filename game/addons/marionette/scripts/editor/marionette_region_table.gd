@tool
class_name MarionetteRegionTable
extends VBoxContainer

# Slice 8: editable Tune & Test region table. Each row offers two
# SpinBoxes (stiffness/damping for hard regions, reach_seconds/
# damping_ratio for soft) plus an Active checkbox. Edits write through
# to the underlying BoneEntry / JiggleEntry resources AND to any live
# spawned bones, so changes are visible during play without rebuild.
#
# Persistence policy: writes are pushed onto the resource immediately
# (so Ctrl+S persists). The user is responsible for explicit saves —
# we don't auto-save, mirroring the Calibrate flow.
#
# Active checkbox: when off, the bones in the region get
# joint_constraints/<axis>/angular_spring_enabled = false on every axis
# (live bones only — the resource's spring_stiffness/damping are
# untouched, so re-enabling restores the tuned values). For jiggle
# bones, "off" sets stiffness=damping=0 on the live JiggleBone (same
# preserve-the-resource semantic).

var marionette: Marionette = null

var _grid: GridContainer
const _COLUMNS: int = 5   # name, n, stiffness/reach, damping/zeta, active
const _SOFT_DIVIDER_TEXT: String = "— soft regions —"

# Region name -> Active flag. Persisted in widget memory only — toggling
# off doesn't write to the resource (the user can save to keep tuning;
# Active is a per-session diagnostic tool).
var _region_active: Dictionary[StringName, bool] = {}


func _init() -> void:
	add_theme_constant_override(&"separation", 4)
	var heading := Label.new()
	heading.text = "Region tuning  (live writes during play)"
	heading.add_theme_color_override(&"font_color", Color(0.6, 0.7, 0.9))
	add_child(heading)

	_grid = GridContainer.new()
	_grid.columns = _COLUMNS
	_grid.add_theme_constant_override(&"h_separation", 12)
	_grid.add_theme_constant_override(&"v_separation", 2)
	add_child(_grid)


# Re-derive + rebuild controls every frame is overkill — only do it on
# selection change or after a rebuild. Track a hash of the regions list
# and only rebuild when it changes.
var _last_signature: String = ""

func _process(_delta: float) -> void:
	if marionette == null or not is_instance_valid(marionette):
		return
	var sig: String = _signature()
	if sig != _last_signature:
		_last_signature = sig
		_refresh()


# Signature compresses (region_name, bone_count) pairs into a string —
# detects "regions added / removed / membership changed" without
# tracking every spring value (those don't need a UI rebuild; SpinBoxes
# track their own value via the bound resource).
func _signature() -> String:
	if marionette.bone_profile == null and marionette.jiggle_profile == null:
		return ""
	var regions: Array[MarionetteRegionGrouping.Region] = MarionetteRegionGrouping.derive(
			marionette.bone_profile, marionette.jiggle_profile)
	var parts: PackedStringArray = []
	for r: MarionetteRegionGrouping.Region in regions:
		parts.append("%s:%d" % [r.name, r.bones.size()])
	return ",".join(parts)


func _refresh() -> void:
	for child in _grid.get_children():
		child.queue_free()
	# Header row.
	_add_label("Region", true)
	_add_label("n", true)
	_add_label("stiffness / reach", true)
	_add_label("damping / ζ", true)
	_add_label("active", true)

	var regions: Array[MarionetteRegionGrouping.Region] = MarionetteRegionGrouping.derive(
			marionette.bone_profile, marionette.jiggle_profile)
	if regions.is_empty():
		_add_label("(no regions — calibrate the bone profile to populate)")
		for i: int in range(_COLUMNS - 1):
			_grid.add_child(Label.new())
		return

	var soft_started: bool = false
	for r: MarionetteRegionGrouping.Region in regions:
		if r.kind == MarionetteRegionGrouping.Region.Kind.SOFT and not soft_started:
			_add_label(_SOFT_DIVIDER_TEXT, false, Color(0.5, 0.5, 0.5))
			for i: int in range(_COLUMNS - 1):
				_grid.add_child(Label.new())
			soft_started = true
		_add_region_row(r)


func _add_region_row(r: MarionetteRegionGrouping.Region) -> void:
	# Col 0–1: name + bone count.
	_add_label(String(r.name))
	_add_label(str(r.bones.size()))

	# Cols 2–3: SpinBoxes for the two tunable params. Range/step depend
	# on whether the region is hard (Jolt-spring units) or soft (seconds /
	# damping ratio).
	var avg: Vector2 = _averaged_params_for_region(r)
	if r.kind == MarionetteRegionGrouping.Region.Kind.HARD:
		_add_spinbox(0.0, 10.0, 0.05, avg.x,
				_on_hard_stiffness_changed.bind(r))
		_add_spinbox(0.0, 10.0, 0.05, avg.y,
				_on_hard_damping_changed.bind(r))
	else:
		_add_spinbox(0.05, 2.0, 0.01, avg.x,
				_on_soft_reach_changed.bind(r))
		_add_spinbox(0.0, 2.0, 0.01, avg.y,
				_on_soft_damping_changed.bind(r))

	# Col 4: Active toggle. Defaults true; flipping off zeros the spring
	# on every live bone in the region without touching the resource.
	var cb := CheckBox.new()
	if not _region_active.has(r.name):
		_region_active[r.name] = true
	cb.button_pressed = _region_active[r.name]
	cb.toggled.connect(_on_region_active_toggled.bind(r))
	_grid.add_child(cb)


# --- Slider handlers ---

func _on_hard_stiffness_changed(value: float, r: MarionetteRegionGrouping.Region) -> void:
	if marionette.bone_profile == null:
		return
	for bone_name: StringName in r.bones:
		var entry: BoneEntry = marionette.bone_profile.bones.get(bone_name)
		if entry == null:
			continue
		# X-axis only (the row's display value is the X average). Y/Z
		# preserved so Ball/Saddle archetypes keep their per-axis pattern.
		entry.spring_stiffness.x = value
	marionette.bone_profile.emit_changed()
	_apply_to_live_bones(r)


func _on_hard_damping_changed(value: float, r: MarionetteRegionGrouping.Region) -> void:
	if marionette.bone_profile == null:
		return
	for bone_name: StringName in r.bones:
		var entry: BoneEntry = marionette.bone_profile.bones.get(bone_name)
		if entry == null:
			continue
		entry.spring_damping.x = value
	marionette.bone_profile.emit_changed()
	_apply_to_live_bones(r)


func _on_soft_reach_changed(value: float, r: MarionetteRegionGrouping.Region) -> void:
	_set_soft_param(r, value, NAN)
	_apply_to_live_jiggle(r)


func _on_soft_damping_changed(value: float, r: MarionetteRegionGrouping.Region) -> void:
	_set_soft_param(r, NAN, value)
	_apply_to_live_jiggle(r)


# Writes (reach, damping_ratio) onto every JiggleEntry in the region.
# NAN on a component means "leave that param alone". Creates an entry
# from the profile defaults if the bone has no explicit JiggleEntry yet.
func _set_soft_param(r: MarionetteRegionGrouping.Region, reach: float, zeta: float) -> void:
	if marionette.jiggle_profile == null:
		marionette.jiggle_profile = JiggleProfile.new()
	for bone_name: StringName in r.bones:
		var entry: JiggleEntry = marionette.jiggle_profile.entries.get(bone_name)
		if entry == null:
			entry = JiggleEntry.new()
			entry.reach_seconds = marionette.jiggle_profile.default_reach_seconds
			entry.damping_ratio = marionette.jiggle_profile.default_damping_ratio
			marionette.jiggle_profile.entries[bone_name] = entry
		if not is_nan(reach):
			entry.reach_seconds = reach
		if not is_nan(zeta):
			entry.damping_ratio = zeta
	marionette.jiggle_profile.emit_changed()


func _on_region_active_toggled(pressed: bool, r: MarionetteRegionGrouping.Region) -> void:
	_region_active[r.name] = pressed
	if r.kind == MarionetteRegionGrouping.Region.Kind.HARD:
		_apply_to_live_bones(r)
	else:
		_apply_to_live_jiggle(r)


# --- Live-bone application ---

# For each MarionetteBone in the region, push the entry's spring values
# (or zero them when Active is off) onto the live joint_constraints. No
# rebuild needed — Jolt picks up the new values at the next physics step.
func _apply_to_live_bones(r: MarionetteRegionGrouping.Region) -> void:
	var sim: PhysicalBoneSimulator3D = marionette._find_simulator()
	if sim == null:
		return
	var active: bool = _region_active.get(r.name, true)
	for bone_name: StringName in r.bones:
		var bone: MarionetteBone = _find_marionette_bone(sim, bone_name)
		if bone == null:
			continue
		var entry: BoneEntry = marionette.bone_profile.bones.get(bone_name) if marionette.bone_profile != null else null
		if entry == null:
			continue
		for i: int in range(3):
			var axis: String = ["x", "y", "z"][i]
			var k: float = entry.spring_stiffness[i] if active else 0.0
			var c: float = entry.spring_damping[i] if active else 0.0
			var on: bool = k > 0.0
			bone.set("joint_constraints/%s/angular_spring_enabled" % axis, on)
			if on:
				bone.set("joint_constraints/%s/angular_spring_stiffness" % axis, k)
				bone.set("joint_constraints/%s/angular_spring_damping" % axis, c)


# For each JiggleBone in the region, recompute stiffness/damping from
# the current entry (or zero when Active off). JiggleBone reads
# stiffness/damping each tick, so writes take effect immediately.
func _apply_to_live_jiggle(r: MarionetteRegionGrouping.Region) -> void:
	var sim: PhysicalBoneSimulator3D = marionette._find_simulator()
	if sim == null:
		return
	var active: bool = _region_active.get(r.name, true)
	for bone_name: StringName in r.bones:
		var jb: JiggleBone = _find_jiggle_bone(sim, bone_name)
		if jb == null:
			continue
		if not active:
			jb.stiffness = 0.0
			jb.damping = 0.0
			continue
		var reach: float = marionette.jiggle_profile.default_reach_seconds
		var zeta: float = marionette.jiggle_profile.default_damping_ratio
		if marionette.jiggle_profile != null and marionette.jiggle_profile.entries.has(bone_name):
			var entry: JiggleEntry = marionette.jiggle_profile.entries[bone_name]
			reach = entry.reach_seconds
			zeta = entry.damping_ratio
		var omega: float = TAU / max(reach, 0.001)
		jb.stiffness = jb.mass * omega * omega
		jb.damping = 2.0 * zeta * omega * jb.mass


static func _find_marionette_bone(sim: PhysicalBoneSimulator3D, bone_name: StringName) -> MarionetteBone:
	for child: Node in sim.get_children():
		if child is MarionetteBone and not (child is JiggleBone) \
				and StringName((child as MarionetteBone).bone_name) == bone_name:
			return child
	return null


static func _find_jiggle_bone(sim: PhysicalBoneSimulator3D, bone_name: StringName) -> JiggleBone:
	for child: Node in sim.get_children():
		if child is JiggleBone and StringName((child as JiggleBone).bone_name) == bone_name:
			return child
	return null


# --- Averaging (display) ---

func _averaged_params_for_region(r: MarionetteRegionGrouping.Region) -> Vector2:
	if r.kind == MarionetteRegionGrouping.Region.Kind.HARD:
		return _averaged_hard(r)
	return _averaged_soft(r)


func _averaged_hard(r: MarionetteRegionGrouping.Region) -> Vector2:
	if marionette.bone_profile == null:
		return Vector2.ZERO
	var k_sum: float = 0.0
	var c_sum: float = 0.0
	var n: int = 0
	for bone_name: StringName in r.bones:
		var entry: BoneEntry = marionette.bone_profile.bones.get(bone_name)
		if entry == null:
			continue
		k_sum += entry.spring_stiffness.x
		c_sum += entry.spring_damping.x
		n += 1
	if n == 0:
		return Vector2.ZERO
	return Vector2(k_sum / n, c_sum / n)


func _averaged_soft(r: MarionetteRegionGrouping.Region) -> Vector2:
	if marionette.jiggle_profile == null:
		return Vector2.ZERO
	var reach_sum: float = 0.0
	var zeta_sum: float = 0.0
	var n: int = 0
	for bone_name: StringName in r.bones:
		var entry: JiggleEntry = marionette.jiggle_profile.entries.get(bone_name)
		if entry == null:
			reach_sum += marionette.jiggle_profile.default_reach_seconds
			zeta_sum += marionette.jiggle_profile.default_damping_ratio
		else:
			reach_sum += entry.reach_seconds
			zeta_sum += entry.damping_ratio
		n += 1
	if n == 0:
		return Vector2.ZERO
	return Vector2(reach_sum / n, zeta_sum / n)


# --- Cell helpers ---

func _add_label(text: String, header: bool = false, color: Color = Color(1, 1, 1)) -> void:
	var l := Label.new()
	l.text = text
	if header:
		l.add_theme_color_override(&"font_color", Color(0.7, 0.7, 0.7))
	elif color != Color(1, 1, 1):
		l.add_theme_color_override(&"font_color", color)
	_grid.add_child(l)


func _add_spinbox(min_v: float, max_v: float, step: float, value: float, on_changed: Callable) -> void:
	var sb := SpinBox.new()
	sb.min_value = min_v
	sb.max_value = max_v
	sb.step = step
	sb.value = value
	sb.custom_minimum_size = Vector2(80, 0)
	sb.value_changed.connect(on_changed)
	_grid.add_child(sb)
