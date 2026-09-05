# shellcheck shell=bash
# Portability: no GNU-only regex/sed constructs (#679, #684)
#
# Area fragment of tests/validate-pre-review-gates.sh (#895). Sourced, not
# executed. Shared drivers live in tests/lib/pre-review-gates-sandbox.sh.

# --- Portability: no GNU-only regex/sed constructs (#679) --------------------
#
# `read_yaml_list` opened with a multi-command sed brace block (`{cmd;cmd;p}`),
# which BSD sed — the macOS default — rejects outright. Wrapped in `2>/dev/null`
# the error was invisible: every key parsed to EMPTY, the declared-convention
# path went inert, and the scan still exited 0. A project's .claude/pre-review.yml
# looked applied and was not.
#
# WHAT IS AND IS NOT TESTABLE HERE — read before adding a case.
#
# Two techniques that look like they would prove the fix DO NOT WORK, and each
# yields a test that passes with the broken code too:
#
#   1. `sed --posix` as a BSD stand-in. It reproduces BSD's `\s` and `\|`
#      semantics, but it still ACCEPTS the multi-command brace block. So it
#      cannot exercise the reported rejection at all.
#   2. Sabotaging `sed` on PATH to prove the parser is sed-free. The gate runs as
#      a CHILD PROCESS, and a child does not reliably inherit a modified PATH
#      (a shell startup file can rewrite it), so the sabotage silently never
#      reaches the code under test and the case passes vacuously.
#
# What IS testable on a GNU host is the OTHER half of the same defect, and it is
# the half that decides whether the config works: the trailing quote strip. The
# old expression was `s/["']\s*$//`, and `\s` is a GNU extension that BSD sed
# reads as a literal `s`. Given `- "scripts/smoke-*.py"   ` (trailing spaces,
# which YAML permits and an editor readily leaves behind), BSD produced
# `scripts/smoke-*.py"   ` — quote and spaces retained — so the glob matched
# nothing and the declared convention was silently inert. The pure-bash parser
# strips it correctly, and that difference is observable right here.
#
# The fixtures below therefore carry REAL trailing whitespace, and the parser is
# also unit-tested directly (test_read_yaml_list_*) so the strip is pinned at the
# function boundary rather than only through the scan.
#
# The brace-block rejection itself is covered by construction rather than by a
# case: `read_yaml_list` contains no `sed` call for a sed dialect to reject.
# `tests/lint-shell-portability.sh` is what keeps it that way.
#
# `write_bsd_sandbox` plants a source whose test the built-in heuristics cannot
# infer (scripts/smoke-*.py), so the ONLY thing that can suppress the finding is
# the declared config. If the config fails to parse, the row appears.

# write_bsd_sandbox <varname> — sandbox with a production source (app.py) and a
# test the built-ins cannot infer (scripts/smoke-app.py), declared via BOTH
# config keys. Sets BSD_LIST to the file list.
BSD_LIST=""
write_bsd_sandbox() {
    local __out="$1" __dir=""
    new_git_sandbox __dir || return 1
    command mkdir -p "$__dir/.claude" "$__dir/scripts"
    command printf '%s\n' "def app_public():" "    return 1" >"$__dir/app.py"
    command printf '%s\n' "import app" "app.app_public()" >"$__dir/scripts/smoke-app.py"
    # Trailing whitespace after the closing quote on one entry — the exact input
    # the old `s/["']\s*$//` was meant to handle and, on BSD, did not.
    {
        command printf '%s\n' "test_patterns:"
        command printf '%s\n' "  - 'scripts/smoke-*.py'   "
        command printf '%s\n' "test_discovery:"
        command printf '%s\n' "  - 'scripts/smoke-{name}.py'"
    } >"$__dir/.claude/pre-review.yml"
    BSD_LIST="$__dir/files.txt"
    command printf '%s\n' "$__dir/app.py" >"$BSD_LIST"
    printf -v "$__out" '%s' "$__dir"
}

# Control: with a working sed, the declared config suppresses the finding. This
# is the "config is applied" baseline the sabotage case is compared against —
# without it, a sabotage case that finds nothing could just mean the fixture was
# never able to fire.
test_declared_config_suppresses_baseline() {
    local sb rows
    write_bsd_sandbox sb || return 1
    run_gate_in "$sb" "$BSD_LIST"

    rows="$(category_rows "$GATE_OUT" "missing-test-file")"
    assert_not_contains "$rows" "app.py" \
        "baseline: the declared test_discovery template suppresses app.py (#679 control)"
}

# Unit-test the parser directly, at the function boundary. Sourcing the gate
# would run the whole scan, so the function is extracted and eval'd — the same
# text that ships, not a copy that could drift.
#
# `- "value"   ` with trailing spaces after the closing quote is the input the
# old `s/["']\s*$//` mishandled on BSD (quote and spaces retained). Each case
# below fails if the trailing strip regresses.
eval_read_yaml_list() {
    eval "$(command awk '/^read_yaml_list\(\) \{$/,/^\}$/' "$GATE")"
}

