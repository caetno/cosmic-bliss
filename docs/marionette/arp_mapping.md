# Auto-Rig Pro → MarionetteHumanoidProfile Bone Name Mapping

Reference table used by the BoneMap auto-populate path in P1.2. One entry per profile bone. The "ARP export name" column assumes ARP's default **game engine export** rig (the simplified deform skeleton, not the internal controller hierarchy).

ARP has two commonly used naming conventions for game export:

- **Standard** — bones end in `.l` / `.r` / `.x`, with `_stretch` on the main limb segments (`arm_stretch.l`, `thigh_stretch.l`). Default for Godot/Unity exports.
- **Unreal (UE)** — humanoid mannequin naming (`upperarm_l`, `thigh_l`, `hand_l`). Selected via the "UE Humanoid" export preset.

Both are listed where they differ. Unlisted bones share the same name across both.

Unverified entries are marked **⚠ verify** — the name is the best guess based on ARP conventions but hasn't been checked against a real ARP export with toe breakdown enabled.

---

## Root / Spine

| Profile bone   | ARP (Standard)     | ARP (UE)          |
|----------------|--------------------|-------------------|
| Root           | `root.x`           | `root`            |
| Hips           | `hips.x`           | `pelvis`          |
| Spine          | `spine_01.x`       | `spine_01`        |
| Chest          | `spine_02.x`       | `spine_02`        |
| UpperChest     | `spine_03.x`       | `spine_03`        |
| Neck           | `neck.x`           | `neck_01`         |
| Head           | `head.x`           | `head`            |

Note: ARP rigs with fewer spine bones (1 or 2 instead of 3) leave Chest / UpperChest unmapped. The P1.2 auto-populate path should warn when Chest or UpperChest is missing rather than hard-fail.

## Face

| Profile bone   | ARP (Standard)     | ARP (UE)          |
|----------------|--------------------|-------------------|
| LeftEye        | `c_eye.l`          | `eye_l`           |
| RightEye       | `c_eye.r`          | `eye_r`           |
| Jaw            | `c_jawbone.x`      | `jaw`             |

Face bones are out-of-scope for Marionette itself (jaw + eyes are Kinematic, driven by the facial system), but they still belong in the profile for retargeting completeness.

## Left Arm

| Profile bone   | ARP (Standard)         | ARP (UE)          |
|----------------|------------------------|-------------------|
| LeftShoulder   | `shoulder.l`           | `clavicle_l`      |
| LeftUpperArm   | `arm_stretch.l`        | `upperarm_l`      |
| LeftLowerArm   | `forearm_stretch.l`    | `lowerarm_l`      |
| LeftHand       | `hand.l`               | `hand_l`          |

## Left Hand (fingers)

| Profile bone               | ARP (Standard)    | ARP (UE)              |
|----------------------------|-------------------|-----------------------|
| LeftThumbMetacarpal        | `thumb1.l`        | `thumb_01_l`          |
| LeftThumbProximal          | `thumb2.l`        | `thumb_02_l`          |
| LeftThumbDistal            | `thumb3.l`        | `thumb_03_l`          |
| LeftIndexProximal          | `index1.l`        | `index_01_l`          |
| LeftIndexIntermediate      | `index2.l`        | `index_02_l`          |
| LeftIndexDistal            | `index3.l`        | `index_03_l`          |
| LeftMiddleProximal         | `middle1.l`       | `middle_01_l`         |
| LeftMiddleIntermediate     | `middle2.l`       | `middle_02_l`         |
| LeftMiddleDistal           | `middle3.l`       | `middle_03_l`         |
| LeftRingProximal           | `ring1.l`         | `ring_01_l`           |
| LeftRingIntermediate       | `ring2.l`         | `ring_02_l`           |
| LeftRingDistal             | `ring3.l`         | `ring_03_l`           |
| LeftLittleProximal         | `pinky1.l`        | `pinky_01_l`          |
| LeftLittleIntermediate     | `pinky2.l`        | `pinky_02_l`          |
| LeftLittleDistal           | `pinky3.l`        | `pinky_03_l`          |

