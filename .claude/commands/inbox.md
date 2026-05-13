---
description: Read this supervisor's inbox and clear it after acknowledgement.
allowed-tools: Bash(cat:*), Bash(pwd), Bash(git:*), Read, Edit, Write
---

You are reading the inbox for the current extension supervisor. Steps:

1. Determine which extension this terminal supervises. Use `pwd` and match against `extensions/<name>/`. The four valid names are: `tentacletech`, `marionette`, `tenticles`, `body_field`. If `pwd` is not inside an extension dir, tell the user this command is only useful in a per-extension supervisor session and stop.

2. Read `.claude/inbox/<name>.md`. The header is an HTML comment ending in `-->`. Anything below the comment is real entries (or blank if empty).

3. If there are real entries:
   - Print them to the user verbatim.
   - Ask whether to clear (default yes). If the user confirms, rewrite the file back to just the header comment (use the same header that was already there — preserve it).
   - If the user says no, leave the file alone.

4. If the inbox is empty, just say "Inbox empty." and stop.

Do not invent entries. Do not act on entries — only surface them. The supervisor decides what to do.
