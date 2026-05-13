---
description: Append a nudge to a sibling extension's inbox. Usage: /handoff <ext> <message>
argument-hint: <ext> <message>
allowed-tools: Bash(date:*), Bash(pwd), Read, Edit, Write
---

You are dropping a short message in a sibling extension's inbox. Arguments: $ARGUMENTS

Steps:

1. Parse the first token as `<ext>` (one of: `tentacletech`, `marionette`, `tenticles`, `body_field`). The rest is the message body. If `<ext>` is missing or unknown, ask the user to retry with a valid extension name and stop.

2. Determine the *current* supervisor's extension from `pwd` (same matching as `/inbox`). If you can't determine it (top-level Claude), use the label `top-level`.

3. Append to `.claude/inbox/<ext>.md` a new entry. Format:
   ```
   ### YYYY-MM-DD HH:MM <from-extension>
   <message body>
   ```
   Use `date '+%Y-%m-%d %H:%M'` for the timestamp.

4. Confirm to the user: "Handed off to <ext>: <one-line preview>."

Rules:
- Keep the message short (one or two sentences). If the user gave a long message, suggest the change probably warrants a `docs/Cosmic_Bliss_Update_*.md` instead, and ask whether to proceed anyway.
- The inbox is for nudges and FYIs, not design-level changes. Design changes go via update docs.
- Do not modify any other file. Do not phone the sibling supervisor synchronously — handoff is async.
