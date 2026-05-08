---
name: User drives phase work in explicit small slices
description: Per-extension Phase work proceeds slice-by-slice; user names exact items per slice and expects nothing more
type: feedback
originSessionId: 9df2acc5-5c10-4e7d-90d5-0b3aaea4872b
---
For phased plans (Marionette_plan.md, TentacleTech roadmap, etc.) the user issues *explicit small slices* — typically 3–8 numbered subtasks per turn, with held-back items called out by name ("no solvers, no editor button — those land in the next slice"). Don't bundle ahead.

**Why:** Each slice is a review/verify checkpoint. Bundling ahead means the user reviews 1500 lines instead of 500, can't course-correct cleanly, and pays the editor-class-cache + visual-verification round-trip cost on already-shipped work.

**How to apply:**
- When the user issues a slice, do *exactly* the named items + tests + a deploy that lets them verify. Stop and report.
- When the user says "Continue" with no further detail, *propose* the next slice scope (3-bullet rundown, total file count, total LOC estimate) and wait for confirmation. Don't auto-bundle the rest of the phase.
- For spatial / geometric algorithms (muscle frames, permutation matchers, archetype solvers), the user wants a **gizmo for visual verification** before unit tests are sufficient — they'll often pair "do P2.6+P2.7" with "implement gizmo" specifically to eyeball the output on their actual rig. If a slice introduces new spatial math without a way to see it, flag that and offer to add visualization in the same slice.
- Don't commit unless explicitly asked. Default mode for Phase work is "land + report + wait for the next slice".
