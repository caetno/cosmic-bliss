@tool
class_name JiggleBone
extends MarionetteBone

# Translation-driven soft-tissue body — breast, glute, belly, etc. — spawned
# alongside the regular MarionetteBones at ragdoll build time. CLAUDE.md §15.
#
# Lives in the same simulator as the rest of the ragdoll so its collisions
# share the world space. Joint setup locks all three angular axes (no
# rotation relative to the host) and exposes a small linear excursion
# budget on each axis — physics offsets the body's position from its
# skin-driven rest, with translation-only SPD spring-damping it back.
#
# Slice 4a: the bone is spawned KINEMATIC (not in the simulator's dynamic
# list) so it tracks the skeleton bone pose directly. Once the broader SPD
# work lands the bone flips to dynamic and `_integrate_forces` evaluates
# the translation spring. Until then it provides collision-only — tentacles
# can push against the breast hull, but nothing wobbles.
#
# `bone_entry` is intentionally null on jiggle bones — they don't carry
# anatomical-frame metadata. Code that branches on it must null-check.

# Skeleton bone whose pose drives this jiggle body's rest position. For ARP
# breast bones, this is the bone's actual skeleton parent (UpperChest); for
# custom rigs the host can be different. Persisted on the spawned bone for
# the runtime SPD path to read once it lands.
@export var host_bone_name: StringName = &""
