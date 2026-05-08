---
name: Marionette test runner + class cache refresh
description: How to run tests/run_tests.gd from a headless Godot, and the non-obvious editor-scan step required after introducing new class_name globals
type: reference
originSessionId: 9df2acc5-5c10-4e7d-90d5-0b3aaea4872b
---
The test runner is a `SceneTree` script at `extensions/marionette/tests/run_tests.gd`. Invoke it via absolute path; the project itself lives at `game/`.

```bash
godot --headless --path /home/caetano/desktop/cosmic-bliss/game \
      --script /home/caetano/desktop/cosmic-bliss/extensions/marionette/tests/run_tests.gd
```

**Pitfall — class cache must be refreshed before tests can resolve newly-added `class_name` globals.** When you add a new `class_name X` to any GDScript file under `gdscript/`, you must:

1. Deploy the file: `tools/build.sh marionette`
2. Re-scan the project from the editor *once*: `godot --headless --path game --editor --quit`
3. *Then* run the tests.

Without step 2, the tests fail with `Parse Error: Identifier "X" not declared in the current scope` even though the file is on disk and the script source is syntactically correct. The cache lives in `game/.godot/global_script_class_cache.cfg`; the editor scan rebuilds it.

This bit me on the very first P2.1–P2.5 run. If a future test suddenly fails to resolve a class that you can grep for, the fix is almost always step 2.

After every iteration that *only* edits existing files (no new `class_name`), step 2 is unnecessary — `tools/build.sh marionette` then re-run the script suffices.

The pure-GDScript build is a flat rsync of `extensions/marionette/gdscript/` → `game/addons/marionette/`. Tests at `extensions/marionette/tests/` are *not* deployed (they're invoked by absolute path), so editing tests doesn't need a deploy.
