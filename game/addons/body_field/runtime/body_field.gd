@tool
class_name BodyField
extends Node3D

## Per-hero body field node. Owns the tet substrate's runtime state
## (allocated at B1+: tet mesh + barycentric weights + bone SDF buffer
## + per-tick compute dispatch). B0 is a placeholder so the integration
## brief's BodyField node accessor reference resolves to a real class.

## B0 scaffolding only — exists purely so the bridge test can verify
## ClassDB.instantiate returns a usable object. Delete the moment a
## real method earns its place on BodyField.
func _bridge_test_marker() -> String:
	return "body_field ok"
