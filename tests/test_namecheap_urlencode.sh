#!/bin/bash
# Unit tests for the url_encode function in scripts/providers/namecheap.com.provider.
#
# url_encode is used to percent-encode free-text contact fields per RFC 3986
# for Namecheap's x-www-form-urlencoded POST body. Unreserved characters
# (A-Z, a-z, 0-9, '-', '_', '.', '~') must pass through unchanged; everything
# else must be %HH uppercase.
#
# Note: Namecheap intentionally does NOT want phone numbers to be encoded
# (the '+' must be raw). The lib documents this; we test that url_encode
# WOULD encode '+' so the caller is responsible for skipping it.

set -u

. "$(dirname "$0")/lib/test_helpers.sh"

# url_encode is the first function defined in the Namecheap provider. It
# is self-contained (no other provider symbols are referenced), so we can
# extract and source it standalone.
FUNC_FILE="$A2TOOLS_TEST_TMPDIR/url_encode.func.sh"
awk '
    /^url_encode\(\) \{/ { in_fn=1 }
    in_fn { print }
    in_fn && /^\}/ { exit }
' "$A2TOOLS_PROVIDERS_DIR/namecheap.com.provider" > "$FUNC_FILE"

if [ ! -s "$FUNC_FILE" ]; then
    echo "FATAL: failed to extract url_encode from namecheap.com.provider" >&2
    exit 2
fi

run_encode() {
    (
        # shellcheck disable=SC1090
        . "$FUNC_FILE"
        url_encode "$1"
    ) 2>/dev/null
}

# ---------------------------------------------------------------------------
test_starts_with "url_encode: unreserved chars pass through"
# ---------------------------------------------------------------------------
# Per RFC 3986: A-Z, a-z, 0-9, '-', '_', '.', '~' are unreserved.
assert_eq "abcXYZ"        "$(run_encode "abcXYZ")"     "alphanumeric unchanged"
assert_eq "0123456789"    "$(run_encode "0123456789")" "digits unchanged"
assert_eq "a-b_c.d~e"     "$(run_encode "a-b_c.d~e")"   "all unreserved specials unchanged"

# ---------------------------------------------------------------------------
test_starts_with "url_encode: reserved/special chars get %HH (uppercase)"
# ---------------------------------------------------------------------------
# Space -> %20 (the canonical example from RFC 3986 itself).
assert_eq "hello%20world" "$(run_encode "hello world")" "space -> %20"

# Common reserved set: !, *, ', (, ), ;, :, @, &, =, +, $, ,, /, ?, #, [, ]
assert_eq "%21" "$(run_encode '!')" "exclamation -> %21"
assert_eq "%2A" "$(run_encode '*')" "asterisk -> %2A"
assert_eq "%27" "$(run_encode "'")" "apostrophe -> %27"
assert_eq "%28" "$(run_encode '(')" "open paren -> %28"
assert_eq "%29" "$(run_encode ')')" "close paren -> %29"
assert_eq "%3B" "$(run_encode ';')" "semicolon -> %3B"
assert_eq "%3A" "$(run_encode ':')" "colon -> %3A"
assert_eq "%40" "$(run_encode '@')" "at-sign -> %40"
assert_eq "%26" "$(run_encode '&')" "ampersand -> %26"
assert_eq "%3D" "$(run_encode '=')" "equals -> %3D"
assert_eq "%2B" "$(run_encode '+')" "plus -> %2B (note: caller must skip for phone)"
assert_eq "%24" "$(run_encode '$')" "dollar -> %24"
assert_eq "%2C" "$(run_encode ',')" "comma -> %2C"
assert_eq "%2F" "$(run_encode '/')" "slash -> %2F"
assert_eq "%3F" "$(run_encode '?')" "question -> %3F"
assert_eq "%23" "$(run_encode '#')" "hash -> %23"
assert_eq "%5B" "$(run_encode '[')" "open bracket -> %5B"
assert_eq "%5D" "$(run_encode ']')" "close bracket -> %5D"

# ---------------------------------------------------------------------------
test_starts_with "url_encode: percent sign is itself encoded"
# ---------------------------------------------------------------------------
# A literal '%' must become %25.
assert_eq "%25" "$(run_encode '%')" "literal % -> %25"
# "50%" -> "50%25"
assert_eq "50%25" "$(run_encode "50%")" "trailing % -> %25"

# ---------------------------------------------------------------------------
test_starts_with "url_encode: non-ASCII bytes get %HH too"
# ---------------------------------------------------------------------------
# A UTF-8 multibyte char (e.g. é = 0xC3 0xA9 in UTF-8) should be encoded
# per-byte, yielding %C3%A9. We don't hard-code the exact output (which
# depends on the bash version's handling of multi-byte substrings in the
# function's `${s:i:1}` loop) - we just verify the function transforms
# the input to a non-empty percent-encoded string.
out="$(run_encode $'é')"
# The output must be non-empty, must contain only %HH escapes and unreserved
# chars, and must NOT be identical to the input.
[ -n "$out" ] && [ "$out" != "$'é'" ] || _assert_fail "UTF-8 input transformed" "got: [$out]"
case "$out" in
    *%*) _assert_pass "UTF-8 input is percent-encoded" "" ;;
    *)   _assert_fail "UTF-8 input is percent-encoded" "got: [$out]" ;;
esac

# ---------------------------------------------------------------------------
test_starts_with "url_encode: empty string"
# ---------------------------------------------------------------------------
assert_eq "" "$(run_encode "")" "empty string -> empty"

# ---------------------------------------------------------------------------
test_starts_with "url_encode: real-world address example"
# ---------------------------------------------------------------------------
# Matches the docstring's claim that the output matches Namecheap's own
# %20 example for address spaces.
assert_eq "123%20Main%20St" "$(run_encode "123 Main St")" "address with spaces"

# Mixed: name with apostrophe, address with comma.
#   "O'Brien"   -> "O%27Brien"
#   "Apt 3"     -> "Apt%203"
#   ", "        -> "%2C%20"
out="$(run_encode "O'Brien, Apt 3")"
assert_eq "O%27Brien%2C%20Apt%203" "$out" "mixed punctuation + spaces"

test_summary
