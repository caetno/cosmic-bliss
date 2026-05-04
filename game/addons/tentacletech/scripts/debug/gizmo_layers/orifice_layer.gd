@tool
extends MeshInstance3D
## Orifice rim layer (Phase 5 slice 5A) — one ImmediateMesh rebuilt per
## _process from `Orifice.get_rim_loop_state(loop_index)` snapshots. Pulls,
## never pushes — the C++ Orifice does not know this overlay exists.
##
## Per loop:
##  - Rim particle current positions as small 3-axis crosses (white).
##  - Closed-loop segments between consecutive rim particles (cyan).
##  - Per-particle authored rest position as a small mint-green dot
##    drawn behind the current cross — deformation reads as the gap
##    between current and rest.
##
## Multi-loop: every loop draws in the same colors. Visual disambiguation
## (per-loop hue, etc.) is reserved for Phase 5 slice 5C / Phase 8.

const _Colors := preload("res://addons/tentacletech/scripts/debug/colors.gd")

const RIM_PARTICLE_SIZE := 0.012
const REST_MARKER_SIZE := 0.006
const HOST_BONE_MARKER_SIZE := 0.018
const ENTRY_INTERACTION_MARKER_SIZE := 0.014
const ENTRY_INTERACTION_AXIS_MIN_LENGTH := 0.05
const HOST_BODY_MARKER_SIZE := 0.022
# Slice 5C-C — friction arrow scale: tuned so a 1 cm tangent-canceled
# motion produces a ~5 cm visible arrow. Tweak per scenario.
const FRICTION_ARROW_SCALE := 5.0
# Pressure bar geometry — drawn radially outward from the rim particle.
const PRESSURE_BAR_MAX_LENGTH := 0.04

# Bright cyan — distinct from particle layer's white crosses and the
# constraint layer's rest-color (also white). Picks up "this segment is
# the orifice rim, not a tentacle chain segment" at a glance.
const RIM_SEGMENT_COLOR := Color(0.4, 0.95, 1.0, 0.9)
# Mint that stays distinct from the particle layer's red-pinned and the
# rim segment cyan; matches Reverie's "neutral rest" palette.
const REST_MARKER_COLOR := Color(0.55, 1.0, 0.8, 0.7)
# Red-purple for the host bone marker — distinct from the rim cyan, the
# rest mint, and Godot's default skeleton orange-yellow. Tells the user
# at a glance "this is where the orifice's Center frame is anchored on
# the ragdoll".
const HOST_BONE_COLOR := Color(0.95, 0.35, 0.85, 0.95)
# Orange — slice 5C-A type-2 contact lines from tentacle particle to rim
# particle. Distinct from rim cyan / rest mint / host bone red-purple /
# environment magenta — chosen so a glance separates contact pairs from
# rim deformation.
const TYPE2_CONTACT_COLOR := Color(1.0, 0.7, 0.25, 0.95)
# Purple for slice 5C-B EntryInteraction markers — entry_point cross +
# entry_axis arrow. Distinct from cyan rim / mint rest / red-purple host
# bone / orange contacts.
const ENTRY_INTERACTION_COLOR := Color(0.7, 0.4, 1.0, 0.95)
# Slightly muted variant for the inactive-but-still-in-grace EIs so the
# user can tell at a glance which are live vs winding down.
const ENTRY_INTERACTION_INACTIVE_COLOR := Color(0.45, 0.3, 0.6, 0.7)
# Slice 5C-C — friction arrow color (cyan-yellow). Distinct from rim
# cyan / orange contact / purple EI / red-purple host bone.
const FRICTION_ARROW_COLOR := Color(0.85, 1.0, 0.4, 0.95)
# Host body marker color (lime). Same family as host-bone marker but
# brighter so the user can tell which side received the impulses.
const HOST_BODY_COLOR := Color(0.55, 1.0, 0.3, 0.95)
# Pressure bar gradient — green (low) → yellow (mid) → red (high).
const PRESSURE_LOW_COLOR := Color(0.3, 1.0, 0.4, 0.9)
const PRESSURE_MID_COLOR := Color(1.0, 1.0, 0.3, 0.9)
const PRESSURE_HIGH_COLOR := Color(1.0, 0.3, 0.3, 0.95)
# Slice 5D §4P-C — magenta arrow from neutral rest to current rest
# position (which is `neutral + plastic_offset`). Drawn only when
# offset is non-zero so a steady orifice stays clean.
const PLASTIC_OFFSET_COLOR := Color(1.0, 0.4, 1.0, 0.95)
# Slice 5D §4P-A — when distance_anisotropic_mode is true and a rim
# segment is in the stretch regime, tint shifts from rim-cyan toward
# yellow as a visual cue. Computed via lerp at draw time; this is the
# saturated yellow endpoint.
const RIM_SEGMENT_STRETCH_COLOR := Color(1.0, 0.95, 0.3, 0.95)
# Slice 5D §4P-B — J-curve strain heat overlay around rim particles
# (only when alpha or beta non-zero). Cool→hot palette.
const J_CURVE_COOL_COLOR := Color(0.3, 0.6, 1.0, 0.85)
const J_CURVE_HOT_COLOR := Color(1.0, 0.3, 0.6, 0.95)

