---
name: Use user-placed test setup — cameras, scenes, tuned values — don't fabricate
description: When the user has placed cameras / authored scenes / dialled in tuning values, use those exactly; don't invent parallel setups or revert to "sensible defaults"
type: feedback
originSessionId: 4205a866-d8cd-463a-9a93-303e1378853d
---
When the user places `Camera3D` nodes in a scene, sets up a test scene, or dials in specific tuning values, use exactly that setup. Don't fabricate camera positions in code, don't generate parallel "equivalent" test scenes, and don't reset tuned shader_parameters in `.tres` edits.

**Why:** During the eye-shader session I spawned a fresh Camera3D in the screenshot script with my own position guess, then had to rip it out when the user said "I put two cameras into the scene, so you know the angles." The user-placed `Front` / `Side` cameras in `more_eyes.tscn` were tuned by hand for the views that expose the artifacts they care about. Same pattern with material values — when the user has set `limbus_intensity = 2.0` or `iris_radius = 0.0071`, those are deliberate; my edits should preserve them, not "round to defaults".

**How to apply:**

- **Screenshot tooling:** read existing `Camera3D` nodes from the scene by name (e.g., `inst.find_child("Side", true, false) as Camera3D`) and call `cam.current = true`. Don't construct one. If the user adds a new camera, the script picks it up via the `CAMERA` const change only.
- **Material edits:** when adding a new shader_parameter to a `.tres`, leave existing parameters untouched. Editor / linter changes to other params are intentional — don't revert them. The system-reminder noting an external `.tres` modification is your cue to read the current state and proceed without reverting.
- **Test scenes:** if the user has authored one, render through it. Don't generate a parallel test setup that does "the same thing".
- **Per-run overrides:** for ad-hoc parameter sweeps, use environment variables in the screenshot script (e.g., `EYE_PUPIL_RADIUS=0.002`) rather than editing the `.tres` and reverting after.