## Right Arm & Right Hand

Mirror of left with `.r` (Standard) / `_r` (UE) suffixes. All bone names identical except the side indicator — spelled out by the auto-populate path at P1.2.

## Left Leg

| Profile bone   | ARP (Standard)         | ARP (UE)          |
|----------------|------------------------|-------------------|
| LeftUpperLeg   | `thigh_stretch.l`      | `thigh_l`         |
| LeftLowerLeg   | `leg_stretch.l`        | `calf_l`          |
| LeftFoot       | `foot.l`               | `foot_l`          |
| LeftToes       | `toes_01.l`            | `ball_l`          |

`LeftToes` in our profile is the ball-of-foot / metatarsal aggregate bone — parent to the 14 individual toe phalanges. ARP without toe breakdown exports a single `toes_01.l` / `ball_l` and no children; ARP with toe breakdown exports `toes_01.l` as the parent of named toe phalanges.

## Right Leg

Mirror of Left Leg with `.r` / `_r` suffixes.

## Left Toes (new in MarionetteHumanoidProfile — 14 bones per foot)

The 28 toe phalanges are added as children of `LeftToes` / `RightToes`. ARP emits these only when "Toes Breakdown" is enabled in the rig setup; without it the 28 entries will be unmapped by the auto-populate path and must be filled manually or left out (the ragdoll builds without them — toes stay Kinematic).

| Profile bone             | ARP (Standard) ⚠ verify         | ARP (UE) ⚠ verify      |
|--------------------------|-------------------------------|------------------------|
| LeftBigToeProximal       | `c_toes_thumb1.l`             | `big_toe_01_l`         |
| LeftBigToeDistal         | `c_toes_thumb2.l`             | `big_toe_02_l`         |
| LeftToe2Proximal         | `c_toes_index1.l`             | `index_toe_01_l`       |
| LeftToe2Intermediate     | `c_toes_index2.l`             | `index_toe_02_l`       |
| LeftToe2Distal           | `c_toes_index3.l`             | `index_toe_03_l`       |
| LeftToe3Proximal         | `c_toes_middle1.l`            | `middle_toe_01_l`      |
| LeftToe3Intermediate     | `c_toes_middle2.l`            | `middle_toe_02_l`      |
| LeftToe3Distal           | `c_toes_middle3.l`            | `middle_toe_03_l`      |
| LeftToe4Proximal         | `c_toes_ring1.l`              | `ring_toe_01_l`        |
| LeftToe4Intermediate     | `c_toes_ring2.l`              | `ring_toe_02_l`        |
| LeftToe4Distal           | `c_toes_ring3.l`              | `ring_toe_03_l`        |
| LeftToe5Proximal         | `c_toes_pinky1.l`             | `pinky_toe_01_l`       |
| LeftToe5Intermediate     | `c_toes_pinky2.l`             | `pinky_toe_02_l`       |
| LeftToe5Distal           | `c_toes_pinky3.l`             | `pinky_toe_03_l`       |

## Right Toes

Mirror of Left Toes with `.r` / `_r` suffixes.

---

## Verification checklist (do before relying on this mapping in code)

- [ ] Export a known ARP character with **toe breakdown enabled** and dump the skeleton bone list.
- [ ] Confirm every `.l` / `.r` suffix convention (some ARP versions use `_l` / `_r` even in Standard mode).
- [ ] Confirm whether ARP prefixes `c_` on deform bones in the game export, or only on controller bones.
- [ ] Cross-check with the ARP version in the reference character. ARP's naming has shifted between major versions; record the ARP version used for our reference rig in this doc.

## Reference rig

- ARP version: _TBD — record here when the reference rig lands._
- Export preset: _TBD — Standard / UE / other._
- Toe breakdown: _TBD — enabled / disabled._
