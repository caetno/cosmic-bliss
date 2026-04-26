@tool
class_name TentacleDebugColors
extends RefCounted
## Shared color encoding for the runtime debug overlay (§15.1–4) and the
## editor gizmo plugin (§15.5). Both readers consume the same constants so
## "this segment is stretched" looks the same in-game and in the inspector.
##
## Lookup helpers cover the two encodings shared across surfaces:
##   - particle inv_mass → pinned/free gradient
##   - segment stretch ratio → compressed/rest/stretched gradient

const PINNED := Color(1.0, 0.2, 0.2)            # red
const FREE := Color(1.0, 1.0, 1.0)              # white

const COMPRESSED := Color(0.2, 0.4, 1.0)
const REST := Color(1.0, 1.0, 1.0)
const STRETCHED := Color(1.0, 0.2, 0.2)

const TARGET := Color(0.4, 1.0, 0.4)
const TARGET_MARKER := Color(0.2, 0.7, 0.25)
const ANCHOR := Color(1.0, 1.0, 0.2)
const BENDING := Color(0.4, 0.85, 1.0, 0.6)

# Editor-gizmo additions for §15.5.
const SPLINE_POLYLINE := Color(0.9, 0.9, 1.0, 0.85)
const TBN_TANGENT := Color(0.85, 0.4, 1.0)      # purple
const TBN_NORMAL := Color(1.0, 0.75, 0.3)       # orange-yellow
const TBN_BINORMAL := Color(0.4, 0.95, 1.0)     # cyan

const COMPRESSED_RATIO := 0.95
const STRETCHED_RATIO := 1.05


static func particle_color(p_inv_mass: float) -> Color:
	var t: float = clampf(p_inv_mass, 0.0, 1.0)
	return PINNED.lerp(FREE, t)


static func stretch_color(p_ratio: float) -> Color:
	if p_ratio <= COMPRESSED_RATIO:
		return COMPRESSED
	if p_ratio >= STRETCHED_RATIO:
		return STRETCHED
	if p_ratio < 1.0:
		var t: float = (p_ratio - COMPRESSED_RATIO) / (1.0 - COMPRESSED_RATIO)
		return COMPRESSED.lerp(REST, t)
	var t2: float = (p_ratio - 1.0) / (STRETCHED_RATIO - 1.0)
	return REST.lerp(STRETCHED, t2)