var _imesh: ImmediateMesh
var _material: StandardMaterial3D


func _ready() -> void:
	_imesh = ImmediateMesh.new()
	mesh = _imesh

	_material = StandardMaterial3D.new()
	_material.vertex_color_use_as_albedo = true
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.no_depth_test = true
	_material.disable_receive_shadows = true
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.render_priority = RenderingServer.MATERIAL_RENDER_PRIORITY_MAX
	material_override = _material


# Pull from a single Orifice snapshot. Caller is expected to call this
# once per _process when the layer is visible.
func update_from(p_orifice: Node3D) -> void:
	_imesh.clear_surfaces()
	if p_orifice == null:
		return
	var loop_count: int = int(p_orifice.call(&"get_rim_loop_count"))
	if loop_count <= 0:
		return

	# Convert world-space snapshot positions to layer-local — same pattern
	# as particles_layer.gd. The layer inherits its parent's transform and
	# Godot re-projects to world during render; doing the math here keeps
	# cross-arm sizes constant in world space regardless of any parent
	# scaling.
	var inv: Transform3D = global_transform.affine_inverse()
	_imesh.surface_begin(Mesh.PRIMITIVE_LINES)

	for li in loop_count:
		var state: Array = p_orifice.call(&"get_rim_loop_state", li)
		var n: int = state.size()
		if n < 2:
			continue
		# Pre-project all positions for the loop.
		var current_local: PackedVector3Array = PackedVector3Array()
		var rest_local: PackedVector3Array = PackedVector3Array()
		current_local.resize(n)
		rest_local.resize(n)
		for k in n:
			var d: Dictionary = state[k]
			current_local[k] = inv * (d["current_position"] as Vector3)
			rest_local[k] = inv * (d["rest_position"] as Vector3)

		# Closed-loop rim segments. Slice 5D §4P-A — when the loop is in
		# anisotropic mode AND the segment is currently in the stretch
		# regime (current_length > rest_length), tint shifts toward
		# yellow to flag the asymmetric behavior.
		var aniso_mode: bool = false
		if n > 0:
			aniso_mode = bool((state[0] as Dictionary).get("distance_anisotropic_mode", false))
		for k in n:
			var k1: int = (k + 1) % n
			var dk: Dictionary = state[k]
			var rest_len: float = float(dk.get("neighbour_rest_distance", 0.0))
			var seg_color: Color = RIM_SEGMENT_COLOR
			if aniso_mode and rest_len > 1e-6:
				var cur_len: float = (current_local[k] - current_local[k1]).length()
				if cur_len > rest_len:
					var stretch_ratio: float = clampf((cur_len / rest_len) - 1.0, 0.0, 0.5)
					seg_color = RIM_SEGMENT_COLOR.lerp(RIM_SEGMENT_STRETCH_COLOR, stretch_ratio / 0.5)
			_imesh.surface_set_color(seg_color)
			_imesh.surface_add_vertex(current_local[k])
			_imesh.surface_set_color(seg_color)
			_imesh.surface_add_vertex(current_local[k1])

		# Per-particle current position cross. Slice 5D §4P-B — when J-
		# curve is non-zero, the cross color blends from cool (low strain)
		# to hot (high strain). Otherwise standard pinned/free gradient.
		for k in n:
			var d: Dictionary = state[k]
			var inv_mass: float = d.get("inv_mass", 1.0)
			var strain: float = float(d.get("current_strain", 0.0))
			var c: Color = _Colors.particle_color(inv_mass)
			# J-curve strain heat: lerp blend factor by 1 − 1/(1+strain²)
			# so the cool-to-hot transition tracks the J-curve factor
			# itself. Only kicks in when the loop has J-curve enabled
			# (signaled by a noticeable strain reading).
			if strain > 0.05:
				var heat: float = 1.0 - 1.0 / (1.0 + strain * strain)
				c = J_CURVE_COOL_COLOR.lerp(J_CURVE_HOT_COLOR, heat)
			_draw_cross(current_local[k], RIM_PARTICLE_SIZE, c)

		# Rest position as a small mint dot — deformation reads as the
		# offset between rest and current.
		for k in n:
			_draw_cross(rest_local[k], REST_MARKER_SIZE, REST_MARKER_COLOR)

		# Slice 5D §4P-C — plastic offset arrow from neutral rest to
		# current rest. Only drawn when offset is non-zero (zero-input
		# orifice stays clean). Magenta to distinguish from the
		# host-bone red-purple marker.
		for k in n:
			var d: Dictionary = state[k]
			var po: Vector3 = d.get("plastic_offset", Vector3.ZERO)
			if po.length() < 1e-4:
				continue
			var neutral_world: Vector3 = d.get("neutral_rest_position", rest_local[k])
			var neutral_local: Vector3 = inv * neutral_world
			_imesh.surface_set_color(PLASTIC_OFFSET_COLOR)
			_imesh.surface_add_vertex(neutral_local)
			_imesh.surface_set_color(PLASTIC_OFFSET_COLOR)
			_imesh.surface_add_vertex(rest_local[k])

	# Slice 5B — host bone marker. Drawn once for the orifice (not per
	# loop) at the bone's resolved world position. Helps debug "is the
	# orifice tracking the right bone".
	var host_state: Dictionary = p_orifice.call(&"get_host_bone_state")
	if host_state.get("has_host_bone", false):
		var bone_xform: Transform3D = host_state.get("current_world_transform", Transform3D())
		var bone_world: Vector3 = bone_xform.origin
		_draw_cross(inv * bone_world, HOST_BONE_MARKER_SIZE, HOST_BONE_COLOR)

	# Slice 5C-B — EntryInteraction markers. One small purple cross at
	# the EI's `entry_point` plus a short arrow along `entry_axis`. Arrow
	# length scales with `penetration_depth / 4` so a deep insertion reads
	# distinctly from a glancing one, with a 0.05 m minimum so shallow EIs
	# don't disappear. Inactive-but-still-in-grace EIs are drawn in a
	# muted shade.
	var ei_list: Array = p_orifice.call(&"get_entry_interactions_snapshot")
	if ei_list.size() > 0:
		for ei_idx in ei_list.size():
			var ei: Dictionary = ei_list[ei_idx]
			var entry_point: Vector3 = ei.get("entry_point", Vector3.ZERO)
			var axis: Vector3 = ei.get("entry_axis", Vector3.UP)
			var depth: float = ei.get("penetration_depth", 0.0)
			var ei_active: bool = ei.get("active", true)
			var c: Color = ENTRY_INTERACTION_COLOR if ei_active else ENTRY_INTERACTION_INACTIVE_COLOR
			_draw_cross(inv * entry_point, ENTRY_INTERACTION_MARKER_SIZE, c)
			var arrow_len: float = max(ENTRY_INTERACTION_AXIS_MIN_LENGTH, depth * 0.25)
			var axis_world_end: Vector3 = entry_point + axis.normalized() * arrow_len
			_imesh.surface_set_color(c)
			_imesh.surface_add_vertex(inv * entry_point)
			_imesh.surface_set_color(c)
			_imesh.surface_add_vertex(inv * axis_world_end)

	# Slice 5C-A — type-2 contact lines. One short orange segment per
	# contact, from the tentacle particle's world position to the rim
	# particle's world position. The contact normal is encoded by the
	# segment direction; lambda magnitude is reserved for a future "thicker
	# line" treatment once 5C-C lands the friction half.
	var contacts: Array = p_orifice.call(&"get_type2_contacts_snapshot")
	if contacts.size() > 0:
		for ci in contacts.size():
			var contact: Dictionary = contacts[ci]
			var loop_idx: int = int(contact.get("loop_index", -1))
			var rim_idx: int = int(contact.get("rim_particle_index", -1))
			if loop_idx < 0 or rim_idx < 0:
				continue
			var rim_world: Vector3 = p_orifice.call(&"get_particle_position", loop_idx, rim_idx)
			# Reconstruct tentacle particle world position from the cached
			# normal + radii_sum + signed gap encoded in `distance`. Saves
			# a node lookup; works as long as the snapshot is fresh.
			var normal: Vector3 = contact.get("normal", Vector3.UP)
			var radii_sum: float = contact.get("radii_sum", 0.0)
			var gap: float = contact.get("distance", 0.0)
			# Rim is in `+normal` from the tentacle particle, so the
			# tentacle particle sits at `rim_world − normal × (radii_sum + gap)`.
			var tent_world: Vector3 = rim_world - normal * (radii_sum + gap)
			_imesh.surface_set_color(TYPE2_CONTACT_COLOR)
			_imesh.surface_add_vertex(inv * tent_world)
			_imesh.surface_set_color(TYPE2_CONTACT_COLOR)
			_imesh.surface_add_vertex(inv * rim_world)

	# Slice 5C-C — friction arrows per type-2 contact. Each contact's
	# `friction_applied` vector is drawn as a short cyan-yellow line at
	# the tentacle particle, scaled by `FRICTION_ARROW_SCALE` so visual
	# length tracks magnitude.
	var fric_list: Array = p_orifice.call(&"get_type2_friction_snapshot")
	if fric_list.size() > 0:
		for fi in fric_list.size():
			var fc: Dictionary = fric_list[fi]
			var loop_idx2: int = int(fc.get("loop_index", -1))
			var rim_idx2: int = int(fc.get("rim_particle_index", -1))
			var fa: Vector3 = fc.get("friction_applied", Vector3.ZERO)
			if loop_idx2 < 0 or rim_idx2 < 0 or fa.length() < 1e-7:
				continue
			# Use the tentacle position from the matching type-2 contact
			# snapshot (already reconstructed above) — re-derive it.
			var rim_world2: Vector3 = p_orifice.call(&"get_particle_position", loop_idx2, rim_idx2)
			# Approximate tentacle particle world position by stepping
			# back along the contact normal by radii_sum (we don't have
			# the per-friction-snapshot radii_sum, so approximate via a
			# small offset).
			var arrow_end: Vector3 = rim_world2 + fa * FRICTION_ARROW_SCALE
			_imesh.surface_set_color(FRICTION_ARROW_COLOR)
			_imesh.surface_add_vertex(inv * rim_world2)
			_imesh.surface_set_color(FRICTION_ARROW_COLOR)
			_imesh.surface_add_vertex(inv * arrow_end)

	# Slice 5C-C — per-rim-particle pressure bars. Aggregated across all
	# active EIs (a single rim particle can carry pressure from multiple
	# tentacles). Drawn as a short radial-outward segment whose color
	# steps green→yellow→red with magnitude.
	var ei_list2: Array = p_orifice.call(&"get_entry_interactions_snapshot")
	if ei_list2.size() > 0:
		var center_pos: Vector3 = (p_orifice.get_center_frame_world() as Transform3D).origin
		# Aggregate pressure per (loop_idx, rim_particle_idx).
		var press_map := {}
		for ei2_idx in ei_list2.size():
			var ei2: Dictionary = ei_list2[ei2_idx]
			if not bool(ei2.get("active", false)):
				continue
			var press_arr: Array = ei2.get("radial_pressure_per_loop_k", [])
			for l in press_arr.size():
				var lp: PackedFloat32Array = press_arr[l]
				for k in lp.size():
					if lp[k] <= 0.0:
						continue
					var key := Vector2i(l, k)
					press_map[key] = float(press_map.get(key, 0.0)) + lp[k]
		# Find max for normalization.
		var max_press := 0.0
		for v in press_map.values():
			if v > max_press:
				max_press = v
		if max_press > 0.0:
			for key in press_map:
				var v: float = press_map[key]
				var l: int = key.x
				var k: int = key.y
				var rim_world3: Vector3 = p_orifice.call(&"get_particle_position", l, k)
				var radial: Vector3 = rim_world3 - center_pos
				var rl: float = radial.length()
				if rl < 1e-6:
					continue
				var dir: Vector3 = radial / rl
				var bar_len: float = clampf(v / max_press, 0.0, 1.0) * PRESSURE_BAR_MAX_LENGTH
				var bar_end: Vector3 = rim_world3 + dir * bar_len
				var t_norm: float = clampf(v / max_press, 0.0, 1.0)
				var color: Color
				if t_norm < 0.5:
					color = PRESSURE_LOW_COLOR.lerp(PRESSURE_MID_COLOR, t_norm * 2.0)
				else:
					color = PRESSURE_MID_COLOR.lerp(PRESSURE_HIGH_COLOR, (t_norm - 0.5) * 2.0)
				_imesh.surface_set_color(color)
				_imesh.surface_add_vertex(inv * rim_world3)
				_imesh.surface_set_color(color)
				_imesh.surface_add_vertex(inv * bar_end)

	# Slice 5C-C — host body marker. Drawn at the resolved
	# PhysicalBone3D world origin when host body resolves; helps debug
	# "is the orifice routing impulses to the right body".
	var hbody: Dictionary = p_orifice.call(&"get_host_body_state")
	if hbody.get("has_host_body", false):
		var hb_pos: Vector3 = hbody.get("current_world_position", Vector3.ZERO)
		_draw_cross(inv * hb_pos, HOST_BODY_MARKER_SIZE, HOST_BODY_COLOR)

	_imesh.surface_end()


func _draw_cross(p_pos: Vector3, p_size: float, p_color: Color) -> void:
	var h: float = p_size * 0.5
	_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_pos + Vector3(h, 0, 0))
	_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_pos - Vector3(h, 0, 0))
	_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_pos + Vector3(0, h, 0))
	_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_pos - Vector3(0, h, 0))
	_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_pos + Vector3(0, 0, h))
	_imesh.surface_set_color(p_color); _imesh.surface_add_vertex(p_pos - Vector3(0, 0, h))