test_read_yaml_list_strips_trailing_whitespace() {
    local d out
    d="$(fresh_dir)"
    # printf '%b' so the escapes materialize — literal trailing spaces in this
    # source would be invisible here and stripped by any formatter, leaving a
    # fixture that cannot exercise the bug.
    command printf '%b' 'test_patterns:\n  - "scripts/smoke-*.py"   \n  - "b.py"\t\n' \
        >"$d/cfg.yml"

    out="$(
        eval_read_yaml_list
        read_yaml_list test_patterns "$d/cfg.yml"
    )"

    assert_equals "scripts/smoke-*.py
b.py" "$out" \
        "trailing whitespace after the closing quote is stripped (#679 AC#1/AC#2)"
}

test_read_yaml_list_handles_quotes_and_sections() {
    local d out
    d="$(fresh_dir)"
    command printf '%b' \
        'test_patterns:\n  - "a.py"\n  - '"'"'b.py'"'"'  \n  - c.py\ntest_discovery:\n  - "t/{name}.py"\n' \
        >"$d/cfg.yml"

    out="$(
        eval_read_yaml_list
        read_yaml_list test_patterns "$d/cfg.yml"
    )"
    assert_equals "a.py
b.py
c.py" "$out" \
        "double/single/unquoted entries parse, and the next top-level key ends the section (#679)"

    out="$(
        eval_read_yaml_list
        read_yaml_list test_discovery "$d/cfg.yml"
    )"
    assert_equals "t/{name}.py" "$out" \
        "a later key is reachable — the section walk is per-key, not first-only (#679)"
}

# --- #684: UNQUOTED trailing whitespace ---------------------------------------
#
# The old GNU expression was `["']\s*$` — the whitespace run only came off when a
# QUOTE sat in front of it, so an UNQUOTED `- a.py  ` kept its trailing spaces.
# #679 mirrored that byte-for-byte (its contract was identical GNU output);
# #684 fixes it, and these cases pin the new behaviour.
#
# The distinction matters for exactly one key, which is why the strip is worth
# changing rather than pinning. `test_patterns`/`test_skip_patterns`/
# `stdout_is_output` become gitignore patterns, and git strips trailing
# whitespace from those itself — the quirk is invisible there. But
# `test_discovery` templates are resolved by a literal `[ -f "$resolved" ]`,
# where a trailing space simply misses. See the e2e case further below.
test_read_yaml_list_strips_unquoted_trailing_whitespace() {
    local d out
    d="$(fresh_dir)"
    # printf '%b' so the escapes materialize — literal trailing spaces here would
    # be invisible in the source and stripped by any formatter, leaving a fixture
    # that cannot exercise the bug at all.
    command printf '%b' 'test_patterns:\n  - a.py   \n  - b.py\t\n  - c.py\n' \
        >"$d/cfg.yml"

    out="$(
        eval_read_yaml_list
        read_yaml_list test_patterns "$d/cfg.yml"
    )"

    assert_equals "a.py
b.py
c.py" "$out" \
        "UNQUOTED entries lose trailing whitespace too — no quote required (#684)"
}

# The escape hatch: whitespace INSIDE the quotes is meant, and survives. This is
# what keeps the fix from being a blunt trim — it mirrors the leading side, which
# likewise strips only up to the opening quote. Without this case, tightening the
# strip to also eat quoted whitespace would pass unnoticed.
test_read_yaml_list_preserves_quoted_inner_whitespace() {
    local d out
    d="$(fresh_dir)"
    command printf '%b' 'test_patterns:\n  - "a.py  "   \n' >"$d/cfg.yml"

    out="$(
        eval_read_yaml_list
        read_yaml_list test_patterns "$d/cfg.yml"
    )"

    assert_equals "a.py  " "$out" \
        "whitespace inside the quotes is deliberate and is preserved (#684)"
}

test_read_yaml_list_absent_key_is_empty() {
    local d out
    d="$(fresh_dir)"
    command printf '%b' 'test_patterns:\n  - "a.py"\n' >"$d/cfg.yml"

    out="$(
        eval_read_yaml_list
        read_yaml_list nosuchkey "$d/cfg.yml"
    )"
    assert_equals "" "$out" "an absent key yields nothing (#679)"

    out="$(
        eval_read_yaml_list
        read_yaml_list test_patterns "$d/does-not-exist.yml"
    )"
    assert_equals "" "$out" "a missing file yields nothing, and does not error (#679)"
}

