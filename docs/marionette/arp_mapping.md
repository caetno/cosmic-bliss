# Auto-Rig Pro → MarionetteHumanoidProfile Bone Name Mapping

Reference table consumed by `marionette_humanoid_bone_map.tres`. One entry per profile bone. The "ARP export name" column reflects the actual deform skeleton emitted by ARP's "Game Engine Export" with toe breakdown enabled, **without** the "Rename bones for Godot" option (that option only renames the 56 standard humanoid bones; toes keep their ARP names regardless, so we always map against the ARP-native vocabulary).

ARP has two commonly used naming conventions for game export:

- **Standard** — bones end in `.l` / `.r` / `.x`, with `_stretch` on the main limb segments (`arm_stretch.l`, `thigh_stretch.l`). Default for Godot/Unity exports. **This is what we map against.**
- **Unreal (UE)** — humanoid mannequin naming (`upperarm_l`, `thigh_l`, `hand_l`). Selected via the "UE Humanoid" export preset. Listed for reference; not currently shipped as a BoneMap.

---

## Bones to ignore in the source skeleton

Present in ARP exports but never mapped to profile slots:

- `c_traj` — root trajectory / world bone.
- `*_twist`, `*_twist_leaf` — IK helper deform bones (`arm_twist.l`, `thigh_twist.r`, etc.).
- `*_leaf` — tail bones ARP appends to terminal phalanges (`c_thumb3.l_leaf`, `head.x_leaf`, etc.).

Every `_leaf` and `_twist` bone in the source skeleton is silently ignored by the BoneMap (no warning needed — they have no profile counterpart by design).

## Profile slots that stay unmapped on a bare ARP rig

These are profile bones with no ARP counterpart in a typical export, so the BoneMap leaves them empty. The ragdoll builds without them.

