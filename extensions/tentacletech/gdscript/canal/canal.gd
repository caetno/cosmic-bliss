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

## The 5F.A PBD centerline chain (`CanalCenterlineSolver` from
## `src/canal/canal_centerline_solver.{h,cpp}`). Instantiated lazily
## or explicitly by `CanalAutoBaker` after step 9 lays down the rest
## positions + anchors. Held as `RefCounted` so this file doesn't have
## to declare a typed dependency on the C++ class (class registration
## happens at GDExtension scene init; parse-time references would fail
## under `--script` invocation per the test gotcha in CLAUDE.md).
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


# ─── Per-tick driver (5F.A wires the centerline chain) ─────────────

## Per-tick driver. 5F.A wires the centerline PBD chain; texture
## integration (§6.12.4) lands in 5F.B and lateral muscular curl (§6.12)
## in 5G. `is_inactive()` still gates the body so production callers
## that wire `Canal.tick(dt)` into a `_physics_process` on the hero
## don't pay the cost for canals with no EI / no storage / no Reverie
## modulation (§6.12.9 hierarchical activation).
##
## Anchors are read each tick from `_proximal_anchor_world` /
## `_distal_anchor_world` — fields populated by `CanalAutoBaker` at
## bake time. 5F.B will refresh those fields per-tick via
## `centerline_source` so a moving host bone propagates into the
## chain; that's out of scope here.
func tick(p_delta: float) -> void:
	if is_inactive():
		return
	if _centerline_chain == null:
		return
	_centerline_chain.set_anchors(_proximal_anchor_world, _distal_anchor_world)
	_centerline_chain.tick(p_delta)


## Test-only entry point that bypasses `is_inactive()`. Used by
## slice 5F.A tests to drive the centerline solver through the
## `Canal` API without first wiring up an EntryInteraction. The 5G
## modulation tests will be able to flip a real activation gate;
## until then the test bypass keeps test scope tight to the chain
## itself.
func tick_force(p_delta: float) -> void:
	if _centerline_chain == null:
		return
	_centerline_chain.set_anchors(_proximal_anchor_world, _distal_anchor_world)
	_centerline_chain.tick(p_delta)


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


## Reports whether 5F.A has plugged in a centerline solver. False
## until `_ensure_centerline_chain` runs (typically called by
## `CanalAutoBaker` after step 9). When false, the gizmo overlay
## falls back to drawing rest positions.
func has_centerline_chain() -> bool:
	return _centerline_chain != null


## Returns the live centerline solver, or null if none has been
## instantiated yet. Held by `Canal` so test fixtures and the gizmo
## overlay can pull snapshots without re-routing through accessors.
func get_centerline_chain() -> RefCounted:
	return _centerline_chain


## Builds the `CanalCenterlineSolver` from the current baked substrate
## (rest positions, anchors, parameters). Idempotent: calling twice
## after a fresh bake rebuilds the chain so changes to parameters or
## rest positions take effect. Returns the new chain instance, or null
## if class registration is missing or rest positions are empty (e.g.
## bake failed). Public so `CanalAutoBaker.bake()` can call it as the
## final substrate step.
func _ensure_centerline_chain() -> RefCounted:
	if _centerline_rest_positions.is_empty():
		return null
	if not ClassDB.class_exists("CanalCenterlineSolver"):
		push_error("Canal._ensure_centerline_chain: CanalCenterlineSolver class not registered "
				+ "(tentacletech extension not loaded)")
		return null
	var solver: RefCounted = ClassDB.instantiate("CanalCenterlineSolver")
	# inv_mass: 0 (pinned) on proximal + distal, 1.0 on interior.
	var n: int = _centerline_rest_positions.size()
	var inv_mass := PackedFloat32Array()
	inv_mass.resize(n)
	for i in n:
		inv_mass[i] = 0.0 if (i == 0 or i == n - 1) else 1.0
	solver.configure(_centerline_rest_positions, inv_mass)
	solver.set_anchors(_proximal_anchor_world, _distal_anchor_world)
	# Push tunables from canal_parameters when available.
	if canal_parameters != null:
		solver.set_iterations(canal_parameters.centerline_iterations)
		solver.set_bending_stiffness(canal_parameters.centerline_bending_stiffness)
		solver.set_damping(canal_parameters.centerline_damping)
		solver.set_gravity_scale(canal_parameters.centerline_gravity_scale)
	_centerline_chain = solver
	return solver


## Snapshot of current centerline particle positions in world space.
## Returns empty array if no chain is allocated. By-copy per §15.
func get_centerline_positions_snapshot() -> PackedVector3Array:
	if _centerline_chain == null:
		return PackedVector3Array()
	return _centerline_chain.get_positions_snapshot()


## Snapshot of previous-tick centerline particle positions. Used by
## the gizmo overlay for bending residual visualisation.
func get_centerline_prev_positions_snapshot() -> PackedVector3Array:
	if _centerline_chain == null:
		return PackedVector3Array()
	return _centerline_chain.get_prev_positions_snapshot()
