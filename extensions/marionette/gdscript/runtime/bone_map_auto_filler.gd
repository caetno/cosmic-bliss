@tool
class_name BoneMapAutoFiller
extends RefCounted

## Pass 1 of the drop-in skeleton workflow. Reads a `Skeleton3D`'s bone names,
## scores each candidate against `BoneNameDictionary` per-convention entries,
## and returns a slot→fill mapping. Greedy assignment by score prevents one
## bone filling two slots.
##
## Authoring-time only. Not called from `_physics_process` or any runtime path.
##
## Returns Dictionary[StringName, FillResult] where FillResult is
## `{ source_bone: StringName, confidence: float, convention: String }`.

## Substring tests on lowercased raw bone name. Bones containing any of these
## are excluded from candidacy entirely — they're IK/FK helpers, control rigs,
## tweak handles, leaf bones, or namespace controls (Rigify MCH/ORG/VIS/WGT,
## ARP `c_p_*` / `c_traj` / IK targets / pole vectors / twist helpers).
## `Array[String]` not `PackedStringArray` because `PackedStringArray(...)`
## isn't a constant expression in GDScript 4.6.
const _SKIP_SUBSTRINGS: Array[String] = [
	# ARP / general helper markers
	"_ik", "_fk", "_pole", "_target", "_twist", "_twk",
	"_helper", "_tweak", "_master", "_ref", "_drv",
	"_handle", "_offset", "_track", "_widget", "_swing",
	"_pre_pole", "_snap_fk", "_scale_fix", "_basetoe",
	"_roll", "_rock", "bend_all",
	"_rot.", "_base.", "_base_",
	# Leaf bones (Mixamo `_End`, ARP `_end_*`, Rigify `_end_handle`).
	"_end",
	# Rigify control / mech / org / widget namespaces.
	"vis_", "mch-", "org-", "wgt-",
	# ARP scene-root controls.
	"c_p_", "c_traj", "c_pos",
	"c_root.", "c_arms_pole",
	"c_stretch_arm", "c_stretch_leg",
]

## Default Jaccard / score threshold below which a slot stays unmapped.
const DEFAULT_CONFIDENCE_THRESHOLD: float = 0.6

## Score awarded when normalized token sets are equal (and side compatible).
## Higher than partial Jaccard, lower than exact raw match — exact-raw wins
## the tiebreak between deform vs control variants like `arm_stretch.l` vs
## `arm.l` (both normalize to tokens=[arm], but only the deform matches the
## raw ARP dictionary entry).
const _NORMALIZED_MATCH_SCORE: float = 0.9


static func auto_fill(
		skel: Skeleton3D,
		existing: BoneMap = null,
		threshold: float = DEFAULT_CONFIDENCE_THRESHOLD,
		) -> Dictionary:
	var results: Dictionary = {}
	if skel == null:
		push_warning("BoneMapAutoFiller.auto_fill: skeleton is null")
		return results

	# Collect candidate bones, filtering out helpers / controls.
	var candidates: Array[Dictionary] = _collect_candidates(skel)

	# Identify slots already filled in `existing` — skip those (preserve manual edits).
	var locked_slots: Dictionary = {}
	if existing != null:
		for slot_str: String in BoneNameDictionary.SLOT_NAMES:
			var slot: StringName = StringName(slot_str)
			var existing_name: StringName = existing.get_skeleton_bone_name(slot)
			if not String(existing_name).is_empty():
				locked_slots[slot] = String(existing_name)

	# Compute (slot, candidate, score) triples for greedy assignment.
	var triples: Array[Dictionary] = []
	for slot_str: String in BoneNameDictionary.SLOT_NAMES:
		var slot: StringName = StringName(slot_str)
		if locked_slots.has(slot):
			continue
		var slot_side: int = BoneNameNormalizer.slot_required_side(slot)
		var expected_names: PackedStringArray = BoneNameDictionary.expected_names(slot)
		if expected_names.is_empty():
			continue
		# Pre-normalize expected names once per slot.
		var expected: Array[Dictionary] = []
		for en: String in expected_names:
			expected.append({
				"raw": en,
				"norm": BoneNameNormalizer.normalize(en),
			})
		for cand: Dictionary in candidates:
			var cand_norm: Dictionary = cand["norm"]
			var cand_side: int = cand_norm["side"]
			if not BoneNameNormalizer.sides_compatible(cand_side, slot_side):
				continue
			var best_score: float = 0.0
			var best_match_raw: String = ""
			for ex: Dictionary in expected:
				var s: float = _score(cand, ex)
				if s > best_score:
					best_score = s
					best_match_raw = ex["raw"]
			if best_score >= threshold:
				triples.append({
					"slot": slot,
					"source": cand["raw"],
					"score": best_score,
					"matched_against": best_match_raw,
				})

	# Greedy assignment: highest-score triples win. One slot per bone, one bone
	# per slot. Bones already locked by `existing` are not in triples.
	triples.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["score"] > b["score"])
	var taken_bones: Dictionary = {}
	for raw_name: String in locked_slots.values():
		taken_bones[raw_name] = true
	for t: Dictionary in triples:
		var slot: StringName = t["slot"]
		var src: String = t["source"]
		if results.has(slot):
			continue
		if taken_bones.has(src):
			continue
		var convention: String = BoneNameDictionary.convention_for_expected_name(slot, t["matched_against"])
		results[slot] = {
			"source_bone": StringName(src),
			"confidence": t["score"],
			"convention": convention,
		}
		taken_bones[src] = true
	return results