# End-to-end: the same trailing-whitespace config must actually suppress the
# finding. This is the user-visible symptom from the issue — a pre-review.yml
# that "looks applied and is inert". write_bsd_sandbox writes the trailing
# spaces, so a regressed strip leaves the glob unmatchable and the row appears.
test_config_with_trailing_whitespace_still_applies() {
    local sb rows
    write_bsd_sandbox sb || return 1
    run_gate_in "$sb" "$BSD_LIST"

    rows="$(category_rows "$GATE_OUT" "missing-test-file")"
    assert_not_contains "$rows" "app.py" \
        "a config whose values carry trailing whitespace still suppresses (#679 AC#1)"
}

# End-to-end for #684, and the case that justifies the behaviour change.
#
# write_bsd_sandbox's test_discovery entry is QUOTED, so it was always stripped —
# the case above passes with and without the #684 fix. This sandbox declares the
# template UNQUOTED with trailing whitespace, which the old strip left in place.
#
# test_discovery is the key where that MATTERS: unlike the gitignore-backed keys
# (git strips pattern whitespace itself), a template is resolved by a literal
# `[ -f "$resolved" ]`, so `scripts/smoke-app.py   ` names a file that does not
# exist. The declared test went unfound and app.py was reported untested — a
# false finding whose cause was invisible in the config.
test_unquoted_test_discovery_with_trailing_whitespace_resolves() {
    # NOT named `dir` — new_git_sandbox has its own `local dir`, which would
    # shadow the caller's and swallow the `printf -v` writeback, leaving this
    # empty and every path below rooted at `/`.
    local rows sb=""
    new_git_sandbox sb || return 1
    command mkdir -p "$sb/.claude" "$sb/scripts"
    command printf '%s\n' "def app_public():" "    return 1" >"$sb/app.py"
    command printf '%s\n' "import app" "app.app_public()" >"$sb/scripts/smoke-app.py"
    # UNQUOTED template, trailing spaces. printf '%b' so they survive the file.
    {
        command printf '%s\n' "test_discovery:"
        command printf '%b' '  - scripts/smoke-{name}.py   \n'
    } >"$sb/.claude/pre-review.yml"
    command printf '%s\n' "$sb/app.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "missing-test-file")"
    assert_not_contains "$rows" "app.py" \
        "an UNQUOTED test_discovery template with trailing whitespace still resolves (#684)"
}

# AC#3: the parser must not swallow a failure. The pure-bash implementation has
# no subprocess to fail, so the positive form of "does not swallow" is that a
# config which parses produces no diagnostic noise on stderr — and, critically,
# that nothing leaks onto stdout, which carries the TSV contract.
test_config_parse_emits_no_stdout_noise() {
    local sb bad_rows
    write_bsd_sandbox sb || return 1
    run_gate_in_err "$sb" "$BSD_LIST"

    # Every stdout line must be a 5-column TSV finding — a diagnostic printed to
    # stdout would appear as a row with the wrong shape.
    bad_rows="$(command printf '%s\n' "$GATE_OUT" |
        command awk -F '\t' 'NF > 0 && NF != 5')"
    assert_equals "" "$bad_rows" \
        "config parsing writes nothing to stdout — the TSV contract stays clean (#679 AC#3)"
}

# The `\s` class in the debug scanners. BSD reads `\s` as a literal `s`, so
# `^\s*print\(` matched only an UNINDENTED print — the overwhelmingly common
# indented form was silently missed. The fixtures below are INDENTED on purpose:
# an unindented one matches under both readings and would prove nothing.
test_indented_debug_statements_are_found() {
    local d rows
    d="$(fresh_dir)"
    command printf '%s\n' "def f():" "    print(\"dbg\")" >"$d/a.py"
    command printf '%s\n' "function g() {" "    console.log(\"dbg\");" "}" >"$d/a.js"
    run_gate "$(make_list "$d" a.py a.js)"

    rows="$(category_rows "$GATE_OUT" "debug-statement")"
    assert_contains "$rows" "a.py" \
        "an INDENTED python print is found — [[:space:]] class, not GNU \\s (#679 AC#2)"
    assert_contains "$rows" "a.js" \
        "an INDENTED console.log is found — [[:space:]] class, not GNU \\s (#679 AC#2)"
}

# The BRE `\|` in the untested-public-api symbol extractor. Under BSD the
# substitution never fired, so func_name became the WHOLE source line, the
# `\b${func_name}\b` probe could never match, and every exported JS/TS symbol
# reported a false HIGH. Here the export IS referenced by its colocated test, so
# a correct extractor suppresses it; a broken one reports it.
test_exported_symbol_name_is_extracted() {
    local d rows
    d="$(fresh_dir)"
    command printf '%s\n' "export function fooBar() {" "  return 1;" "}" >"$d/mod.ts"
    command printf '%s\n' "import { fooBar } from './mod';" "test('fooBar', () => fooBar());" >"$d/mod.test.ts"
    run_gate "$(make_list "$d" mod.ts)"

    rows="$(category_rows "$GATE_OUT" "untested-public-api")"
    assert_not_contains "$rows" "mod.ts" \
        "a tested export is not flagged — the symbol name extracts via ERE alternation (#679 AC#2)"
}
