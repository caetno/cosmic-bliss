---
name: Top-level Claude reviews extension work
description: For Cosmic Bliss, the repo-root Claude reviews work done by per-extension sub-Claudes; do not propose a separate code-review agent
type: feedback
originSessionId: 8cf9c35d-3b1b-4d72-82e5-d04d8e6ae043
---
For the Cosmic Bliss monorepo, the user runs sub-Claudes inside `extensions/<name>/` (tentacletech, marionette, etc.) for implementation, and bounces up to a top-level Claude (started at the repo root) for cross-cutting review.

**Why:** When asked whether to set up a dedicated `code-reviewer` subagent, the user explicitly chose to keep top-level Claude as the reviewer. The top-level holds cross-cutting context (architecture docs, contracts between extensions, build system, doc consistency) that a sibling review agent would either duplicate or be worse without. Confirmed 2026-04-25.

**How to apply:**
- When a sub-Claude finishes a phase or milestone, expect to be asked for review at the top level. Read against the architecture doc, verify build artifacts and tests actually exist, flag spec divergences.
- Do not propose spawning a `code-reviewer` subagent for ongoing review — only suggest the existing `/review`, `/security-review`, `/ultrareview` skills for ad-hoc focused passes.
- The pattern is documented in `extensions/tentacletech/CLAUDE.md` under "Workflow"; if other extensions adopt the same pattern, mirror that section.