| Profile slot           | Reason                                                                 |
|------------------------|------------------------------------------------------------------------|
| `Root`                 | `c_traj` is trajectory, not anatomical — leave empty.                  |
| `LeftEye`, `RightEye`, `Jaw` | Face bones; out-of-scope for Marionette (Reverie's responsibility). |
| `LeftToes`, `RightToes` | Metatarsal/ball bone — ARP toe breakdown attaches the 14 phalanges directly under `foot.l`/`foot.r`, no parent ball bone exists. |

---

## Root / Spine

| Profile bone   | ARP (Standard)     | ARP (UE)          |
|----------------|--------------------|-------------------|
| Root           | _(unmapped)_       | _(unmapped)_      |
| Hips           | `root.x`           | `pelvis`          |
| Spine          | `spine_01.x`       | `spine_01`        |
| Chest          | `spine_02.x`       | `spine_02`        |
| UpperChest     | `spine_03.x`       | `spine_03`        |
| Neck           | `neck.x`           | `neck_01`         |
| Head           | `head.x`           | `head`            |

ARP rigs configured with fewer spine bones (1 or 2 instead of 3) leave Chest / UpperChest unmapped.

## Face

| Profile bone   | ARP (Standard)     | ARP (UE)          |
|----------------|--------------------|-------------------|
| LeftEye        | _(unmapped)_       | `eye_l`           |
| RightEye       | _(unmapped)_       | `eye_r`           |
| Jaw            | _(unmapped)_       | `jaw`             |

Out-of-scope for Marionette runtime; the slots stay in the profile for future facial-system retargeting.

## Left Arm

| Profile bone   | ARP (Standard)         | ARP (UE)          |
|----------------|------------------------|-------------------|
| LeftShoulder   | `shoulder.l`           | `clavicle_l`      |
| LeftUpperArm   | `arm_stretch.l`        | `upperarm_l`      |
| LeftLowerArm   | `forearm_stretch.l`    | `lowerarm_l`      |
| LeftHand       | `hand.l`               | `hand_l`          |

## Left Hand (fingers)

ARP exports finger deform bones with the `c_` controller prefix even in the simplified game export — verified against the Kasumi reference rig.

| Profile bone               | ARP (Standard)    | ARP (UE)              |
|----------------------------|-------------------|-----------------------|
| LeftThumbMetacarpal        | `c_thumb1.l`      | `thumb_01_l`          |
| LeftThumbProximal          | `c_thumb2.l`      | `thumb_02_l`          |
| LeftThumbDistal            | `c_thumb3.l`      | `thumb_03_l`          |
| LeftIndexProximal          | `c_index1.l`      | `index_01_l`          |
| LeftIndexIntermediate      | `c_index2.l`      | `index_02_l`          |
| LeftIndexDistal            | `c_index3.l`      | `index_03_l`          |
| LeftMiddleProximal         | `c_middle1.l`     | `middle_01_l`         |
| LeftMiddleIntermediate     | `c_middle2.l`     | `middle_02_l`         |
| LeftMiddleDistal           | `c_middle3.l`     | `middle_03_l`         |
| LeftRingProximal           | `c_ring1.l`       | `ring_01_l`           |
| LeftRingIntermediate       | `c_ring2.l`       | `ring_02_l`           |
| LeftRingDistal             | `c_ring3.l`       | `ring_03_l`           |
| LeftLittleProximal         | `c_pinky1.l`      | `pinky_01_l`          |
| LeftLittleIntermediate     | `c_pinky2.l`      | `pinky_02_l`          |
| LeftLittleDistal           | `c_pinky3.l`      | `pinky_03_l`          |

## Right Arm & Right Hand

Mirror of left with `.r` (Standard) / `_r` (UE) suffixes. All bone names identical except the side indicator.

## Left Leg

| Profile bone   | ARP (Standard)         | ARP (UE)          |
|----------------|------------------------|-------------------|
| LeftUpperLeg   | `thigh_stretch.l`      | `thigh_l`         |
| LeftLowerLeg   | `leg_stretch.l`        | `calf_l`          |
| LeftFoot       | `foot.l`               | `foot_l`          |
| LeftToes       | _(unmapped)_           | `ball_l`          |

`LeftToes` in our profile is the ball-of-foot / metatarsal aggregate. The Kasumi reference export has no such bone — the 14 toe phalanges parent directly under `foot.l`. Slot stays unmapped; toe phalanges still attach correctly post-retarget.

## Right Leg

Mirror of Left Leg with `.r` / `_r` suffixes.

## Left Toes (14 bones, requires ARP toe breakdown)

ARP emits these only when "Toes Breakdown" is enabled in the rig setup. All use the `c_toes_*` prefix in the game export.

| Profile bone             | ARP (Standard)         | ARP (UE) ⚠ verify    |
|--------------------------|------------------------|-----------------------|
| LeftBigToeProximal       | `c_toes_thumb1.l`      | `big_toe_01_l`        |
| LeftBigToeDistal         | `c_toes_thumb2.l`      | `big_toe_02_l`        |
| LeftToe2Proximal         | `c_toes_index1.l`      | `index_toe_01_l`      |
| LeftToe2Intermediate     | `c_toes_index2.l`      | `index_toe_02_l`      |
| LeftToe2Distal           | `c_toes_index3.l`      | `index_toe_03_l`      |
| LeftToe3Proximal         | `c_toes_middle1.l`     | `middle_toe_01_l`     |
| LeftToe3Intermediate     | `c_toes_middle2.l`     | `middle_toe_02_l`     |
| LeftToe3Distal           | `c_toes_middle3.l`     | `middle_toe_03_l`     |
| LeftToe4Proximal         | `c_toes_ring1.l`       | `ring_toe_01_l`       |
| LeftToe4Intermediate     | `c_toes_ring2.l`       | `ring_toe_02_l`       |
| LeftToe4Distal           | `c_toes_ring3.l`       | `ring_toe_03_l`       |
| LeftToe5Proximal         | `c_toes_pinky1.l`      | `pinky_toe_01_l`      |
| LeftToe5Intermediate     | `c_toes_pinky2.l`      | `pinky_toe_02_l`      |
| LeftToe5Distal           | `c_toes_pinky3.l`      | `pinky_toe_03_l`      |

## Right Toes

Mirror of Left Toes with `.r` / `_r` suffixes.

---

## Reference rig

- **Character**: Kasumi (`game/scenes/kasumi_local.tscn`, sourced from `game/assets/Kasumi/Kasumi_game.glb`).
- **Skeleton size**: 116 bones (84 anatomical + `c_traj` + `*_leaf` + `*_twist` helpers).
- **Export preset**: ARP Game Engine Export, Standard naming, toe breakdown enabled, **"Rename bones for Godot" off**.
- **ARP version**: _record on next export._

Verified against this rig: every Standard ARP name in the tables above. UE column for toes still marked ⚠ verify.
