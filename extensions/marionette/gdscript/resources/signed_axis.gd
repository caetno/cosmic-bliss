class_name SignedAxis
extends RefCounted

# One of the six signed cardinal directions in 3D. Used by BoneEntry to encode
# the bone-local→anatomical permutation: which signed bone-local axis maps to
# anatomical flex (+X), along-bone (+Y), and abduction (+Z).
#
# Encoding: low bit = sign (0 = +, 1 = -), upper bits = axis index (X=0, Y=1, Z=2).
# This makes index_of/sign_of/inverse cheap bit ops.

enum Axis {
	PLUS_X = 0,
	MINUS_X = 1,
	PLUS_Y = 2,
	MINUS_Y = 3,
	PLUS_Z = 4,
	MINUS_Z = 5,
}

const COUNT: int = 6


static func to_vector3(a: Axis) -> Vector3:
	match a:
		Axis.PLUS_X: return Vector3(1.0, 0.0, 0.0)
		Axis.MINUS_X: return Vector3(-1.0, 0.0, 0.0)
		Axis.PLUS_Y: return Vector3(0.0, 1.0, 0.0)
		Axis.MINUS_Y: return Vector3(0.0, -1.0, 0.0)
		Axis.PLUS_Z: return Vector3(0.0, 0.0, 1.0)
		Axis.MINUS_Z: return Vector3(0.0, 0.0, -1.0)
	return Vector3.ZERO


static func sign_of(a: Axis) -> int:
	return -1 if (int(a) & 1) != 0 else 1


static func index_of(a: Axis) -> int:
	return int(a) >> 1


static func inverse(a: Axis) -> Axis:
	return (int(a) ^ 1) as Axis


static func from_components(axis_index: int, axis_sign: int) -> Axis:
	var bit: int = 1 if axis_sign < 0 else 0
	return ((axis_index << 1) | bit) as Axis


static func to_name(a: Axis) -> StringName:
	match a:
		Axis.PLUS_X: return &"+X"
		Axis.MINUS_X: return &"-X"
		Axis.PLUS_Y: return &"+Y"
		Axis.MINUS_Y: return &"-Y"
		Axis.PLUS_Z: return &"+Z"
		Axis.MINUS_Z: return &"-Z"
	return &""