## Apply the result of `auto_fill` to a `BoneMap` via the high-level
## `set_skeleton_bone_name` API (which routes through the correct
## `bone_map/<name>` property — sidesteps the `bonemap/` silent-overwrite trap
## documented in `reference_godot_bonemap_property.md`).
##
## Returns count of slots filled.
static func apply_to_bone_map(bm: BoneMap, fill_results: Dictionary) -> int:
	var count: int = 0
	for slot in fill_results:
		var src: StringName = fill_results[slot]["source_bone"]
		bm.set_skeleton_bone_name(slot, src)
		count += 1
	return count


## Logs per-slot fill results to the editor output panel. Confidence buckets:
## ≥0.95 = exact, 0.85-0.95 = strong, 0.6-0.85 = partial, <0.6 = unfilled.
static func log_results(fill_results: Dictionary, total_slots: int) -> void:
	var exact: int = 0
	var strong: int = 0
	var partial: int = 0
	for slot in fill_results:
		var c: float = fill_results[slot]["confidence"]
		if c >= 0.95:
			exact += 1
		elif c >= 0.85:
			strong += 1
		else:
			partial += 1
	var unfilled: int = total_slots - fill_results.size()
	print("BoneMapAutoFiller: %d/%d slots filled (exact=%d, strong=%d, partial=%d, unfilled=%d)"
			% [fill_results.size(), total_slots, exact, strong, partial, unfilled])
	for slot in fill_results:
		var r: Dictionary = fill_results[slot]
		print("  %s ← %s  (%.2f, %s)" % [String(slot), String(r["source_bone"]),
				r["confidence"], r["convention"]])


# --- internals ---------------------------------------------------------------


static func _collect_candidates(skel: Skeleton3D) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i: int in skel.get_bone_count():
		var bn: String = skel.get_bone_name(i)
		if _is_skip_bone(bn):
			continue
		out.append({
			"raw": bn,
			"norm": BoneNameNormalizer.normalize(bn),
		})
	return out


static func _score(cand: Dictionary, expected: Dictionary) -> float:
	# Exact raw match wins absolute priority — distinguishes deform from control
	# bones that normalize identically (`arm_stretch.l` vs `arm.l`).
	if cand["raw"] == expected["raw"]:
		return 1.0
	var c_tokens: PackedStringArray = cand["norm"]["tokens"]
	var e_tokens: PackedStringArray = expected["norm"]["tokens"]
	if _tokens_equal(c_tokens, e_tokens):
		return _NORMALIZED_MATCH_SCORE
	return _jaccard(c_tokens, e_tokens)


static func _tokens_equal(a: PackedStringArray, b: PackedStringArray) -> bool:
	if a.size() != b.size():
		return false
	for i: int in a.size():
		if a[i] != b[i]:
			return false
	return true


static func _jaccard(a: PackedStringArray, b: PackedStringArray) -> float:
	if a.is_empty() or b.is_empty():
		return 0.0
	var set_a: Dictionary = {}
	var set_b: Dictionary = {}
	for t: String in a:
		set_a[t] = true
	for t: String in b:
		set_b[t] = true
	var intersection: int = 0
	for k in set_a:
		if set_b.has(k):
			intersection += 1
	var union: int = set_a.size() + set_b.size() - intersection
	if union == 0:
		return 0.0
	return float(intersection) / float(union)


static func _is_skip_bone(raw_name: String) -> bool:
	var lower: String = raw_name.to_lower()
	for s: String in _SKIP_SUBSTRINGS:
		if lower.find(s) >= 0:
			return true
	return false
