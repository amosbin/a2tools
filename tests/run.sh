#!/bin/bash
# a2tools unit-test runner.
#
# Usage:
#   ./tests/run.sh                  # run every test_*.sh
#   ./tests/run.sh test_common_*    # run only the matching files
#
# Each test_*.sh is executed in its own subshell. A non-zero exit code
# (or unexpected output shape) is reported but does NOT abort the whole
# run - we want to see ALL the failures, not just the first.
#
# Output is TAP-like. A summary line at the end shows totals.

set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

# Quick sanity: the repo root must be the a2tools checkout.
if [ ! -f "$REPO_ROOT/scripts/lib/common.sh" ]; then
    echo "FATAL: $REPO_ROOT does not look like the a2tools checkout." >&2
    echo "       (missing scripts/lib/common.sh)" >&2
    exit 2
fi

# Discover test files. If args are given, run only those that match.
shopt -s nullglob
if [ $# -gt 0 ]; then
    files=()
    for pat in "$@"; do
        for f in "$TESTS_DIR"/$pat; do
            [ -f "$f" ] || continue
            files+=("$f")
        done
    done
else
    files=("$TESTS_DIR"/test_*.sh)
fi
shopt -u nullglob

if [ ${#files[@]} -eq 0 ]; then
    echo "No test files matched." >&2
    exit 2
fi

# Run each test in order. Capture exit code and output.
printf '1..%d\n' "${#files[@]}"

pass=0
fail=0
i=0
for f in "${files[@]}"; do
    i=$((i + 1))
    name="$(basename "$f" .sh)"

    # Skip non-executable / non-bash files defensively.
    if ! head -n1 "$f" | grep -q '#!.*bash'; then
        printf 'not ok %d - %s (not a bash script)\n' "$i" "$name"
        fail=$((fail + 1))
        continue
    fi

    # Run. Each test exits 0 on pass, 1 on fail.
    out="$(bash "$f" 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        printf 'ok %d - %s\n' "$i" "$name"
        pass=$((pass + 1))
    else
        printf 'not ok %d - %s (exit %d)\n' "$i" "$name" "$rc"
        fail=$((fail + 1))
        # Print the test's own output for debugging. Indent by 2 spaces
        # so it lines up under the "not ok" line.
        printf '%s\n' "$out" | sed 's/^/  /'
    fi
done

printf '\n# run: %d | pass: %d | fail: %d\n' "$i" "$pass" "$fail"

if [ "$fail" -ne 0 ]; then
    exit 1
fi
exit 0
