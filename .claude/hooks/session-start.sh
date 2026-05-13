#!/usr/bin/env bash
# SessionStart hook: detect which extension this terminal "belongs to" by cwd,
# then surface inbox messages, sibling commits, and new cross-cutting update
# docs since this extension's last commit. Output goes to stdout and is
# injected into the model's context.
#
# Detection:
#   - If cwd is inside extensions/<name>/, the session is the <name> supervisor.
#   - Otherwise, treat it as top-level Claude (repo janitor) and skip per-ext
#     fanout, but still print pending update docs and any non-empty inboxes.

set -uo pipefail

# Capture invoking cwd BEFORE switching to repo root.
CWD="${PWD}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT" || exit 0

EXTENSIONS=(tentacletech marionette tenticles body_field)
EXT=""
for e in "${EXTENSIONS[@]}"; do
    case "$CWD" in
        */extensions/"$e"|*/extensions/"$e"/*) EXT="$e"; break ;;
    esac
done

# --- Helper: trim leading/trailing blank lines, print only if non-empty ---
print_section() {
    local title="$1"; shift
    local body="$*"
    body="$(printf '%s' "$body" | sed -e '/./,$!d' | sed -e :a -e '/^\s*$/{$d;N;ba' -e '}')"
    if [ -n "$body" ]; then
        printf '## %s\n%s\n\n' "$title" "$body"
    fi
}

# --- Inbox: print non-empty inboxes ---
inbox_dump() {
    local ext="$1"
    local f=".claude/inbox/${ext}.md"
    [ -f "$f" ] || return 0
    # strip the HTML comment header; print only real entries
    local content
    content="$(sed -n '/^-->/,$p' "$f" | tail -n +2)"
    content="$(printf '%s' "$content" | sed -e :a -e '/^\s*$/{$d;N;ba' -e '}')"
    if [ -n "$content" ]; then
        printf '### inbox/%s.md\n%s\n\n' "$ext" "$content"
    fi
}

# --- Recent update docs (last 14 days) ---
recent_update_docs() {
    find docs -maxdepth 1 -name 'Cosmic_Bliss_Update_*.md' -mtime -14 2>/dev/null \
        | sort -r | head -10
}

# --- Recent sibling commits (last 14 days, touching sibling extension paths) ---
sibling_commits() {
    local self="$1"
    local sibling
    for sibling in "${EXTENSIONS[@]}"; do
        [ "$sibling" = "$self" ] && continue
        local out
        out="$(git log --since='14 days ago' --oneline -- "extensions/${sibling}/" 2>/dev/null | head -5)"
        if [ -n "$out" ]; then
            printf '### %s\n%s\n\n' "$sibling" "$out"
        fi
    done
}

# ============================================================
echo "# SessionStart briefing"
echo

if [ -n "$EXT" ]; then
    echo "**Supervisor scope:** \`extensions/${EXT}/\`"
    echo
    echo "Reminder: edits stay inside your extension. Cross-extension reads via \`${EXT}-explorer\` -> sibling \`<ext>-explorer\`. Cross-extension writes via \`docs/Cosmic_Bliss_Update_*.md\`. Use \`/handoff <ext> <msg>\` for nudges; \`/inbox\` to read+clear your own."
    echo

    own_inbox="$(inbox_dump "$EXT")"
    if [ -n "$own_inbox" ]; then
        printf '## Your inbox\n%s\n' "$own_inbox"
    fi

    siblings="$(sibling_commits "$EXT")"
    print_section "Sibling activity (last 14d)" "$siblings"

    updates="$(recent_update_docs)"
    print_section "Recent update docs (last 14d)" "$updates"
else
    echo "**Scope:** repo root (top-level Claude / janitor)."
    echo
    echo "Reminder: extension-internal work belongs in the per-extension supervisor session, not here. This session is for tools/, docs/architecture/, build, version bumps, monorepo refactors."
    echo
    # surface any non-empty inboxes so the user notices stale handoffs
    any=""
    for e in "${EXTENSIONS[@]}"; do
        d="$(inbox_dump "$e")"
        [ -n "$d" ] && any="${any}${d}"
    done
    print_section "Pending inboxes across extensions" "$any"

    updates="$(recent_update_docs)"
    print_section "Recent update docs (last 14d)" "$updates"
fi
