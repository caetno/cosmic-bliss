---
name: Godot 4.6 static var lazy-init in @tool scripts
description: Eager `static var x = build()` initializers can run before class_name dependencies resolve under @tool reload — use lazy `_ensure_x()` instead
type: reference
originSessionId: 8768f07d-d49b-448e-ae9c-61f4e9166246
---
In Godot 4.6 GDScript, eagerly-initialized class-level static vars whose initializers reference other `class_name`-declared classes (or their enums/static methods) can fire **before those classes are fully resolved** under `@tool` hot-reload. The initializer silently produces a default value (e.g. empty array) and never re-runs, leaving the class permanently broken in the editor — even though tests pass because `runtime` script load order is different.

Symptom seen: `MarionettePermutationMatcher._candidates` was eagerly built from `SignedAxis.Axis.*` enum members. In tests the array had 24 entries; in the editor `@tool` gizmo it was `[]`, and every `find_match()` returned `score = -INF` because the for-loop never executed.

**Fix pattern**: lazy initialization on first access.

```gdscript
static var _candidates: Array = []

static func _ensure_candidates() -> Array:
    if _candidates.is_empty():
        _candidates = _build_candidates()
    return _candidates

static func find_match(...) -> ...:
    for triple in _ensure_candidates():
        ...
```

Apply preemptively whenever a static var initializer touches another class_name'd class — especially enums, static methods on `RefCounted` helpers, or any class loaded via the global script class registry. Don't wait for the symptom.
