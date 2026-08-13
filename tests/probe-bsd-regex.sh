#!/usr/bin/env bash
# Regex-dialect probe (#684) — what does THIS host's grep/sed actually do?
#
# #679 swept GNU-only regex out of the shell scanners because BSD grep/sed (the
# macOS default) read `\s`/`\w`/BRE `\|` as LITERALS: the pattern stops matching,
# the scanner emits zero rows, and the scan still exits 0. macOS sees a clean
# report of nothing. `tests/lint-shell-portability.sh` bans those constructs
# statically.
#
# One construct was deliberately left OUT of that ban: `\b`. Modern BSD `grep -E`
# is widely believed to support it, and 38 sites depend on it — but the belief
# had never been checked on a BSD host, only asserted. #684 exists to settle it.
#
# This file is that check. It is a PROBE, not a lint: it makes no claim about
# what the tree should contain. It runs each construct the scanners rely on and
# reports what the host's own regex engines do with it, so `\b`'s disposition is
# decided by evidence from a macOS runner rather than by argument. The `.github/
# workflows/ci.yml` `bsd-probe` job is what puts a BSD userland under it; running
# it on Linux gives the GNU baseline to compare against.
#
# WHY A PROBE AND NOT A TEST. The portable answer differs BY PLATFORM, so there
# is no single expected output to assert:
#
#   - GNU accepts `\b` and REJECTS BSD's `[[:<:]]`/`[[:>:]]` outright
#     ("Invalid character class name", exit 2).
#   - BSD accepts `[[:<:]]`, and its `\b` support varies by dialect and vintage.
#
# So a naive "rewrite everything to one spelling" breaks the other platform.
# What IS assertable everywhere is the POSIX baseline (`[[:space:]]`,
# `[[:alnum:]_]`, `grep -w`, ERE alternation) — the constructs #679 migrated TO.
# Those are checked as hard REQUIREMENTS below and fail the script. The dialect
# questions are reported as INFO rows.
#
# FAIL-LOUD. A construct that is unsupported must be visibly reported as such,
# never rendered as an empty result — silence reading as success is the exact
# #679 failure mode. Every check prints an explicit SUPPORTED/UNSUPPORTED verdict,
# and an unmet REQUIREMENT exits non-zero with an actionable message.
#
# Pure bash + coreutils; no network, no python, no harness. Runs anywhere.

set -uo pipefail

FAILURES=0

# --- reporting ---------------------------------------------------------------

hdr() {
    printf '\n== %s ==\n' "$1"
}

# info <label> <verdict> [detail] — a dialect observation. Never fails the run;
# this is the data the probe exists to collect.
info() {
    printf '  [info] %-46s %s%s\n' "$1" "$2" "${3:+  ($3)}"
}

# require <label> <verdict> — a POSIX baseline that MUST hold on every platform.
require() {
    if [ "$2" = "SUPPORTED" ]; then
        printf '  [ ok ] %-46s %s\n' "$1" "$2"
    else
        printf '  [FAIL] %-46s %s\n' "$1" "$2"
        FAILURES=$((FAILURES + 1))
    fi
}

# --- probing primitives ------------------------------------------------------
#
# Each returns SUPPORTED / UNSUPPORTED / ERROR, distinguishing three outcomes
# that a bare exit status conflates:
#
#   SUPPORTED   — matched the positive input (the construct works)
#   UNSUPPORTED — ran cleanly but did NOT match (read as a literal — the silent
#                 #679 failure mode, and the one worth naming explicitly)
#   ERROR       — the tool REJECTED the pattern (exit >= 2), e.g. GNU on
#                 `[[:<:]]`. Loud rather than silent, but still a non-answer.

# probe_grep <verdict-var> <input> <pattern> [flags...]
#
# Pass NO flag argument for the BRE (plain grep) probes. An empty-string flag
# would be taken as a FILE operand, so grep would read the empty path instead of
# stdin and report ERROR on every BRE row — an artifact of the probe that reads
# exactly like a platform finding.
probe_grep() {
    local __out="$1" input="$2" pattern="$3"
    shift 3
    local rc
    printf '%s\n' "$input" | command grep ${1+"$@"} -- "$pattern" >/dev/null 2>&1
    rc=$?
    case $rc in
        0) printf -v "$__out" '%s' "SUPPORTED" ;;
        1) printf -v "$__out" '%s' "UNSUPPORTED" ;;
        *) printf -v "$__out" '%s' "ERROR" ;;
    esac
}

# probe_sed <verdict-var> <input> <expression> <expected>
# SUPPORTED only when the substitution actually changed the input to <expected>;
# a sed that reads the construct as a literal leaves the input untouched.
probe_sed() {
    local __out="$1" input="$2" expr="$3" expected="$4"
    local got rc
    got="$(printf '%s\n' "$input" | command sed -E "$expr" 2>/dev/null)"
    rc=$?
    if [ $rc -ne 0 ]; then
        printf -v "$__out" '%s' "ERROR"
    elif [ "$got" = "$expected" ]; then
        printf -v "$__out" '%s' "SUPPORTED"
    else
        printf -v "$__out" '%s' "UNSUPPORTED"
    fi
}

# --- host identification -----------------------------------------------------

hdr "Host"
printf '  uname:  %s\n' "$(command uname -a 2>/dev/null || echo unknown)"
# BSD grep/sed have no --version and exit non-zero on it; that IS the signal.
printf '  grep:   %s\n' "$(command grep --version 2>/dev/null | command head -1 ||
    echo 'no --version (BSD-style)')"
