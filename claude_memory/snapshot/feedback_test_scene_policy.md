---
name: Test scene policy — simple, with confirmation
description: For Cosmic Bliss, simple Godot test scenes are allowed but require user confirmation before creating; complex authored data (animations, baked lighting, Resource pipelines) is forbidden
type: feedback
originSessionId: 8cf9c35d-3b1b-4d72-82e5-d04d8e6ae043
---
For the Cosmic Bliss Godot project, test scenes follow a refined policy (was previously "no test scenes ever"):

**Allowed with explicit user confirmation:** simple test scenes — node tree + scripts + minimal `@export` properties.

**Forbidden, even with confirmation:** animation tracks, `AnimationPlayer` / `AnimationTree` setups, baked lighting, side-authored `Resource` files, multi-asset pipelines, rigged characters. These require a separate explicit ask.

**Why:** Past failure mode was Claude helpfully scaffolding out animation rigs and resource pipelines that the user then had to hand-clean. The cost of cleanup outweighed the help. Confirmed 2026-04-26 after the tentacletech sub-Claude generated `test_solver_visual.tscn` (small, useful — accepted retroactively) and the policy was relaxed in light of that being an OK call.

**How to apply:**
- Before creating any `.tscn`, ask the user. Don't assume the previous "no test scenes" rule still applies, and don't assume the new "simple is fine" rule means you can skip the ask.
- If the user gives you a feature that visually needs verification, prefer headless GDScript tests (`extends SceneTree`, `--script` invocation) first. Only propose a `.tscn` if visual confirmation is genuinely needed.
- The rule is documented in the top-level `CLAUDE.md` ("Working style" + "Never" sections), `extensions/tentacletech/CLAUDE.md`, and `docs/architecture/TentacleTech_Architecture.md` §14. If you find an outdated phrasing in a CLAUDE.md, update it.
