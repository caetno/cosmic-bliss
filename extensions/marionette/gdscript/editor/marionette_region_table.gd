@tool
class_name MarionetteRegionTable
extends VBoxContainer

# Slice 7: read-only Tune & Test region table. Hosted at the bottom of
# the Marionette inspector by MarionetteInspectorPlugin. Renders one
# row per derived region (hard from BoneProfile, soft from JiggleProfile)
# showing the averaged spring/jiggle params for the bones in that
# region.
#
# No edit controls yet — slice 8 swaps the labels for sliders and adds
# the per-region Active checkbox + live writes.
#
# Refresh strategy: re-derive regions on _process every frame. Cheap
# (78 + 4 bones, dictionary iteration) and avoids needing change signals
# from BoneProfile / JiggleProfile / individual entries. Only ticks
# while the inspector is open on a Marionette (Godot frees this Control
# when the user selects something else).

var marionette: Marionette = null

var _grid: GridContainer
const _COLUMNS: int = 4   # name, n, stiffness, damping
const _SOFT_DIVIDER_TEXT: String = "— soft regions —"


func _init() -> void:
	add_theme_constant_override(&"separation", 4)
	var heading := Label.new()
	heading.text = "Region tuning  (read-only — slice 7)"
	heading.add_theme_color_override(&"font_color", Color(0.6, 0.7, 0.9))
	add_child(heading)

	_grid = GridContainer.new()
	_grid.columns = _COLUMNS
	_grid.add_theme_constant_override(&"h_separation", 12)
	_grid.add_theme_constant_override(&"v_separation", 2)
	add_child(_grid)


func _process(_delta: float) -> void:
	if marionette == null or not is_instance_valid(marionette):
		return
	_refresh()


func _refresh() -> void:
	for child in _grid.get_children():
		child.queue_free()
	# Header row.
	_add_header("Region")
	_add_header("n")
	_add_header("stiffness (X / k)")
	_add_header("damping (X / c)")

	var regions: Array[MarionetteRegionGrouping.Region] = MarionetteRegionGrouping.derive(
			marionette.bone_profile, marionette.jiggle_profile)
	if regions.is_empty():
		_add_label("(no regions — calibrate the bone profile to populate)", _COLUMNS)
		return

	var soft_started: bool = false
	for r: MarionetteRegionGrouping.Region in regions:
		if r.kind == MarionetteRegionGrouping.Region.Kind.SOFT and not soft_started:
			# Visual divider before the first soft region.
			_add_label(_SOFT_DIVIDER_TEXT, _COLUMNS, Color(0.5, 0.5, 0.5))
			soft_started = true
		_add_label(String(r.name))
		_add_label(str(r.bones.size()))
		var avg: Vector2 = _averaged_params_for_region(r)
		_add_label(_format_param(avg.x, r.kind))
		_add_label(_format_param(avg.y, r.kind))


# Returns averaged (stiffness, damping) for the region. For HARD regions:
# the X-axis (flex) component of BoneEntry.spring_stiffness/damping —
# that's the primary tuning signal; Y/Z averaging would mix locked
# axes (Hinge Y/Z, Saddle Y) into the mean. For SOFT regions:
# reach_seconds, damping_ratio.
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
			# Fall back to profile defaults — same resolution as the
			# JiggleProfile.params_for() path.
			reach_sum += marionette.jiggle_profile.default_reach_seconds
			zeta_sum += marionette.jiggle_profile.default_damping_ratio
		else:
			reach_sum += entry.reach_seconds
			zeta_sum += entry.damping_ratio
		n += 1
	if n == 0:
		return Vector2.ZERO
	return Vector2(reach_sum / n, zeta_sum / n)


func _format_param(value: float, kind: int) -> String:
	if kind == MarionetteRegionGrouping.Region.Kind.HARD:
		# Stiffness in Jolt-direct units (0–4 typical) — two decimals.
		return "%.2f" % value
	# Soft-region params: reach in seconds, damping_ratio dimensionless.
	# Both small numbers; same format works.
	return "%.2f" % value


func _add_header(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override(&"font_color", Color(0.7, 0.7, 0.7))
	_grid.add_child(l)


func _add_label(text: String, span: int = 1, color: Color = Color(1, 1, 1)) -> void:
	var l := Label.new()
	l.text = text
	if color != Color(1, 1, 1):
		l.add_theme_color_override(&"font_color", color)
	_grid.add_child(l)
	# Quick + dirty span: fill remaining columns of the row with empty
	# Labels so the next "real" cell starts on a fresh row.
	for i: int in range(span - 1):
		_grid.add_child(Label.new())
