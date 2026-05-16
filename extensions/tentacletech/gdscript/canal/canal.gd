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

## Optional override for the skeleton driving this canal's CP bones +
## TerminalPin lookup. Empty path → `_resolve_skeleton()` walks
## ancestors looking for the first `Skeleton3D`. Used by the per-tick
## anchor refresh (5F.B.A) so a moving host bone propagates into the
## centerline chain without re-running the bake. Cached lazily.
@export var skeleton_path: NodePath

## Optional override for the parent node whose children are the
## scene's `Orifice` nodes. Empty path → `get_parent()`. Resolved by
## `get_orifices_root()` so the per-tick refresh in
## `CPBoneCenterlineSource.refresh_anchors` can find the entry/exit
## orifice nodes by their authored `NodePath`s on `CanalParameters`.
@export var orifices_root_path: NodePath

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

## The 5F.B.B per-tick `tunnel_state` CPU integrator
## (`TunnelStateIntegrator` from
## `src/canal/tunnel_state_integrator.{h,cpp}`). Owns four per-cell
## scratch arrays (dynamic_wall_radius, plastic_offset, damage,
## fourth_channel) and uploads them to `_tunnel_state_texture` each
## tick. Same RefCounted-by-name pattern as `_centerline_chain` for
## the same parse-time reason.
var _tunnel_state_integrator: RefCounted = null

## The §6.12.12 per-substep canal-interior reaction pass
## (`CanalReactionPass` from `src/canal/canal_reaction_pass.{h,cpp}`).
## Reads `_tunnel_state_integrator`'s wall displacement per cross-
## section, sums to per-cross-section wall reaction, routes to the
## CP bone's rigid host-bone parent, dispatches `body_apply_impulse`
## at the load-weighted centroid. Same RefCounted-by-name pattern as
## the centerline chain + tunnel-state integrator for the same parse-
## time reason.
var _reaction_pass: RefCounted = null

## Per-cross-section host-bone RIDs, sized `canal_axial_segments`.
## Resolved at bake time by `CanalAutoBaker` step 9b — each cross-
## section's CP bone's rigid-parent host bone, looked up via the
## skeleton's PhysicalBone3D children. Empty RID = no resolvable
## host bone; the reaction pass silently skips those sections.
var _cross_section_host_bone_rids: Array = []

## Parallel Object IDs for the host PhysicalBone3D nodes. Used by
## tests + gizmo overlay so a fixture can inspect which host bone
## absorbed each cross-section's reaction without re-doing the
## skeleton lookup.
var _cross_section_host_bone_object_ids: PackedInt64Array = PackedInt64Array()

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

## 5F.B.C — Test-only override. Set true to force `is_inactive()` false
## so test fixtures can drive `tick()` (not `tick_force`) without first
## wiring up an EntryInteraction. Production callers leave this false.
@export var force_active_for_test: bool = false


## True iff no active EntryInteraction on either orifice AND no
## storage chain content AND no Reverie modulation. 5E always returns
## true (placeholder — no EI machinery wired yet, no Reverie writes,
## no storage); 5F flips the body to query each gating signal.
##
## Per §6.12.9: when inactive, both the centerline solver tick and
## the texture integration loop are skipped entirely; the shader
## reads the last-uploaded texture (= rest pose at scene init).
func is_inactive() -> bool:
	if force_active_for_test:
		return false
	# 5E placeholder. 5F replaces with:
	#   return _active_entry_interactions.is_empty()
	#       and _storage_chain.is_empty()
	#       and _reverie_modulation_zero()
	return true


## 5F.B.C — Test-only helper that binds a tentacle to this canal with
## the given proximal particle index. Production EI → canal binding
## lives in the EI lifecycle hooks on `Orifice` (follow-up slice).
func register_active_canal_for_test(p_tentacle: Node, p_proximal_particle_idx: int) -> void:
	if p_tentacle == null:
		return
	if not p_tentacle.has_method("register_active_canal"):
		push_error("Canal.register_active_canal_for_test: tentacle missing "
				+ "register_active_canal — was the tentacletech extension loaded?")
		return
	p_tentacle.call("register_active_canal", self, p_proximal_particle_idx)


func unregister_active_canal_for_test(p_tentacle: Node) -> void:
	if p_tentacle == null:
		return
	if not p_tentacle.has_method("unregister_active_canal"):
		return
	p_tentacle.call("unregister_active_canal", self)


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
	_refresh_anchors_through_source()
	_centerline_chain.set_anchors(_proximal_anchor_world, _distal_anchor_world)
	_centerline_chain.tick(p_delta)
	_tick_tunnel_state(p_delta)
	_tick_reaction_pass(p_delta)