printf '  sed:    %s\n' "$(command sed --version 2>/dev/null | command head -1 ||
    echo 'no --version (BSD-style)')"

# --- REQUIREMENTS: the POSIX baseline #679 migrated TO ------------------------
#
# These must hold on every platform. If one fails, the #679 sweep itself is
# broken on this host and the scanners cannot be trusted here.

hdr "POSIX baseline (must hold everywhere)"

V=""
probe_grep V 'a b' '[[:space:]]' -E
require "[[:space:]] under grep -E" "$V"

probe_grep V 'a b' '[[:space:]]'
require "[[:space:]] under grep (BRE)" "$V"

probe_grep V 'foo_bar1' '^[[:alnum:]_]+$' -E
require "[[:alnum:]_] under grep -E" "$V"

probe_grep V 'needle' 'haystack|needle' -E
require "ERE alternation (a|b)" "$V"

# `grep -w` is the POSIX word-match flag — the portable fallback for the six
# BRE symbol probes if `\b` proves unsafe there. It is a FLAG, not a regex
# construct, so it sidesteps the dialect question entirely.
probe_grep V 'def my_func():' 'my_func' -w
require "grep -w matches a whole word" "$V"

probe_grep V 'def my_func_extra():' 'my_func' -w
if [ "$V" = "UNSUPPORTED" ]; then
    require "grep -w rejects a partial word" "SUPPORTED"
else
    require "grep -w rejects a partial word" "BROKEN (matched a substring)"
fi

probe_sed V 'a  b' 's/[[:space:]]+/_/' 'a_b'
require "[[:space:]] under sed -E" "$V"

# --- INFO: the dialect questions #684 exists to settle ------------------------

hdr "Word boundaries (the #684 question)"

# The 38 sites split by dialect: 32 use `grep -E`, 6 use plain `grep` (BRE).
# The BRE six are the higher risk — they are the shell-interpolated symbol
# probes, where a non-match reads as "no test exists" and produces a FALSE
# untested-public-api finding at HIGH.
probe_grep V 'def my_func():' '\bmy_func\b' -E
info "\\b under grep -E   (32 sites)" "$V"

probe_grep V 'def my_func():' '\bmy_func\b'
info "\\b under grep (BRE)  (6 sites)" "$V"

# The negative half: a boundary that WORKS must also still exclude a partial
# word. A `\b` read as a literal `b` fails to match here too, so this row alone
# cannot distinguish the two — read it together with the positive above.
probe_grep V 'def my_func_extra():' '\bmy_func\b' -E
info "\\b -E rejects partial word" "$V" "UNSUPPORTED here means correct"

probe_sed V 'my_func x' 's/\bmy_func\b/HIT/' 'HIT x'
info "\\b under sed -E" "$V"

# BSD's own boundary syntax. GNU REJECTS these outright (exit 2 -> ERROR), which
# is precisely why neither spelling can be applied tree-wide unconditionally.
probe_grep V 'def my_func():' '[[:<:]]my_func[[:>:]]' -E
info "[[:<:]] / [[:>:]] under grep -E" "$V"

hdr "GNU-only constructs (#679 banned these; all should be UNSUPPORTED on BSD)"

# Reported for completeness: they confirm the probe can actually TELL the
# platforms apart. On GNU these read SUPPORTED, on BSD UNSUPPORTED — a run where
# every one of them says SUPPORTED is a GNU host, and its `\b` rows above say
# nothing about BSD.
#
# The `lint-allow-gnu-regex:` markers below are on the `info` LABEL lines, not
# the probes. lint-shell-portability.sh inspects any line naming grep/sed/awk,
# and these labels name `grep` in their display text — the banned construct here
# is the SUBJECT of a report string, never a pattern handed to a tool. The probe
# calls themselves need no marker: the gate reads a bare `probe_grep` as an
# ordinary function call, which is correct, since the dialect risk lives in the
# pattern and the whole point of this file is to measure it.
probe_grep V 'a b' '\s' -E
info "\\s under grep -E" "$V" # lint-allow-gnu-regex: report label, not a pattern

probe_grep V 'foo' '\w' -E
info "\\w under grep -E" "$V" # lint-allow-gnu-regex: report label, not a pattern

# Input is `ab`, so a match can ONLY come from `a\|b` being read as ALTERNATION
# (GNU). BSD reads `\|` as a literal pipe, which `ab` does not contain ->
# UNSUPPORTED. Probing with an input that literally contains `|` could not tell
# the two readings apart.
probe_grep V 'ab' 'a\|b'
info "BRE \\| alternation" "$V" "SUPPORTED on GNU = alternation"

probe_grep V 'foo' 'f.o' -P
info "grep -P (PCRE)" "$V" # lint-allow-gnu-regex: report label, not a pattern

# --- verdict -----------------------------------------------------------------

hdr "Verdict"
if [ "$FAILURES" -ne 0 ]; then
    printf '  %d POSIX baseline requirement(s) FAILED on this host.\n' "$FAILURES"
    printf '  The #679 portable spellings do not hold here — the scanners\n'
    printf '  cannot be trusted on this platform until that is resolved.\n'
    exit 1
fi

printf '  POSIX baseline holds on this host.\n'
printf '  Word-boundary rows above are INFORMATIONAL — read them from the\n'
printf '  macos-latest run to decide the disposition of the 38 `\\b` sites\n'
printf '  (documented exemption vs. port to `grep -w`). See issue #684.\n'
exit 0
