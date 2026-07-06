#!/bin/bash
# Unit tests for fqdncredmgr.sh's mask_username helper.
#
# mask_username is the function that renders stored usernames in
# `fqdncredmgr list` output with the middle characters replaced by '*',
# so that the raw username never appears in a `ps` capture or a log line.
# It also handles email-style usernames specially, masking the domain part
# of the email differently from the local part.
#
# mask_username is a pure function (no library dependencies), so we
# extract just that function definition and source it in isolation. No
# fqdncredmgr state is touched.

set -u

. "$(dirname "$0")/lib/test_helpers.sh"

# Extract just the mask_username function from fqdncredmgr.sh. The
# function is pure (no sub-shells, no globals, no other a2tools symbols),
# so extracting it in isolation is safe.
FUNC_FILE="$A2TOOLS_TEST_TMPDIR/mask_username.func.sh"
awk '
    /^mask_username\(\) \{/ { in_fn=1 }
    in_fn { print }
    in_fn && /^\}/ { exit }
' "$A2TOOLS_SCRIPTS_DIR/fqdncredmgr.sh" > "$FUNC_FILE"

# Sanity: the extract should not be empty.
if [ ! -s "$FUNC_FILE" ]; then
    echo "FATAL: failed to extract mask_username from fqdncredmgr.sh" >&2
    exit 2
fi

run_mask() {
    (
        # shellcheck disable=SC1090
        . "$FUNC_FILE"
        mask_username "$1"
    ) 2>/dev/null
}

# ---------------------------------------------------------------------------
test_starts_with "mask_username: short non-email usernames"
# ---------------------------------------------------------------------------
# 1 char: fully masked
assert_eq "*"  "$(run_mask a)"        "1-char username -> single *"
# 2 chars: fully masked
assert_eq "**" "$(run_mask ab)"       "2-char username -> two *"
# 3 chars: a** (first kept, last kept)
assert_eq "a*c" "$(run_mask abc)"     "3-char username -> first + * + last"

# ---------------------------------------------------------------------------
test_starts_with "mask_username: longer non-email usernames"
# ---------------------------------------------------------------------------
assert_eq "a****d" "$(run_mask abcde)"  "5-char -> a + 3* + d"
assert_eq "a*********k" "$(run_mask abcdefghijk)" "11-char -> a + 9* + k"

# ---------------------------------------------------------------------------
test_starts_with "mask_username: email-style usernames (local part)"
# ---------------------------------------------------------------------------
# Local part 'alice' is 5 chars -> a***e.
# Domain label 'example' is 7 chars -> e****** (first + 6*).
# TLD '.com' preserved.
assert_eq "a***e@e******.com" "$(run_mask alice@example.com)" "alice@example.com"

# Short local part
assert_eq "**@e******.com" "$(run_mask ab@example.com)" "ab@example.com - 2-char local masked fully"

# Short domain label
# A 2-char domain label is fully masked (the lib's branch is
# `if [ "$dl_len" -le 2 ]`), not "first char + *".
assert_eq "a***e@**.com" "$(run_mask alice@ex.com)" "ex.com - 2-char domain label masked fully"

# ---------------------------------------------------------------------------
test_starts_with "mask_username: multi-label TLDs preserved"
# ---------------------------------------------------------------------------
# .co.uk -> extension becomes ".co.uk".
assert_eq "a***e@e******.co.uk" "$(run_mask alice@example.co.uk)" \
    "multi-label TLD (.co.uk) preserved"

# ---------------------------------------------------------------------------
test_starts_with "mask_username: username that is just an @-symbol"
# ---------------------------------------------------------------------------
# Edge: local part empty after split - masked_part prints ''* 0 *''. The
# function is robust enough that this returns "@" with masking. Document
# the actual behavior here so any future change is intentional.
out="$(run_mask "@example.com")"
# Whatever it produces, it must NOT contain the raw 'example' substring
# (the second character onward of the domain label).
case "$out" in
    *"example"*) _assert_fail "domain label must not leak unaltered" "got: $out" ;;
    *)           _assert_pass "domain label is masked" "" ;;
esac

# ---------------------------------------------------------------------------
test_starts_with "mask_username: @-less username with no dot"
# ---------------------------------------------------------------------------
out="$(run_mask alice)"
# alice -> a***e
assert_eq "a***e" "$out" "plain alice -> a***e"

test_summary
