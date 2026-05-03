# PBD / XPBD research

Background reading for the Phase 4.5 placeholder (XPBD compliance, contact
warm-starting, friction budgets) flagged in
`../Cosmic_Bliss_Update_2026-05-03_phase4_wedge_robustness.md`. Source
material is pulled here so we have local, greppable copies that survive
upstream link rot.

## Layout

```
docs/pbd_research/
├── README.md
├── scraper.py        # polite recursive HTML→Markdown scraper
├── manifest.json     # auto: tracks fetched URLs + sha1 + paths
└── scraped/          # output, mirrors site URL structure
    └── <host>/<path>/<page>.md
```

## Usage

```bash
# First target — Obi convergence page, no recursion:
python3 scraper.py https://obi.virtualmethodstudio.com/manual/6.1/convergence.html --no-follow

# Crawl the full Obi 6.1 manual (caps at 50 pages by default):
python3 scraper.py https://obi.virtualmethodstudio.com/manual/6.1/ \
    --allow-prefix https://obi.virtualmethodstudio.com/manual/6.1/ \
    --depth 3 --max-pages 80 --delay 1.0

# Re-fetch a single page:
python3 scraper.py <url> --no-follow --force
```

Re-runs are incremental: anything in `manifest.json` is skipped unless
`--force` is set. The output `.md` includes a comment header with the
source URL and fetch timestamp. Output goes under `scraped/<host>/<path>.md`,
mirroring the URL structure so `git diff` after a re-run cleanly shows
upstream content changes.

## Etiquette

- 1-second default delay between fetches.
- Honest User-Agent string (identifies as a personal research scraper).
- Default 50-page cap so a typo on `--allow-prefix` doesn't accidentally
  walk a whole site.
- Always check `robots.txt` and the site's terms before crawling at scale.
  Obi's manual is small and hosted on a personal-studio domain — keep
  crawls polite.

## What's worth reading first

**Start with `findings_obi_synthesis.md` in this folder** — that's the
distilled answer for what Obi's source teaches us about TentacleTech's
wedge-robustness work, with concrete revisions to the slice plan in
`../Cosmic_Bliss_Update_2026-05-03_phase4_wedge_robustness.md`.

The Obi 7.x asset source dropped under `Obi/` (full Unity asset). Most
algorithmic value lives in `Obi/Resources/Compute/`:

- **`ContactHandling.cginc`** — per-contact lambda accumulators. The
  reference implementation for multi-contact-correct friction.
- **`ColliderCollisionConstraints.compute`** — Project/Apply pattern,
  one thread per contact. Reference for slice 4M.
- **`DistanceConstraints.compute`** — canonical XPBD form, ~70 lines.
  Reference for slice 4M-XPBD.
- **`AtomicDeltas.cginc`** — Jacobi accumulator + SOR apply pattern.
  Adapted to single-thread C++ for our solver.
- **`Solver.compute`** — predict, sleep threshold, velocity update.
  Reference for slice 4P.
- **`Integration.cginc`** — predict/differentiate cycle. 36 lines.
- **`SolverParameters.cginc`** — knobs Obi exposes. Inventory for what
  we might want to copy.
- **`PinholeConstraints.compute`** — orifice abstraction for Phase 5.
  XPBD pin-on-collider with `mix`-along-edge, motor force, artificial
  friction, range clamping, multi-edge cursor advancement. Re-read
  when Phase 5 opens — see synthesis doc § "Addendum 2026-05-03 (part 2)".
- **`ChainConstraints.compute`** — direct (non-iterative) tridiagonal
  solver for chains. Phase 9 polish candidate for free-air segments;
  doesn't help wedged chains. ~160 lines.
- **`TetherConstraints.compute`** — one-sided XPBD distance (only
  resists overstretch). Pattern useful for slack-permitted attachments.

The C# Burst backend at `Obi/Scripts/Common/Backends/Burst/` mirrors
the compute kernels in C# Unity Mathematics — easier to read than HLSL
if the GPU layer is unfamiliar.

**Skip:** the PDFs (user-facing setup tutorials), the CHANGELOGs (bug
fix logs, no algorithmic discussion), the `Editor/` directory
(inspectors), the `Samples/` directories (Unity scenes).

The crawled HTML pages under `scraped/obi.virtualmethodstudio.com/` are
useful as commentary explaining the *intent* behind the source-level
patterns. The convergence page in particular gives the official Obi
answer for "iterations vs. substeps" tradeoff.

Add any other papers / blog posts under `scraped/external/<source>/` by
hand if they're not crawlable.
