#!/usr/bin/env python3
"""Polite recursive scraper for technical documentation sites.

Fetches a starting URL, converts the main content to Markdown, follows
in-prefix links, repeats. Re-runs are incremental — already-fetched URLs
are skipped via a manifest.json next to this script.

Deps: requests + beautifulsoup4 (already on system; markdownify not used —
we roll our own bs4-based converter so code blocks and headings come through
clean and we control which page chrome gets stripped).

Usage:
    python3 scraper.py <start-url> [options]

Examples:
    python3 scraper.py https://obi.virtualmethodstudio.com/manual/6.1/convergence.html
    python3 scraper.py https://obi.virtualmethodstudio.com/manual/6.1/ \\
        --allow-prefix https://obi.virtualmethodstudio.com/manual/6.1/ \\
        --depth 4 --delay 1.5
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import time
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urldefrag, urljoin, urlparse

import requests
from bs4 import BeautifulSoup, NavigableString, Tag

SCRIPT_DIR = Path(__file__).resolve().parent
SCRAPE_DIR = SCRIPT_DIR / "scraped"
MANIFEST_PATH = SCRIPT_DIR / "manifest.json"

USER_AGENT = (
    "cosmic-bliss-research-scraper/1.0 "
    "(personal research; +https://github.com/anthropics/claude-code)"
)

# Skip these file extensions when discovering links — not text content.
BINARY_EXTS = {
    ".pdf", ".zip", ".tar", ".gz", ".png", ".jpg", ".jpeg", ".gif",
    ".svg", ".webp", ".mp4", ".webm", ".mp3", ".wav", ".ogg", ".woff",
    ".woff2", ".ttf", ".eot", ".ico",
}

# Tags whose text we drop entirely from the markdown output.
STRIP_TAGS = {"script", "style", "noscript", "template", "iframe", "svg"}

# Candidate selectors for "main content" — first match wins. Falls back to
# <body> if none hit. Add site-specific selectors at the top as new sites
# get scraped; the generic ones below catch most other docs.
MAIN_CONTENT_SELECTORS = [
    "div#tutorial-contents",  # Obi manual
    "main",
    "article",
    "div.content",
    "div#content",
    "div.main-content",
    "div#main-content",
    "div.markdown-body",  # GitHub-like
    "div.documentation",
]

# Parser preference order. lxml handles HTML5's "auto-close <p> on nested
# <p>" rule that html.parser misses (Obi pages have nested <p> which collapse
# the entire page into one paragraph under html.parser).
PARSERS = ["lxml", "html5lib", "html.parser"]


def _make_soup(html: str) -> BeautifulSoup:
    last_err = None
    for p in PARSERS:
        try:
            return BeautifulSoup(html, p)
        except Exception as e:
            last_err = e
    raise RuntimeError(f"no HTML parser available: {last_err}")


# -- HTML → Markdown --------------------------------------------------------


def _text_of(node) -> str:
    """Concatenated text content with whitespace collapsed."""
    if isinstance(node, NavigableString):
        return str(node)
    return "".join(_text_of(c) for c in node.children)


def _normalize_inline_ws(s: str) -> str:
    return re.sub(r"\s+", " ", s)


def render(node, base_url: str, list_depth: int = 0) -> str:
    """Convert a bs4 node into markdown. Block-level joining happens by callers
    inserting blank lines between block calls; inline functions return tight
    strings without trailing whitespace."""

    if isinstance(node, NavigableString):
        return _normalize_inline_ws(str(node))

    if not isinstance(node, Tag):
        return ""

    name = node.name.lower() if node.name else ""

    if name in STRIP_TAGS:
        return ""

    # Block elements -------------------------------------------------------
    if name in ("h1", "h2", "h3", "h4", "h5", "h6"):
        level = int(name[1])
        text = _normalize_inline_ws(_render_inline_children(node, base_url)).strip()
        return f"{'#' * level} {text}\n"

    if name == "p":
        text = _render_inline_children(node, base_url).strip()
        return text + "\n" if text else ""

    if name == "br":
        return "  \n"

    if name == "hr":
        return "---\n"

    if name == "blockquote":
        inner = _render_block_children(node, base_url, list_depth).strip()
        quoted = "\n".join("> " + line for line in inner.splitlines())
        return quoted + "\n"

    if name == "pre":
        # If pre>code, prefer the code child to preserve language hint.
        code = node.find("code")
        if code is not None:
            lang = ""
            for cls in code.get("class", []) or []:
                if cls.startswith("language-"):
                    lang = cls[len("language-"):]
                    break
            text = _text_of(code).rstrip("\n")
        else:
            text = _text_of(node).rstrip("\n")
            lang = ""
        return f"```{lang}\n{text}\n```\n"

    if name in ("ul", "ol"):
        return _render_list(node, base_url, list_depth, ordered=(name == "ol"))

    if name == "table":
        return _render_table(node, base_url)

    # Media / structural -----------------------------------------------
    if name == "img":
        alt = node.get("alt", "")
        src = urljoin(base_url, node.get("src", ""))
        return f"![{alt}]({src})"

    if name == "figure":
        return _render_block_children(node, base_url, list_depth).strip() + "\n"

    if name == "figcaption":
        text = _render_inline_children(node, base_url).strip()
        return f"_{text}_\n" if text else ""

    if name == "div" or name == "section" or name == "article" or name == "main":
        return _render_block_children(node, base_url, list_depth)

    # Inline elements --------------------------------------------------
    if name == "a":
        text = _render_inline_children(node, base_url).strip()
        href = node.get("href", "")
        if not text:
            return ""
        if not href:
            return text
        absurl, _ = urldefrag(urljoin(base_url, href))
        return f"[{text}]({absurl})"

    if name in ("strong", "b"):
        return f"**{_render_inline_children(node, base_url).strip()}**"

    if name in ("em", "i"):
        return f"*{_render_inline_children(node, base_url).strip()}*"

    if name == "code":
        # Inline code only — pre>code is handled above.
        return f"`{_text_of(node)}`"

    if name in ("kbd", "samp", "var"):
        return f"`{_text_of(node)}`"

    if name == "del" or name == "s":
        return f"~~{_render_inline_children(node, base_url).strip()}~~"

    if name == "sup":
        return f"^{_text_of(node)}^"

    if name == "sub":
        return f"~{_text_of(node)}~"

    # Spans, fonts, etc. — pass through children as inline.
    return _render_inline_children(node, base_url)


def _render_inline_children(node: Tag, base_url: str) -> str:
    parts = [render(c, base_url) for c in node.children]
    out = "".join(parts)
    return _normalize_inline_ws(out)


def _render_block_children(node: Tag, base_url: str, list_depth: int) -> str:
    """Render children, separating block-level outputs by blank lines."""
    out_parts: list[str] = []
    for c in node.children:
        if isinstance(c, NavigableString):
            text = str(c).strip()
            if text:
                out_parts.append(_normalize_inline_ws(text))
            continue
        if not isinstance(c, Tag):
            continue
        rendered = render(c, base_url, list_depth)
        if rendered.strip():
            out_parts.append(rendered.rstrip())
    # Block-level joins — separate with one blank line.
    return "\n\n".join(out_parts) + ("\n" if out_parts else "")


def _render_list(node: Tag, base_url: str, list_depth: int, ordered: bool) -> str:
    indent = "  " * list_depth
    lines: list[str] = []
    counter = 1
    for li in node.find_all("li", recursive=False):
        marker = f"{counter}." if ordered else "-"
        # Render inline-then-block: li may contain nested lists. Split.
        # We render the li as a block; inline content first, nested blocks indented.
        inline_parts = []
        block_parts = []
        for c in li.children:
            if isinstance(c, NavigableString):
                txt = _normalize_inline_ws(str(c))
                if txt.strip():
                    inline_parts.append(txt)
                continue
            if not isinstance(c, Tag):
                continue
            if c.name in ("ul", "ol", "pre", "blockquote", "table", "p", "div"):
                if c.name == "p":
                    inline_parts.append(_render_inline_children(c, base_url).strip())
                else:
                    block_parts.append(render(c, base_url, list_depth + 1).rstrip())
            else:
                inline_parts.append(render(c, base_url, list_depth))
        first = _normalize_inline_ws(" ".join(p for p in inline_parts if p)).strip()
        lines.append(f"{indent}{marker} {first}".rstrip())
        for blk in block_parts:
            for bl in blk.splitlines():
                lines.append(("  " + bl) if bl else "")
        counter += 1
    return "\n".join(lines) + "\n"


def _render_table(node: Tag, base_url: str) -> str:
    """Simple markdown table. Skips tables with merged cells (just dumps them
    as plaintext lines)."""
    rows: list[list[str]] = []
    for tr in node.find_all("tr"):
        cells = []
        for cell in tr.find_all(["th", "td"]):
            text = _normalize_inline_ws(_render_inline_children(cell, base_url)).strip()
            cells.append(text.replace("|", "\\|"))
        if cells:
            rows.append(cells)
    if not rows:
        return ""
    width = max(len(r) for r in rows)
    rows = [r + [""] * (width - len(r)) for r in rows]
    out = ["| " + " | ".join(rows[0]) + " |",
           "| " + " | ".join(["---"] * width) + " |"]
    for r in rows[1:]:
        out.append("| " + " | ".join(r) + " |")
    return "\n".join(out) + "\n"


def html_to_markdown(html: str, base_url: str) -> str:
    soup = _make_soup(html)

    # Drop chrome we never want.
    for tag in soup(STRIP_TAGS):
        tag.decompose()

    # Find the main content region.
    root = None
    for sel in MAIN_CONTENT_SELECTORS:
        match = soup.select_one(sel)
        if match is not None:
            root = match
            break
    if root is None:
        root = soup.body or soup

    md = _render_block_children(root, base_url, 0)
    # Collapse 3+ consecutive blank lines into 2.
    md = re.sub(r"\n{3,}", "\n\n", md)
    return md.strip() + "\n"


# -- Crawl ------------------------------------------------------------------


def derive_default_prefix(url: str) -> str:
    parsed = urlparse(url)
    path = parsed.path
    if "." in path.rsplit("/", 1)[-1]:
        # URL ends in a file (foo.html) — strip back to the parent dir.
        path = path.rsplit("/", 1)[0] + "/"
    elif not path.endswith("/"):
        path = path + "/"
    return f"{parsed.scheme}://{parsed.netloc}{path}"


def url_to_path(url: str) -> Path:
    """Map a URL to a relative on-disk path under SCRAPE_DIR."""
    parsed = urlparse(url)
    parts = [parsed.netloc] + [p for p in parsed.path.split("/") if p]
    if not parts or parts[-1] == "" or "." not in parts[-1]:
        # Directory-style URL — write index.md.
        parts.append("index.md")
    else:
        # Replace .html / .htm / etc. with .md.
        last = parts[-1]
        stem = re.sub(r"\.(html?|aspx?|php|jsp)$", "", last, flags=re.IGNORECASE)
        parts[-1] = stem + ".md"
    return Path(*parts)


def discover_links(soup: BeautifulSoup, base_url: str, allow_prefix: str) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    for a in soup.find_all("a", href=True):
        href = a["href"]
        absurl, _ = urldefrag(urljoin(base_url, href))
        if not absurl.startswith(allow_prefix):
            continue
        ext = Path(urlparse(absurl).path).suffix.lower()
        if ext in BINARY_EXTS:
            continue
        if absurl in seen:
            continue
        seen.add(absurl)
        out.append(absurl)
    return out


def load_manifest() -> dict:
    if MANIFEST_PATH.exists():
        return json.loads(MANIFEST_PATH.read_text())
    return {"fetched": {}, "version": 1}


def save_manifest(manifest: dict) -> None:
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2, sort_keys=True))


def fetch(url: str, session: requests.Session) -> tuple[str, str]:
    """Returns (html, content_type). Raises requests.HTTPError on bad status."""
    r = session.get(url, timeout=30)
    r.raise_for_status()
    return r.text, r.headers.get("Content-Type", "")


def write_page(url: str, markdown: str) -> Path:
    rel = url_to_path(url)
    out = SCRAPE_DIR / rel
    out.parent.mkdir(parents=True, exist_ok=True)
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    header = (
        f"<!--\n"
        f"source: {url}\n"
        f"fetched: {now}\n"
        f"-->\n\n"
    )
    out.write_text(header + markdown)
    return out


def crawl(
    start_url: str,
    allow_prefix: str,
    max_depth: int,
    delay: float,
    max_pages: int,
    force: bool,
    follow: bool,
) -> None:
    SCRAPE_DIR.mkdir(parents=True, exist_ok=True)
    manifest = load_manifest()
    fetched = manifest["fetched"]

    session = requests.Session()
    session.headers["User-Agent"] = USER_AGENT
    session.headers["Accept"] = "text/html,application/xhtml+xml"

    queue: deque[tuple[str, int]] = deque([(start_url, 0)])
    seen: set[str] = set([start_url])
    pages_done = 0

    print(f"[scraper] start={start_url}")
    print(f"[scraper] allow_prefix={allow_prefix}")
    print(f"[scraper] depth<={max_depth} max_pages={max_pages} delay={delay}s")

    while queue and pages_done < max_pages:
        url, depth = queue.popleft()
        if not force and url in fetched:
            print(f"[skip] cached: {url}")
            # Still discover links from cached file? Not needed — manifest
            # captured the link set last time. Skip outright.
            continue

        try:
            print(f"[fetch] depth={depth} {url}")
            html, ctype = fetch(url, session)
        except requests.RequestException as e:
            print(f"[error] {url}: {e}", file=sys.stderr)
            continue

        if "html" not in ctype.lower():
            print(f"[skip] non-html ({ctype}): {url}")
            continue

        markdown = html_to_markdown(html, url)
        out_path = write_page(url, markdown)
        digest = hashlib.sha1(html.encode("utf-8", errors="ignore")).hexdigest()
        fetched[url] = {
            "fetched": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "path": str(out_path.relative_to(SCRIPT_DIR)),
            "sha1": digest,
            "content_type": ctype,
            "depth": depth,
        }
        save_manifest(manifest)
        pages_done += 1
        print(f"  -> {out_path.relative_to(SCRIPT_DIR)} ({len(markdown)} bytes)")

        if follow and depth < max_depth:
            soup = _make_soup(html)
            for link in discover_links(soup, url, allow_prefix):
                if link in seen:
                    continue
                seen.add(link)
                queue.append((link, depth + 1))

        time.sleep(delay)

    print(f"[done] fetched={pages_done} queued_remaining={len(queue)}")


# -- CLI --------------------------------------------------------------------


def main() -> int:
    p = argparse.ArgumentParser(description="Polite recursive doc scraper.")
    p.add_argument("start_url", help="Starting URL.")
    p.add_argument("--allow-prefix",
                   help="Only follow links beginning with this prefix. "
                        "Default: derived from start URL (path minus filename).")
    p.add_argument("--depth", type=int, default=3,
                   help="Maximum link depth from start URL (default 3).")
    p.add_argument("--delay", type=float, default=1.0,
                   help="Seconds between fetches (default 1.0).")
    p.add_argument("--max-pages", type=int, default=50,
                   help="Hard cap on total pages fetched (default 50).")
    p.add_argument("--force", action="store_true",
                   help="Re-fetch even if URL is already in manifest.")
    p.add_argument("--no-follow", action="store_true",
                   help="Fetch only the start URL; ignore links.")
    args = p.parse_args()

    allow_prefix = args.allow_prefix or derive_default_prefix(args.start_url)
    crawl(
        start_url=args.start_url,
        allow_prefix=allow_prefix,
        max_depth=args.depth,
        delay=args.delay,
        max_pages=args.max_pages,
        force=args.force,
        follow=not args.no_follow,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
