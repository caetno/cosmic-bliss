---
description: Create a new docs/Cosmic_Bliss_Update_<date>_<slug>.md skeleton for a cross-cutting design change. Usage: /update-doc <slug>
argument-hint: <slug>
allowed-tools: Bash(date:*), Bash(pwd), Bash(ls:*), Read, Write
---

You are scaffolding a new cross-cutting update doc. Argument: $ARGUMENTS

Steps:

1. Parse `<slug>` from the argument. It should be lowercase, underscore-separated, descriptive (e.g. `rhythm_phase_rename`, `orifice_rim_v2`). If it's missing, ask the user for one.

2. Compute today's date as `YYYY-MM-DD` via `date '+%Y-%m-%d'`. If a file `docs/Cosmic_Bliss_Update_<date>_<slug>.md` already exists, append `-02`, `-03`, etc. to disambiguate (check with `ls docs/`).

3. Determine the originating extension (from `pwd`, same as `/inbox` and `/handoff`). Use `top-level` if not in an extension.

4. Write the file with this skeleton (fill in `<placeholders>` from context where you can):

   ```markdown
   # Cosmic Bliss Update — <date> — <human-readable title>

   **Originating supervisor:** <ext>
   **Status:** proposed

   ## What changes
   <one paragraph describing the design change>

   ## Affected extensions / systems
   - <ext>: <what changes here>
   - <sibling>: <what they need to do; or "no action, FYI">

   ## Rationale
   <why; cite invariants or pain points>

   ## Migration plan
   1. <step>
   2. <step>

   ## Open questions
   - <Q1>

   ## Acceptance
   <what "applied" looks like; how each affected supervisor confirms>
   ```

5. After writing, tell the user the path and remind them: once applied to the canonical doc(s), the update doc remains as changelog (per root CLAUDE.md).

Do not edit any other file. Do not pre-fill placeholders with speculation — leave them as `<...>` for the user.
