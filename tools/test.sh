#!/usr/bin/env bash
# Test runner per extension. Encapsulates the per-ext pipeline so sub-Claudes
# can invoke a single allowlisted command instead of inline shell pipelines.
#
# Usage:
#   ./tools/test.sh <ext>            # run all tests for extension
#   ./tools/test.sh <ext> <pattern>  # TT only: run tests matching pattern
#
# Exit code: 0 if all tests pass, 1 otherwise.
#
# Why this exists: each extension has different invocation requirements
# (vulkan vs headless, single runner vs per-file, etc.). Inline bash
# pipelines trip Claude Code's static-analysis guards; one script per
# extension consolidates the complexity behind a stable allowlist entry.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GAME_DIR="${REPO_ROOT}/game"

EXT="${1:-}"
PATTERN="${2:-}"

if [[ -z "${EXT}" ]]; then
    echo "usage: $0 <ext> [pattern]" >&2
    echo "  ext: body_field | marionette | tentacletech | tenticles" >&2
    exit 2
fi

run_body_field() {
    # Needs --rendering-driver vulkan; create_local_rendering_device returns null in headless.
    # NOTE: first run after adding a new .glsl file needs `godot --path "$GAME_DIR" --editor --quit` first
    # to trigger import. This script does NOT do that automatically (it'd cost ~5s on every run); if you
    # see RID errors after adding a shader, run the editor once.
    local script="${REPO_ROOT}/extensions/body_field/tests/run_tests.gd"
    if [[ ! -f "${script}" ]]; then
        echo "missing: ${script}" >&2
        return 1
    fi
    timeout 60 godot --path "${GAME_DIR}" --rendering-driver vulkan --quit-after 10 --script "${script}" 2>&1 | tail -40
    return ${PIPESTATUS[0]}
}

run_marionette() {
    local script="${REPO_ROOT}/extensions/marionette/tests/run_tests.gd"
    if [[ ! -f "${script}" ]]; then
        echo "missing: ${script}" >&2
        return 1
    fi
    timeout 120 godot --path "${GAME_DIR}" --headless --quit-after 30 --script "${script}" 2>&1 | tail -40
    return ${PIPESTATUS[0]}
}

run_tentacletech() {
    # Per-test-file layout. Iterate, aggregate, print summary.
    local test_dir="${GAME_DIR}/tests/tentacletech"
    local glob="${PATTERN:-test_*.gd}"
    local total_pass=0
    local total_fail=0
    local failed_tests=()
    local logdir
    logdir="$(mktemp -d)"

    shopt -s nullglob
    local tests=("${test_dir}"/${glob})
    shopt -u nullglob

    if [[ ${#tests[@]} -eq 0 ]]; then
        echo "no tests matched: ${test_dir}/${glob}" >&2
        return 1
    fi

    echo "TT: ${#tests[@]} test files"
    for t in "${tests[@]}"; do
        local name
        name="$(basename "${t}" .gd)"
        local log="${logdir}/${name}.log"
        timeout 60 godot --path "${GAME_DIR}" --headless --script "res://tests/tentacletech/${name}.gd" >"${log}" 2>&1
        local rc=$?
        # Extract "N/N passed" or "N passed, N failed" from the log.
        local summary
        summary="$(grep -oE '[0-9]+/[0-9]+ passed|[0-9]+ passed, [0-9]+ failed' "${log}" | head -1 || true)"
        local pass
        pass="$(echo "${summary}" | grep -oE '^[0-9]+' || echo 0)"
        if [[ ${rc} -ne 0 ]]; then
            failed_tests+=("${name} (rc=${rc})")
            total_fail=$((total_fail + 1))
        else
            total_pass=$((total_pass + pass))
        fi
    done

    echo "---"
    echo "TT total passing: ${total_pass}"
    if [[ ${#failed_tests[@]} -gt 0 ]]; then
        echo "FAILED (${#failed_tests[@]}):"
        for f in "${failed_tests[@]}"; do echo "  ${f}"; done
        echo "logs: ${logdir}"
        return 1
    fi
    rm -rf "${logdir}"
    return 0
}

run_tenticles() {
    local test_dir="${REPO_ROOT}/extensions/tenticles/tests"
    if [[ ! -d "${test_dir}" ]] || [[ -z "$(ls -A "${test_dir}" 2>/dev/null)" ]]; then
        echo "tenticles: no tests yet (skipping)"
        return 0
    fi
    echo "tenticles: test runner not implemented yet" >&2
    return 1
}

case "${EXT}" in
    body_field)    run_body_field ;;
    marionette)    run_marionette ;;
    tentacletech)  run_tentacletech ;;
    tenticles)     run_tenticles ;;
    *)
        echo "unknown ext: ${EXT}" >&2
        echo "valid: body_field | marionette | tentacletech | tenticles" >&2
        exit 2
        ;;
esac
