@tool
class_name SurfaceOrificeRimAttachment
extends SurfaceAttachment

## Stub. Concrete bake() lands TT-side at the §10.4 rim-authoring
## migration (orifice rim particles replace Blender-authored anchor
## bones; weights bake from the surface field).

func bake(_field) -> PackedFloat32Array:
	push_warning("SurfaceOrificeRimAttachment.bake() — stub; concrete impl lands at TentacleTech §10.4 rim-authoring migration")
	return PackedFloat32Array()
