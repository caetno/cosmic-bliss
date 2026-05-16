@tool
class_name SurfaceAttachment
extends Resource

## Base class for body-surface attachments — anchors authored in Godot
## (not Blender) whose per-vertex weight on the body mesh is baked from
## the surface field's cotan-Laplacian diffusion.
##
## Subclasses (§17.5+, TT §10.4, Marionette §16) override `bake()` to
## describe their source signal (delta at a vertex, ring of seeds, etc.).
## §17.1 ships the API + storage; the three concrete subclasses are
## stubs that `push_warning` until their consumers migrate.

enum WeightMode { ADDITIVE, REPLACE }

@export var attachment_name: StringName = &""
@export var host_bone: StringName = &""
@export var weight_mode: WeightMode = WeightMode.ADDITIVE

## Populated by `BodySurfaceFieldBaker` / `BodySurfaceField.bake_all_attachments()`.
## Length == source_mesh vertex count when fresh; empty until first bake.
@export var baked_weights: PackedFloat32Array = PackedFloat32Array()

## Topology fingerprint at bake time. Mismatch with the field's
## current fingerprint means the bake is stale and consumers should
## re-bake before relying on the weights.
@export var baked_topology_fingerprint: String = ""


## Subclasses override. Receives the parent `BodySurfaceField` so they
## can call `diffuse(...)` / `diffuse_geodesic(...)`. Returns a
## per-vertex weight array of length `field.n_verts`.
func bake(field) -> PackedFloat32Array:
	push_error("SurfaceAttachment.bake() — abstract; subclass must override")
	return PackedFloat32Array()