## Test-only entry point that bypasses `is_inactive()`. Used by
## slice 5F.A tests to drive the centerline solver through the
## `Canal` API without first wiring up an EntryInteraction. The 5G
## modulation tests will be able to flip a real activation gate;
## until then the test bypass keeps test scope tight to the chain
## itself.
func tick_force(p_delta: float) -> void:
	if _centerline_chain == null:
		return
	_refresh_anchors_through_source()
	_centerline_chain.set_anchors(_proximal_anchor_world, _distal_anchor_world)
	_centerline_chain.tick(p_delta)
	_tick_tunnel_state(p_delta)
	_tick_reaction_pass(p_delta)


## Per-tick driver for the `TunnelStateIntegrator` slice 5F.B.B
## attaches. Called from both `tick` (gated by `is_inactive()`) and
## `tick_force` (test bypass). Refreshes the zone-strength snapshot
## first so Reverie's per-tick modulation propagates without re-
## configuring the integrator, then runs the per-cell integration.
func _tick_tunnel_state(p_delta: float) -> void:
	if _tunnel_state_integrator == null:
		return
	if canal_parameters != null:
		_tunnel_state_integrator.update_constriction_zones(
				_flatten_constriction_zones(canal_parameters.constriction_zones))
	_tunnel_state_integrator.tick(p_delta)


