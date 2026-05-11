@tool
class_name BoneNameNormalizer
extends RefCounted

## Normalizes raw skeleton bone names to a canonical token set + side tag.
## Used by BoneMapAutoFiller to compare candidate source bones against
## per-convention dictionary entries (also normalized through this pipeline).
##
## Pipeline:
##   1. Strip raw namespace prefixes that contain digits (`bip01_`, `mixamorig1:`)
##      so the digit doesn't survive into the token list and confuse phalanx
##      indexing.
##   2. Insert separator after Left/Right word-prefix (catches `Leftc_*` style).
##   3. Insert separators at camelCase / letter↔digit boundaries.
##   4. Lowercase.
##   5. Tokenize on `_-.: `.
##   6. Drop noise tokens (namespace + helper markers).
##   7. Extract side tag from first or last token if it's a recognized side marker.
##   8. Strip leading zeros from purely-digit tokens (`01` → `1`).
##
## Returns Dictionary { tokens: PackedStringArray, side: Side, raw: String }.

enum Side { NONE, LEFT, RIGHT, CENTER }

# Tokens classified as side markers when they appear at the first or last
# position. `x` is the ARP/Blender center marker (`spine_01.x`).
const _SIDE_TOKEN: Dictionary = {
	"left": Side.LEFT, "right": Side.RIGHT,
	"l": Side.LEFT, "r": Side.RIGHT,
	"x": Side.CENTER,
}

# Tokens dropped before scoring. Either rig-namespace prefixes (mixamorig, def,
# org, mch, vis, wgt, bip01, bip, c) or generic helper markers (stretch, twist,
# leaf, ik, fk, etc.). Token-set scoring needs noise removed so candidates
# from different conventions match the same dictionary entry on overlap.
const _NOISE_TOKENS: Dictionary = {
	# Convention namespace prefixes
	"mixamorig": true, "mixamorig1": true, "mixamorig2": true, "mixamorig3": true,
	"def": true, "org": true, "mch": true, "vis": true, "wgt": true,
	"bip01": true, "bip": true,
	# ARP controller prefix (`c_thumb1.l` → drop `c`, keep `thumb`+`1`)
	"c": true,
	# Rigify finger prefix (`DEF-f_index.01.L` → drop `f`, keep `index`+`1`)
	"f": true,
	# Helper / control / tweak markers
	"stretch": true, "twist": true, "twk": true, "leaf": true,
	"helper": true, "target": true, "tweak": true, "master": true,
	"pole": true, "ik": true, "fk": true, "drv": true, "rot": true, "ref": true,
	"scale": true, "fix": true, "snap": true,
	"track": true, "handle": true, "offset": true,
	"roll": true, "rock": true, "roll1": true, "roll2": true, "rock1": true, "rock2": true,
	"basetoe": true, "base": true, "end": true,
	"nostr": true, "swing": true, "parent": true, "widget": true,
	"pre": true, "bend": true, "all": true,
	"p": true, "pos": true,
}


## Substring prefixes containing digits — stripped raw before tokenizing so the
## namespace digit (`Bip01`, `mixamorig1:`) doesn't pollute the token stream.
const _RAW_NAMESPACE_STRIPS: Array[String] = [
	"bip01_", "bip01:",
	"mixamorig1:", "mixamorig2:", "mixamorig3:",
]


