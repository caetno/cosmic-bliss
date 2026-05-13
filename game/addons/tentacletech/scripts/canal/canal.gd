@tool
class_name Canal
extends Node3D

## Per-canal runtime node. Holds the baked rest-pose substrate
## (§6.12.1 + §6.12.2): Catmull spline through CP bones, per-cell
## rest-radius table, allocated `tunnel_state` RGBA32F texture,
## centerline particle rest positions. Per-tick dynamics
## (centerline solver + texture integration §6.12.4) ship in 5F;
## modulation API (Reverie writes muscle / curl) ships in 5G.
##
## 5E places this node in the scene tree alongside the host hero
## body. `CanalAutoBaker.bake(canal, hero_mesh_instance, skeleton)`
## populates the baked substrate at scene init. The node itself owns
## the storage so editor inspection + gizmo overlay can read state
## without spinning up the AutoBaker again.

## Per-canal authoring + runtime parameters. `CanalAutoBaker` reads
## this resource at bake time; the per-tick integration loop (5F+)
## reads it every tick.
@export var canal_parameters: CanalParameters

## Source of rest-pose centerline geometry. `null` means
## `CanalAutoBaker` substitutes a default `CPBoneCenterlineSource` at
## bake time (5E back-compat). Set explicitly to a
## `CPBoneCenterlineSource` to make the dependency visible in the
## inspector, or — when `body_field` ships its primitive resource
## family per the 2026-05-13 gizmo-primitive amendment — to a
## `CanalCenterlinePrimitiveSource`. The solver and per-tick rest
## refresh path consume only the abstract base; they cannot tell
## which concrete source is plugged in.
@export var centerline_source: CanalCenterlineSource

# ─── Baked substrate (filled by CanalAutoBaker) ────────────────────

## Catmull spline through the resolved CP bone world positions, in
## the order given by their trailing numeric suffix. Sampled by the
## per-vert bake step + the gizmo overlay. 5F's centerline solver
## reads `rest_positions_in_host_frame` snapshots for spring-back.
var _spline: RefCounted

## Row-major per-cell rest radius table, sized
## `canal_axial_segments × canal_angular_sectors`. Index k*sectors+j.
## Consumed by §6.12.4 step 2e to compute the target wall radius.
var _rest_radius_per_cell: PackedFloat32Array = PackedFloat32Array()

## `(canal_axial_segments × canal_angular_sectors)` RGBA32F image
## holding (dynamic_wall_radius, plastic_offset, damage|velocity,
## fourth_channel) cells. R-channel initialised to rest_radius;
## G/B/A initialised to (0, 0, 1.0). 5F+ updates this each tick.
var _tunnel_state_texture: ImageTexture

## Centerline particle rest positions in WORLD space (sampled along
## the rest spline at uniform arc-length spacing). 5F's PBD chain
## reads these as the spring-back target after host-frame transform.
var _centerline_rest_positions: PackedVector3Array = PackedVector3Array()

## Resolved distal/proximal anchor world positions captured at bake
## time. 5F's PBD chain pins the proximal+distal centerline
## particles here each tick (after refreshing from the orifice
## Center frames + TerminalPin bone).
var _proximal_anchor_world: Vector3
var _distal_anchor_world: Vector3

## Placeholder for the 5F PBD centerline chain. 5E never instantiates
## it; runtime code that wants a chain checks `has_centerline_chain()`
## and walks `_centerline_rest_positions` for the rest pose instead.
var _centerline_chain: RefCounted = null

# ─── Runtime identity ──────────────────────────────────────────────

## Index of this canal in the hero's canal array. `CUSTOM0.r` on
## canal interior verts is authored as `canal_id + 1` (0 reserved
## for "not a canal vert"). Set by `CanalAutoBaker` so per-vert bake
## can route based on the same value. Default -1 = unset.
var _canal_id: int = -1


func set_canal_id(p_id: int) -> void:
	_canal_id = p_id


func get_canal_id() -> int:
	return _canal_id


# ─── Hierarchical activation (§6.12.9) ─────────────────────────────

## True iff no active EntryInteraction on either orifice AND no
## storage chain content AND no Reverie modulation. 5E always returns
## true (placeholder — no EI machinery wired yet, no Reverie writes,
## no storage); 5F flips the body to query each gating signal.
##
## Per §6.12.9: when inactive, both the centerline solver tick and
## the texture integration loop are skipped entirely; the shader
## reads the last-uploaded texture (= rest pose at scene init).
func is_inactive() -> bool:
	# 5E placeholder. 5F replaces with:
	#   return _active_entry_interactions.is_empty()
	#       and _storage_chain.is_empty()
	#       and _reverie_modulation_zero()
	return true


# ─── Per-tick stub (5F populates) ──────────────────────────────────

## Per-tick driver — 5F runs the centerline solver + texture
## integration here. 5E is a no-op early-return on `is_inactive()`.
## The stub exists so 5F has a clean place to hang the per-tick work
## without restructuring the node lifecycle.
func tick(_p_delta: float) -> void:
	if is_inactive():
		return
	# 5F:
	#   _centerline_chain.tick(_p_delta)
	#   _integrate_tunnel_state(_p_delta)


# ─── Bake-time accessors (used by CanalAutoBaker + gizmo) ──────────

## Direct setter used by `CanalAutoBaker` after step 6 builds the
## spline. Stored as RefCounted (CatmullSpline) so this file doesn't
## need to declare a typed dependency on the C++ class — the cache
## refresh + class registration handle the lookup.
func _set_baked_spline(p_spline: RefCounted) -> void:
	_spline = p_spline


func get_baked_spline() -> RefCounted:
	return _spline


func _set_baked_rest_radius_per_cell(p_table: PackedFloat32Array) -> void:
	_rest_radius_per_cell = p_table


func get_baked_rest_radius_per_cell() -> PackedFloat32Array:
	return _rest_radius_per_cell


func _set_baked_tunnel_state_texture(p_tex: ImageTexture) -> void:
	_tunnel_state_texture = p_tex


func get_baked_tunnel_state_texture() -> ImageTexture:
	return _tunnel_state_texture


func _set_baked_centerline_rest_positions(p_positions: PackedVector3Array) -> void:
	_centerline_rest_positions = p_positions


func get_baked_centerline_rest_positions() -> PackedVector3Array:
	return _centerline_rest_positions


func _set_baked_anchors(p_proximal: Vector3, p_distal: Vector3) -> void:
	_proximal_anchor_world = p_proximal
	_distal_anchor_world = p_distal


func get_proximal_anchor_world() -> Vector3:
	return _proximal_anchor_world


func get_distal_anchor_world() -> Vector3:
	return _distal_anchor_world


## Reports whether 5F has plugged in a centerline solver. 5E always
## returns false; the gizmo overlay falls back to drawing rest
## positions in that case.
func has_centerline_chain() -> bool:
	return _centerline_chain != null
