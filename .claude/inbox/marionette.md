<!--
Inbox for the Marionette supervisor.

Append-only during a session. Cleared by `/inbox` after read.
Each entry: `### YYYY-MM-DD HH:MM <from-extension>` then a short body.

Use for nudges and FYIs that don't warrant an update doc.
For design-level changes to Marionette's public surface, ask the
caller to drop a `docs/Cosmic_Bliss_Update_*.md` instead.
-->

### 2026-05-14 07:54 top-level
Cross-extension audit on 2026-05-14 surfaced 6 SHARP + 8 LATENT + 1 tension on Marionette plus four apply-pass items (05-14 §7.4–§7.7 in `Marionette_plan.md` §15/§16/§17/§18). Full inventory + recommended priorities in `docs/Cosmic_Bliss_Update_2026-05-14-02_cross_extension_audit_findings.md` (PR #10); P0 items are the `body_rhythm_phase` integrator-owner decision + publish (Mar-I14) and the four doc apply-pass edits.

### 2026-05-14 09:30 top-level
Named the next cross-extension testable scenario: *ragdoll with muscle tension that tries to hold a pose while constrained and being penetrated* (kasumi, three tension settings). Full readiness verdict + Marionette slice list in `docs/Cosmic_Bliss_Update_2026-05-14-03_ragdoll_under_tension_scenario.md` §3. Slice order (Marionette-side, in priority): (1) **Mar-I6 snapshot fix** at `marionette_bone.cpp:246` — gates everything else because it biases the high-tension regime that headlines the scenario; (2) **Mar-I5 snapshot fix** at `jiggle_bone.gd:66,71` (in-scope because kasumi has jiggle bones); (3) **`body_rhythm_phase` publisher** (Mar-I14, ride along — P0 anyway); (4) **apply-pass §7.4–§7.7** (one bundled doc PR); (5) **P10.2 `PinAnchor` minimum slice** — hard pin only, no IK soup; (6) **P10.7 `body_strain` publisher minimum slice** — stub scalar per region, see 05-14-03 §3 for the contract. Full P10 composer (Mar-I8/I9, P10.6 pump) and Phase 11 (`apply_hit`, `GrabTarget`) are out of scope here — Reverie-era work. Project CLAUDE.md "Never" bullet on snapshot discipline tightened in this PR; the bug fixes (1) and (2) close out the cross-cutting §4.1 code violations.