static func normalize(raw_name: String) -> Dictionary:
	# Step 1: strip raw namespace prefixes that carry digits.
	var s: String = raw_name
	var lower_s: String = s.to_lower()
	for pfx: String in _RAW_NAMESPACE_STRIPS:
		if lower_s.begins_with(pfx):
			s = s.substr(pfx.length())
			lower_s = s.to_lower()
			break
	# Step 2: split off Left/Right word-prefix even when not separated (e.g.
	# `Leftc_toes_thumb1` → `Left_c_toes_thumb1`). camelCase rule alone misses
	# this because `c` is lowercase, no transition.
	if lower_s.begins_with("left") and s.length() > 4:
		s = s.substr(0, 4) + "_" + s.substr(4)
	elif lower_s.begins_with("right") and s.length() > 5:
		s = s.substr(0, 5) + "_" + s.substr(5)
	# Step 3: insert separators at camelCase / letter↔digit transitions.
	s = _split_camel_and_digits(s)
	# Step 4: lowercase.
	s = s.to_lower()
	# Step 5: tokenize on common separators.
	var raw_tokens: PackedStringArray = PackedStringArray()
	var current: String = ""
	for i: int in s.length():
		var c: String = s[i]
		if c == "_" or c == "-" or c == "." or c == ":" or c == " ":
			if not current.is_empty():
				raw_tokens.append(current)
				current = ""
		else:
			current += c
	if not current.is_empty():
		raw_tokens.append(current)
	# Step 6: drop noise tokens.
	var filtered: PackedStringArray = PackedStringArray()
	for t: String in raw_tokens:
		if not _NOISE_TOKENS.has(t):
			filtered.append(t)
	# Step 7: extract side tag from first or last token.
	# Side stored as `int` in the result Dictionary. The Side enum is exposed
	# for callers to compare against, but typed `Side` parameters / returns
	# trigger a 4.6 GDScript parser quirk where the same enum is treated as
	# distinct types when crossed across class boundaries — workaround is to
	# pass / return `int` everywhere the value crosses a function boundary.
	var side: int = Side.NONE
	var tokens: PackedStringArray = PackedStringArray()
	if filtered.size() > 0 and _SIDE_TOKEN.has(filtered[0]):
		side = _SIDE_TOKEN[filtered[0]]
		for i: int in range(1, filtered.size()):
			tokens.append(filtered[i])
	elif filtered.size() > 0 and _SIDE_TOKEN.has(filtered[-1]):
		side = _SIDE_TOKEN[filtered[-1]]
		for i: int in range(0, filtered.size() - 1):
			tokens.append(filtered[i])
	else:
		tokens = filtered.duplicate()
	# Step 8: normalize digit-only tokens (`01` → `1`).
	for i: int in tokens.size():
		if tokens[i].is_valid_int():
			tokens[i] = str(tokens[i].to_int())
	return {
		"tokens": tokens,
		"side": side,
		"raw": raw_name,
	}


## Side enforced as a hard constraint: source bone with side L can never
## fill a Right-prefixed slot, and vice versa. Center / NONE slots accept
## NONE / CENTER candidates only (rejects sided candidates).
## Returns int (Side enum value); see comment in `normalize` for the typing
## rationale.
static func slot_required_side(slot_name: StringName) -> int:
	var s: String = String(slot_name)
	if s.begins_with("Left"):
		return Side.LEFT
	if s.begins_with("Right"):
		return Side.RIGHT
	return Side.NONE


## Returns true when a candidate's detected side is compatible with the slot's
## required side. NONE / CENTER are interchangeable on the candidate side.
static func sides_compatible(candidate_side: int, slot_side: int) -> bool:
	if slot_side == Side.LEFT:
		return candidate_side == Side.LEFT
	if slot_side == Side.RIGHT:
		return candidate_side == Side.RIGHT
	# Center slot: candidate must be NONE or CENTER.
	return candidate_side == Side.NONE or candidate_side == Side.CENTER


static func _split_camel_and_digits(s: String) -> String:
	var out: String = ""
	for i: int in s.length():
		var c: String = s[i]
		if i > 0:
			var prev: String = s[i - 1]
			var prev_lower_letter: bool = _is_lower_letter(prev)
			var prev_letter: bool = prev_lower_letter or _is_upper_letter(prev)
			var prev_digit: bool = _is_digit(prev)
			var c_upper_letter: bool = _is_upper_letter(c)
			var c_letter: bool = c_upper_letter or _is_lower_letter(c)
			var c_digit: bool = _is_digit(c)
			if (prev_lower_letter and c_upper_letter) \
			or (prev_letter and c_digit) \
			or (prev_digit and c_letter):
				out += "_"
		out += c
	return out


static func _is_upper_letter(c: String) -> bool:
	return c.length() == 1 and c >= "A" and c <= "Z"


static func _is_lower_letter(c: String) -> bool:
	return c.length() == 1 and c >= "a" and c <= "z"


static func _is_digit(c: String) -> bool:
	return c.length() == 1 and c >= "0" and c <= "9"
