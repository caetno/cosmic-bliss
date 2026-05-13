---
description: Spawn each sibling extension's explorer subagent in parallel to summarize their current state.
allowed-tools: Bash(pwd), Agent
---

You are gathering a quick snapshot of sibling extensions without context-loading them.

Steps:

1. Determine the current supervisor's extension from `pwd`. The four valid names are: `tentacletech`, `marionette`, `tenticles`, `body_field`. If `pwd` is not inside an extension dir, treat all four as siblings.

2. For each sibling extension, in a **single message with parallel Agent tool calls**, spawn its `<ext>-explorer` subagent. Each prompt should be:

   > "Give a one-paragraph status snapshot of this extension: current phase, what landed most recently (cite latest commit or PHASE_LOG entry), what's actively being worked on, any pending open questions the supervisor should know about. Under 150 words. Cite file paths."

3. When all explorers return, present a compact summary to the user — one section per sibling, each ≤150 words, with `path:line` citations preserved.

4. End with a one-line note if any sibling reports something that overlaps with the current supervisor's domain (e.g. shared bus channels, body_rhythm_phase changes, integration points).

Rules:
- Parallel fan-out, not sequential.
- Do not call `<ext>-dev` — this is a read-only survey.
- Do not invent siblings — there are exactly four extension supervisors plus a possible top-level.