# Flatten the authored `Array[CanalConstrictionZone]` into a flat
# PackedFloat32Array of 5-tuples (arc_length_s, half_width,
# max_contraction, current_strength, friction_bonus) — the format the
# C++ integrator expects. Cheap (Reverie scenes will have ≤ ~8 zones
# per canal); allocating a fresh array each tick keeps the wire-up
# simple and avoids stale-state bugs.
func _flatten_constriction_zones(p_zones: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if p_zones == null:
		return out
	out.resize(p_zones.size() * 5)
	for i in p_zones.size():
		var z = p_zones[i]
		if z == null:
			# Holes are zero-strength zones; harmless but should warn
			# loudly enough that an authoring mistake doesn't go silent.
			out[i * 5 + 0] = 0.0
			out[i * 5 + 1] = 0.0
			out[i * 5 + 2] = 0.0
			out[i * 5 + 3] = 0.0
			out[i * 5 + 4] = 0.0
			continue
		out[i * 5 + 0] = z.arc_length_s
		out[i * 5 + 1] = z.half_width
		out[i * 5 + 2] = z.max_contraction
		out[i * 5 + 3] = z.current_strength
		out[i * 5 + 4] = z.friction_bonus
	return out


# ─── Per-tick anchor refresh (5F.B.A) ──────────────────────────────

## Re-resolve `_proximal_anchor_world` / `_distal_anchor_world` from
## the `centerline_source`. Called each tick before driving the
## solver so moving host bones / orifice frames propagate into the
## chain. Fallbacks: the existing bake-time anchor values, so a
## degenerate config (no source override, no resolvable orifice) is a
## no-op rather than a snap to origin.
func _refresh_anchors_through_source() -> void:
	if centerline_source == null:
		return
	var skel := _resolve_skeleton()
	var anchors: Dictionary = centerline_source.refresh_anchors(
			skel, self, _proximal_anchor_world, _distal_anchor_world)
	_proximal_anchor_world = anchors.get("proximal", _proximal_anchor_world)
	_distal_anchor_world = anchors.get("distal", _distal_anchor_world)


# ─── Scene-graph resolvers (used by per-tick refresh) ──────────────

## Resolves the skeleton driving this canal. `skeleton_path` override
## wins; otherwise walks ancestors looking for the first `Skeleton3D`.
## Returns `null` if neither resolves — callers should fall back to a
## no-op when this is the case.
func _resolve_skeleton() -> Skeleton3D:
	if not skeleton_path.is_empty():
		var n := get_node_or_null(skeleton_path)
		if n is Skeleton3D:
			return n
	var cur: Node = get_parent()
	while cur != null:
		if cur is Skeleton3D:
			return cur
		cur = cur.get_parent()
	return null


## Returns the node whose children are this canal's referenced
## orifices. `orifices_root_path` override wins; otherwise returns
## `get_parent()` (hero-root convention). Consumed by
## `CPBoneCenterlineSource.refresh_anchors`.
func get_orifices_root() -> Node:
	if not orifices_root_path.is_empty():
		var n := get_node_or_null(orifices_root_path)
		if n != null:
			return n
	return get_parent()


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


# ─── 5F.B.B — tunnel_state CPU integrator ──────────────────────────


## Reports whether 5F.B.B has plugged in a tunnel-state integrator.
## Mirrors `has_centerline_chain()`; gizmo + test fixtures gate on this
## before drawing wall-displacement markers / asserting on snapshots.
func has_tunnel_state_integrator() -> bool:
	return _tunnel_state_integrator != null


## Live `TunnelStateIntegrator` accessor — returns null if none has
## been configured yet. Held by `Canal` so test fixtures can drive
## test-only setters without re-routing through this node.
func get_tunnel_state_integrator() -> RefCounted:
	return _tunnel_state_integrator


## Builds the `TunnelStateIntegrator` from the current baked substrate
## (rest_radius_per_cell, tunnel_state texture, centerline solver) +
## canal_parameters tunables. Idempotent: calling twice rebuilds the
## integrator so a re-bake or parameter swap takes effect. Returns the
## new integrator instance, or null when the class isn't registered
## (extension not loaded) or when no rest_radius table has been baked.
## Public so `CanalAutoBaker.bake()` can call it as the final substrate
## step after `_ensure_centerline_chain()`.
func _ensure_tunnel_state_integrator() -> RefCounted:
	if canal_parameters == null:
		return null
	if _rest_radius_per_cell.is_empty():
		return null
	if _tunnel_state_texture == null:
		return null
	if not ClassDB.class_exists("TunnelStateIntegrator"):
		push_error("Canal._ensure_tunnel_state_integrator: TunnelStateIntegrator "
				+ "class not registered (tentacletech extension not loaded)")
		return null
	var integ: RefCounted = ClassDB.instantiate("TunnelStateIntegrator")
	integ.configure(
			canal_parameters.canal_axial_segments,
			canal_parameters.canal_angular_sectors,
			_rest_radius_per_cell,
			_tunnel_state_texture,
			_flatten_constriction_zones(canal_parameters.constriction_zones))
	integ.set_centerline_solver(_centerline_chain)
	integ.set_curvature_response_gain(canal_parameters.curvature_response_gain)
	integ.set_contraction_gain(canal_parameters.contraction_gain)
	integ.set_min_wall_radius(canal_parameters.min_wall_radius)
	integ.set_wall_response_rate(canal_parameters.wall_response_rate)
	integ.set_use_second_order_wall(canal_parameters.use_second_order_wall)
	integ.set_wall_acceleration_gain(canal_parameters.wall_acceleration_gain)
	integ.set_wall_damping(canal_parameters.wall_damping)
	integ.set_plastic_params(
			canal_parameters.plastic_accumulate_rate,
			canal_parameters.plastic_recover_rate,
			canal_parameters.plastic_max_offset)
	integ.set_damage_params(
			canal_parameters.damage_rate,
			canal_parameters.damage_plastic_gain,
			canal_parameters.damage_friction_loss)
	integ.set_muscle_friction_gain(canal_parameters.muscle_friction_gain)
	# `CanalParameters.fourth_channel_mode` now matches the integrator's
	# enum 1:1 (the legacy "damage" option was dropped at slice 5F.B.B —
	# damage already occupies the B channel). No remap needed.
	integ.set_fourth_channel_mode(canal_parameters.fourth_channel_mode)
	_tunnel_state_integrator = integ
	return integ


## Snapshot of per-cell `dynamic_wall_radius` (m). Indexed
## `k * angular_sectors + j`. Empty when no integrator is allocated.
func get_dynamic_wall_radius_snapshot() -> PackedFloat32Array:
	if _tunnel_state_integrator == null:
		return PackedFloat32Array()
	return _tunnel_state_integrator.get_dynamic_wall_radius_snapshot()


## Snapshot of per-cell `plastic_offset` (m). Same indexing as above.
func get_plastic_offset_snapshot() -> PackedFloat32Array:
	if _tunnel_state_integrator == null:
		return PackedFloat32Array()
	return _tunnel_state_integrator.get_plastic_offset_snapshot()


## Snapshot of per-cell `damage` (Pa·s units, monotonically growing).
func get_damage_snapshot() -> PackedFloat32Array:
	if _tunnel_state_integrator == null:
		return PackedFloat32Array()
	return _tunnel_state_integrator.get_damage_snapshot()


## Snapshot of the fourth-channel value (`wall_radial_velocity` when
## `fourth_channel_mode == 0`, `friction_mult` when `== 1`).
func get_fourth_channel_snapshot() -> PackedFloat32Array:
	if _tunnel_state_integrator == null:
		return PackedFloat32Array()
	return _tunnel_state_integrator.get_fourth_channel_snapshot()


# ─── §6.12.12 — Canal-interior reaction pass ───────────────────────


## Setter used by `CanalAutoBaker` step 9b after host-bone resolution.
## Stores per-cross-section host-bone RIDs + parallel Object IDs.
## Idempotent — calling again replaces both arrays in one go.
func _set_baked_cross_section_host_bone_rids(
		p_rids: Array, p_object_ids: PackedInt64Array) -> void:
	_cross_section_host_bone_rids = p_rids
	_cross_section_host_bone_object_ids = p_object_ids


## Returns the resolved host-bone RID for cross-section `k`, or an
## empty RID if `k` is out of range or unresolved.
func get_cross_section_host_bone_rid(p_k: int) -> RID:
	if p_k < 0 or p_k >= _cross_section_host_bone_rids.size():
		return RID()
	return _cross_section_host_bone_rids[p_k]


## Snapshot of the per-cross-section host-bone RIDs. Empty RID
## entries mark cross-sections with no resolvable PhysicalBone3D
## (degenerate authoring; reaction pass skips them).
func get_cross_section_host_bone_rids_snapshot() -> Array:
	return _cross_section_host_bone_rids.duplicate()


## Snapshot of the parallel Object IDs. Tests use this to assert
## "cross-section k routes to bone X" without re-walking the skeleton.
func get_cross_section_host_bone_object_ids_snapshot() -> PackedInt64Array:
	return _cross_section_host_bone_object_ids.duplicate()


## Reports whether §6.12.12 has plugged in a reaction pass.
func has_reaction_pass() -> bool:
	return _reaction_pass != null


## Live `CanalReactionPass` accessor; null until `_ensure_reaction_pass`
## runs (typically called by `CanalAutoBaker` after step 9b lays down
## the host-bone RIDs).
func get_reaction_pass() -> RefCounted:
	return _reaction_pass


## Builds the `CanalReactionPass` from the current baked substrate
## (rest_radius_per_cell, host_bone_rids, centerline solver,
## tunnel-state integrator) + canal_parameters tunables. Idempotent;
## a re-bake replaces the pass.
func _ensure_reaction_pass() -> RefCounted:
	if canal_parameters == null:
		return null
	if _rest_radius_per_cell.is_empty():
		return null
	if _centerline_chain == null or _tunnel_state_integrator == null:
		# The reaction pass reads displacement from the integrator and
		# world-pose from the centerline; neither dependency optional.
		return null
	if not ClassDB.class_exists("CanalReactionPass"):
		push_error("Canal._ensure_reaction_pass: CanalReactionPass class not registered "
				+ "(tentacletech extension not loaded)")
		return null
	var pass_inst: RefCounted = ClassDB.instantiate("CanalReactionPass")
	pass_inst.configure(
			canal_parameters.canal_axial_segments,
			canal_parameters.canal_angular_sectors,
			_rest_radius_per_cell,
			_cross_section_host_bone_rids,
			canal_parameters.wall_response_stiffness,
			canal_parameters.canal_reaction_rim_exclusion)
	pass_inst.set_centerline_solver(_centerline_chain)
	pass_inst.set_tunnel_state_integrator(_tunnel_state_integrator)
	_reaction_pass = pass_inst
	return pass_inst


# Per-tick driver — called from both `tick` (gated by `is_inactive()`)
# and `tick_force`. Silently no-ops when no pass has been allocated.
func _tick_reaction_pass(p_delta: float) -> void:
	if _reaction_pass == null:
		return
	_reaction_pass.tick(p_delta)


## Snapshot of per-cross-section reaction vectors (N), sized
## `canal_axial_segments`. Indices `< canal_reaction_rim_exclusion`
## are always Vector3.ZERO (excluded). By-copy per §15.
func get_last_reaction_per_section_snapshot() -> PackedVector3Array:
	if _reaction_pass == null:
		return PackedVector3Array()
	return _reaction_pass.get_last_reaction_per_section_snapshot()


## Snapshot of per-host-bone impulse vectors (N·s) applied this tick.
## Sized to the number of unique bones that received an impulse.
## Order matches `get_last_application_points_snapshot()`.
func get_last_bone_impulse_snapshot() -> PackedVector3Array:
	if _reaction_pass == null:
		return PackedVector3Array()
	return _reaction_pass.get_last_bone_impulse_snapshot()


## Snapshot of the load-weighted centroid world-space points the
## impulses were applied at. Same indexing as `get_last_bone_impulse_snapshot()`.
func get_last_application_points_snapshot() -> PackedVector3Array:
	if _reaction_pass == null:
		return PackedVector3Array()
	return _reaction_pass.get_last_application_points_snapshot()
