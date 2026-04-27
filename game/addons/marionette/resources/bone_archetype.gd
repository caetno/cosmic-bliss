class_name BoneArchetype
extends RefCounted

# Joint behavior class for a bone, dispatched to a per-archetype solver at
# authoring time (P2.6). Public-API resource; uses anatomical vocabulary.

enum Type {
	BALL,           # 3-DOF spherical: shoulder, hip
	HINGE,          # 1-DOF flexion: elbow, knee, finger/toe phalanges (non-proximal)
	SADDLE,         # 2-DOF flexion + abduction: wrist, ankle, MCP, MTP
	PIVOT,          # 1-DOF axial rotation; reserved (no humanoid default)
	SPINE_SEGMENT,  # small-ROM 3-DOF vertebra-like: spine, neck, head
	CLAVICLE,       # protraction/elevation; small-ROM 3-DOF
	ROOT,           # pelvis / world root; not driven by SPD
	FIXED,          # kinematic only (jaw, eyes — out of Marionette scope)
}

const COUNT: int = 8

const _NAMES: Array[StringName] = [
	&"Ball",
	&"Hinge",
	&"Saddle",
	&"Pivot",
	&"SpineSegment",
	&"Clavicle",
	&"Root",
	&"Fixed",
]


static func to_name(t: Type) -> StringName:
	var i: int = int(t)
	if i < 0 or i >= _NAMES.size():
		return &""
	return _NAMES[i]


static func from_name(n: StringName) -> int:
	var idx: int = _NAMES.find(n)
	return idx  # -1 if missing


static func all() -> Array[Type]:
	return [
		Type.BALL,
		Type.HINGE,
		Type.SADDLE,
		Type.PIVOT,
		Type.SPINE_SEGMENT,
		Type.CLAVICLE,
		Type.ROOT,
		Type.FIXED,
	]
