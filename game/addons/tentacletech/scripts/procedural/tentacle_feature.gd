@tool
class_name TentacleFeature
extends Resource
## Abstract base for every TentacleMesh feature subclass (§10.2 catalog).
##
## Subclasses override `_apply(ctx)` to mutate the BakeContext — adding
## geometry, writing color/UV1/CUSTOM0 channels — and `_get_required_masks()`
## to declare which channels they *write*. The bake driver uses that table
## to validate ordering: a feature whose look depends on another's mask
## must not run before that mask is authored.
##
## §5.0 partition rule: every feature subclass must state which layer owns
## it (geometry vs vertex shader vs fragment shader). The TentacleMesh
## proposal (`docs/proposals/TentacleMesh_proposal.md`) and architecture doc
## §5.0 are the canonical references.

@export var enabled: bool = true :
	set(v):
		if enabled == v: return
		enabled = v
		emit_changed()


# Default no-op. Subclasses override.
func _apply(_ctx: BakeContext) -> void:
	pass


# Returns the names of mask channels this feature writes (CH_* constants
# from BakeContext). Default empty.
func _get_required_masks() -> PackedStringArray:
	return PackedStringArray()


# Slice 5H — write this feature's contribution to the 2D radial-
# perturbation silhouette image carried by `p_ctx`. Default no-op.
# Implementations deposit Gaussians / strips / rings into the image
# via the helpers on `SilhouetteBakeContext` (`add_gaussian`,
# `add_axial_ring`, `add_axial_strip`). Bake is ADDITIVE — overlapping
# features sum; subtractive behavior (sucker pits) emit negative
# amplitudes.
func bake_silhouette_contribution(_ctx: SilhouetteBakeContext) -> void:
	pass
