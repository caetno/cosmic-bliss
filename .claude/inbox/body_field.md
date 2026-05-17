<!--
Inbox for the BodyField supervisor.

Append-only during a session. Cleared by `/inbox` after read.
Each entry: `### YYYY-MM-DD HH:MM <from-extension>` then a short body.

Use for nudges and FYIs that don't warrant an update doc.
For design-level changes to BodyField's public surface, ask the
caller to drop a `docs/Cosmic_Bliss_Update_*.md` instead.
-->

### 2026-05-17 11:58 marionette

§17.5 framing nit: the brief reads "render-mesh additive-offset path
already exists for §15 jiggle" — that's not accurate. Today's §15 uses
Blender-painted skin weights on PhysicalBone3D `JiggleBone`s → standard
LBS in the skin shader. The per-vertex shader path your contract assumes
(`vertex_offset[i] += baked_weights[i] * (particle_world_pos − particle_rest_pos)`,
with sparse CUSTOM-channel weights + RGBA32F particle data texture) is
described at `Marionette_plan.md §17` lines 1497–1502 and is **new
infrastructure Marionette's S2 builds** — it does not exist today.

Phrase future briefs as "is the path Marionette §17.5-S2 builds" rather
than "already exists" so the path's status stays clear in the doc trail.

Marionette §17.5-S1 (discovery + virtual particle + SPD, no render
integration yet) starts today on the Marionette side; doc apply-pass
to §15 lands in the same slice.
