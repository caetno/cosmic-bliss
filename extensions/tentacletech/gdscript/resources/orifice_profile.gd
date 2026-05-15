@tool
class_name OrificeProfile
extends Resource

## Authoring-time configuration block for an Orifice (§10.4, §10.5).
##
## Slice TT-S3 (contact suppression) is the first concrete field on this
## resource — every other §10.4 OrificeAutoBaker output (rim anchors,
## tunnel spline, girth profile) is implied future scope. The resource
## exists today so the runtime has one canonical Object to read from
## once the AutoBaker ships; until then a small amount of authoring is
## done by hand (manual_suppressed_bones) and the auto-list stays empty.
##
## See:
## - docs/architecture/TentacleTech_Architecture.md §10.5
## - docs/Cosmic_Bliss_Update_2026-05-14-03_ragdoll_under_tension_scenario.md §4 slice 2

## Auto-populated by `OrificeAutoBaker` at bake time from proximity to
## the orifice Center frame (§10.4 step 5). The AutoBaker has not landed
## yet — for 5F-era scenes this list will typically be empty and
## `manual_suppressed_bones` carries the entire payload. Treat as
## authoritative input once the baker ships.
@export var suppressed_bones: PackedStringArray = PackedStringArray()

## Author-override pass; merged into the effective suppression set on
## top of the auto-populated list. Lets the user add anatomy-specific
## bones the proximity heuristic misses (e.g. distant rib bones that
## the rim still mechanically engages, or a chin bone whose capsule
## overhangs the mouth orifice). Bone names not present in the
## skeleton at `resolve_suppression_set` time produce a warning and
## are skipped (the §10.5 mechanism is best-effort — no contact gets
## suppressed when the resolver can't find a body).
@export var manual_suppressed_bones: PackedStringArray = PackedStringArray()


## Slice TT-S6 (§6.5) — per-loop area-stiffening coefficient applied
## to every rim loop on this orifice at hero-init. Effective per-iter
## area compliance becomes
## `loop.area_compliance / (1 + area_stiffening_per_ei × active_ei_count)`,
## where `active_ei_count` is the EI count on this orifice. Retires
## the original "Cap: 3 simultaneous per orifice. 4th rejected at
## entry." hard boolean — orifices now physically resist further
## expansion as more tentacles enter, rather than refusing the 4th
## via a script.
##
## Tuning per anatomy:
## - Lax-rim anatomies (lips, vulva at high arousal) → lower (0.2-0.4)
## - Tight-rim anatomies (anus, urethra) → higher (0.6-1.0)
## - Default 0.5 → 3-EI loading gives 2.5× nominal stiffness, which
##   makes a 4th-tentacle entry visibly hard but not impossible.
@export_range(0.0, 4.0, 0.05) var area_stiffening_per_ei: float = 0.5


## Returns the union of `suppressed_bones` + `manual_suppressed_bones`
## with duplicates removed. Order is not stable — callers must not
## rely on it. The runtime resolves the union once per host-init via
## `Orifice.set_suppressed_object_ids`; per-tick code reads the
## resolved Object-ID set directly, never re-walks this method.
func get_effective_suppression_set() -> PackedStringArray:
	var seen := {}
	var out := PackedStringArray()
	for n in suppressed_bones:
		if n.is_empty():
			continue
		if not seen.has(n):
			seen[n] = true
			out.append(n)
	for n in manual_suppressed_bones:
		if n.is_empty():
			continue
		if not seen.has(n):
			seen[n] = true
			out.append(n)
	return out
