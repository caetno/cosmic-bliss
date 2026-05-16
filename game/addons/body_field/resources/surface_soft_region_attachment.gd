@tool
class_name SurfaceSoftRegionAttachment
extends SurfaceAttachment

## Stub. Concrete bake() lands at Marionette §16 (soft-region clusters
## migrate from Euclidean SDF blend to geodesic-on-surface blend
## derived from the body surface field).

func bake(_field) -> PackedFloat32Array:
	push_warning("SurfaceSoftRegionAttachment.bake() — stub; concrete impl lands at Marionette §16 soft-region geodesic blend")
	return PackedFloat32Array()
