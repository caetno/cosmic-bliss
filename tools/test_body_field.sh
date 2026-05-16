#!/usr/bin/env bash
# Run the body_field test harness with the three invocation gotchas
# pre-baked: --rendering-driver vulkan (compute shaders), working dir
# under the godot project (so res:// resolves), and --editor --quit on
# --refresh to rebuild the class cache after a new class_name lands.
#
# Usage:
#   ./tools/test_body_field.sh             # run tests
#   ./tools/test_body_field.sh --refresh   # refresh class cache, then run
#
# Override the godot binary with GODOT_BIN env var.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GAME_DIR="${REPO_ROOT}/game"
TEST_SCRIPT="${REPO_ROOT}/extensions/body_field/tests/run_tests.gd"
GODOT_BIN="${GODOT_BIN:-godot}"

if [[ ! -f "${TEST_SCRIPT}" ]]; then
    echo "test_body_field.sh: ${TEST_SCRIPT} not found" >&2
    exit 1
fi

if ! command -v "${GODOT_BIN}" >/dev/null 2>&1; then
    echo "test_body_field.sh: godot binary not found (GODOT_BIN=${GODOT_BIN})" >&2
    exit 1
fi

if [[ "${1:-}" == "--refresh" ]]; then
    echo ">> refreshing class cache (--editor --quit)"
    "${GODOT_BIN}" --headless --editor --quit --path "${GAME_DIR}" >/dev/null 2>&1 || true
fi

echo ">> running body_field tests"
exec "${GODOT_BIN}" \
    --headless \
    --rendering-driver vulkan \
    --quit-after 10 \
    --path "${GAME_DIR}" \
    --script "${TEST_SCRIPT}"
