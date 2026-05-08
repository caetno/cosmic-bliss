---
name: Diagnostic style — kill the suspect to confirm cause before fixing
description: When a visual artifact has multiple plausible causes, ablate candidates one at a time before writing a fix
type: feedback
originSessionId: 4205a866-d8cd-463a-9a93-303e1378853d
---
When a visible artifact (white ring, dark band, bright spot, etc) could plausibly come from several inputs (texture content, shader math, lighting, geometry), don't speculate-then-implement. Zero out one candidate at a time and re-render to isolate the actual contributor, then fix that.

**Why:** During the eye-shader session I burned several iterations on wrong fixes — UV remap (caused stretching, user flagged), halo luminance dampening (changed nothing visibly), narrow ring suppression band (fought the wrong target) — because I assumed the texture's bright halo was the "white ring" the user kept reporting. One quick diagnostic test (`cornea_smoothness = 0` in the screenshot script's material override) made the ring vanish entirely, immediately revealing it was cornea spec catching the cornea-bulge curvature transition, not the texture. Should have done that first.

**How to apply:** When the user reports a visual artifact in shader/lighting work and multiple inputs could be producing it:
1. List the candidate inputs (texture luminance, cornea spec, normal map, blend mask, geometry curvature, env reflection, …).
2. Render a baseline.
3. Zero out / kill one candidate at a time via material override in the screenshot script — render, compare. Whichever zero-out kills the artifact identifies the cause.
4. Then fix the actual contributor; don't blanket-suppress the others.

Verifying inputs by ablation is cheap (one render per test) and protects against shipping a confidently-wrong fix that papers over symptoms while the real cause persists. Especially valuable in shaders/lighting/post-fx where many effects compose into the final pixel and visual reasoning alone often picks the wrong suspect.
