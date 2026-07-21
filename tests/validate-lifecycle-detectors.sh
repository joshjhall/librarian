#!/usr/bin/env bash
# check-lifecycle detector behavioral gate (issue #435).
#
# check-lifecycle is a resource-lifecycle pre-scan (unreaped-subprocess /
# terminate-without-kill / unclosed-handle / unpaired-listener) across Swift,
# Python, JS/TS, and Go. Like the check-security / check-code-health family
# before #348, its correctness is otherwise only covered by
# tests/validate-python-ports.sh (bash==python parity over one shared tree) and
# tests/validate-prescan-differential.sh (bash==python over the whole repo) —
# both of which, as their headers note, cannot catch a regression where BOTH
# impls break the same way. This gate is the behavioral half: it drives
# PURPOSE-BUILT fixtures through the scanner and asserts the SPECIFIC category
# each fixture must emit, AND that a safe counter-fixture stays silent — with
# emphasis on the low-false-positive BOUNDARIES that make a lifecycle scanner
# usable:
#
#   * the assignment-anchored unclosed-handle (`f = open()` fires, the *same-line*
#     scoped `with open() as f:` stays silent — while a *following-line* Go
#     `defer f.Close()` is NOT visible to a single-line regex, so the Go handle
#     still fires as a MEDIUM candidate the LLM pass-2 resolves; both boundaries
#     asserted below),
#   * the ruled-out false positives the motivating issue calls out as required
#     negative fixtures — a background pipe-reader that drains correctly, and a
#     collection that IS cleared (bounded, not the LLM-only unbounded-growth),
#   * the WHOLESALE test-file skip (check-lifecycle skips a whole test file, not
#     just one category, since lifecycle shortcuts in test scaffolding are
#     expected), asserted via the segment-anchored is_test_file.
#
# Each category is asserted against BOTH the Python primary (patterns.py) and the
# bash fallback (PATTERNS_FORCE_BASH=1 patterns.sh) — free parity reinforcement on
# top of validate-python-ports.sh's whole-corpus diff.
#
# The sibling tests/coverage-python.sh corpus is extended in lockstep so the same
# per-language branches execute under measurement; coverage rises because
# behavior is asserted, never the reverse.
#
# The port reads only file CONTENT (no git-rooting), so its CWD is irrelevant and
# every fixture runs from $WORKDIR.
#
# SKIPS (does not fail) the python assertions when a python3>=3.11 is unavailable
# — the same posture as validate-source-detectors.sh; the bash path is still
# asserted.
#
# Pure bash-3.2 + coreutils; full /usr/bin/* paths per project convention.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS_DIR="$REPO_ROOT/plugins/review-audit/skills"

REAL_BASH="$(command -v bash)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "check-lifecycle detector fixtures (#435)"

HAVE_PY=0
if command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    HAVE_PY=1
fi

WORKDIR="$(/usr/bin/mktemp -d)"
trap '/usr/bin/rm -rf "$WORKDIR"' EXIT

SK="$SKILLS_DIR/check-lifecycle"

# --- Scanner drivers ---------------------------------------------------------
# emit_rows IMPL LIST CAT — the rows one impl emits for a single category. IMPL
# is "py" or "sh".
emit_rows() {
    local impl="$1" list="$2" cat="$3"
    if [ "$impl" = py ]; then
        python3 "$SK/patterns.py" "$list" 2>/dev/null
    else
        /usr/bin/env PATTERNS_FORCE_BASH=1 "$REAL_BASH" "$SK/patterns.sh" "$list" 2>/dev/null
    fi | /usr/bin/awk -F '\t' -v c="$cat" '$3 == c'
}

# assert_fires LIST CAT NEEDLE MSG — the category fires (rows contain NEEDLE) in
# BOTH impls. Python side skipped (not failed) when absent.
assert_fires() {
    local list="$1" cat="$2" needle="$3" msg="$4"
    assert_contains "$(emit_rows sh "$list" "$cat")" "$needle" "$msg (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_contains "$(emit_rows py "$list" "$cat")" "$needle" "$msg (python)"
    fi
}

# assert_silent LIST CAT MSG — the category emits NOTHING in both impls.
assert_silent() {
    local list="$1" cat="$2" msg="$3"
    assert_output_empty "$(emit_rows sh "$list" "$cat")" "$msg (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_output_empty "$(emit_rows py "$list" "$cat")" "$msg (python)"
    fi
}

# fresh_dir — unique scratch dir per fixture so path resolution is clean.
fresh_dir() { /usr/bin/mktemp -d "$WORKDIR/case.XXXXXX"; }

# make_list OUTFILE PATH... — write a newline file list, echo its path.
make_list() {
    local out="$1"
    shift
    : >"$out"
    local p
    for p in "$@"; do
        /usr/bin/printf '%s\n' "$p" >>"$out"
    done
    /usr/bin/printf '%s' "$out"
}

# ============================================================================
# unreaped-subprocess — spawn sites across all four languages
# ============================================================================
test_unreaped_subprocess() {
    local d list

    # Swift Process()
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'let task = Process()' >"$d/a.swift"
    list="$(make_list "$d/l" "$d/a.swift")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: Swift Process() spawn fires"

    # Python Popen / subprocess.Popen
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n%s\n' 'proc = subprocess.Popen(["ls"])' 'p2 = Popen(cmd)' >"$d/b.py"
    list="$(make_list "$d/l" "$d/b.py")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: Python Popen spawn fires"

    # JS spawn / execFile / bare exec (child_process.exec — the common Node form)
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n%s\n%s\n' \
        'const child = spawn("ls", args)' \
        'const r = execFile("cat", [f])' \
        'const e = exec("ls -la", cb)' >"$d/c.js"
    list="$(make_list "$d/l" "$d/c.js")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: JS spawn/execFile/exec fires"

    # Go exec.Command
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'cmd := exec.Command("ls")' >"$d/d.go"
    list="$(make_list "$d/l" "$d/d.go")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: Go exec.Command fires"

    # The remaining JS spawn-family alternatives (spawnSync/execFileSync/execSync)
    # asserted independently so a regression dropping one can't hide behind
    # another (same isolation principle as the listener category).
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'const a = spawnSync("ls")' >"$d/ss.js"
    list="$(make_list "$d/l" "$d/ss.js")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: JS spawnSync fires"

    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'const b = execFileSync("cat", [f])' >"$d/efs.js"
    list="$(make_list "$d/l" "$d/efs.js")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: JS execFileSync fires"

    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'const c = execSync("ls -la")' >"$d/es.js"
    list="$(make_list "$d/l" "$d/es.js")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: JS execSync fires"

    # Negative: a plain function call that merely CONTAINS "spawn" as a substring
    # of another identifier must NOT fire (word-boundary anchor).
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'const n = respawnCounter(x)' >"$d/neg.js"
    list="$(make_list "$d/l" "$d/neg.js")"
    assert_silent "$list" unreaped-subprocess \
        "lifecycle: respawnCounter (substring, not a call) does NOT fire"

    # KNOWN TRADE-OFF (pinned): the broad `\bexec\s*\(` alternative also matches
    # the unrelated JS idiom `regex.exec(str)` (RegExp.prototype.exec). This is a
    # DELIBERATE false positive the MEDIUM certainty + LLM pass-2 confirm/dismiss
    # absorbs — pinning it here makes any future regex tightening a reviewed,
    # intentional change rather than a silent drift.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'const m = /ab+c/.exec(input)' >"$d/re.js"
    list="$(make_list "$d/l" "$d/re.js")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: regex.exec() fires (pinned FP; pass-2 dismisses)"
}

# ============================================================================
# terminate-without-kill — SIGTERM / .terminate() / os.Interrupt send sites
# ============================================================================
test_terminate_without_kill() {
    local d list

    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'task.terminate()' >"$d/a.swift"
    list="$(make_list "$d/l" "$d/a.swift")"
    assert_fires "$list" terminate-without-kill "Terminate without kill escalation" \
        "lifecycle: Swift .terminate() fires"

    # Python .terminate() — the arm exists for all four languages, assert it.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'proc.terminate()' >"$d/b.py"
    list="$(make_list "$d/l" "$d/b.py")"
    assert_fires "$list" terminate-without-kill "Terminate without kill escalation" \
        "lifecycle: Python .terminate() fires"

    # JS .terminate() (e.g. a Worker) — assert the JS arm independently.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'child.terminate()' >"$d/c.js"
    list="$(make_list "$d/l" "$d/c.js")"
    assert_fires "$list" terminate-without-kill "Terminate without kill escalation" \
        "lifecycle: JS .terminate() fires"

    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'signal.Notify(c, os.Interrupt)' >"$d/d.go"
    list="$(make_list "$d/l" "$d/d.go")"
    assert_fires "$list" terminate-without-kill "Terminate without kill escalation" \
        "lifecycle: Go os.Interrupt fires"
}

# ============================================================================
# unclosed-handle — ASSIGNMENT form fires; scoped form stays silent
# ============================================================================
test_unclosed_handle() {
    local d list

    # Python assignment form fires.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'f = open("x.txt")' >"$d/a.py"
    list="$(make_list "$d/l" "$d/a.py")"
    assert_fires "$list" unclosed-handle "Handle acquired without scoped close" \
        "lifecycle: Python f = open() fires"

    # Python scoped `with open() as f:` stays SILENT (the low-FP boundary — no
    # `= open(` assignment).
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'with open("x.txt") as f:' >"$d/b.py"
    list="$(make_list "$d/l" "$d/b.py")"
    assert_silent "$list" unclosed-handle \
        "lifecycle: Python with open() as f is bounded (silent)"

    # Go os.Open / os.Create assignment fires.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'f, err := os.Open("x.txt")' >"$d/c.go"
    list="$(make_list "$d/l" "$d/c.go")"
    assert_fires "$list" unclosed-handle "Handle acquired without scoped close" \
        "lifecycle: Go os.Open fires"

    # BOUNDARY: a Go handle WITH a following-line `defer f.Close()` STILL fires —
    # a single-line regex cannot see the next-line defer, so it is emitted as a
    # MEDIUM candidate that the LLM pass-2 confirms is actually closed and
    # dismisses. This documents the real (not defer-aware) behavior and guards
    # against a doc claim that the regex is boundary-aware when it is not.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n%s\n' 'f, err := os.Open("x.txt")' '	defer f.Close()' >"$d/deferred.go"
    list="$(make_list "$d/l" "$d/deferred.go")"
    assert_fires "$list" unclosed-handle "Handle acquired without scoped close" \
        "lifecycle: Go os.Open + defer still fires (candidate; pass-2 resolves)"

    # JS fs.openSync assignment fires.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'const s = fs.openSync(path, "r")' >"$d/d.js"
    list="$(make_list "$d/l" "$d/d.js")"
    assert_fires "$list" unclosed-handle "Handle acquired without scoped close" \
        "lifecycle: JS fs.openSync fires"

    # JS createReadStream/createWriteStream alternatives asserted independently.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'const rs = fs.createReadStream(path)' >"$d/crs.js"
    list="$(make_list "$d/l" "$d/crs.js")"
    assert_fires "$list" unclosed-handle "Handle acquired without scoped close" \
        "lifecycle: JS fs.createReadStream fires"

    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'const ws = fs.createWriteStream(path)' >"$d/cws.js"
    list="$(make_list "$d/l" "$d/cws.js")"
    assert_fires "$list" unclosed-handle "Handle acquired without scoped close" \
        "lifecycle: JS fs.createWriteStream fires"

    # Go os.Create alternative asserted independently (os.Open covered above).
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'g, err := os.Create("y.txt")' >"$d/cr.go"
    list="$(make_list "$d/l" "$d/cr.go")"
    assert_fires "$list" unclosed-handle "Handle acquired without scoped close" \
        "lifecycle: Go os.Create fires"

    # Swift FileHandle() assignment fires.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'let fh = FileHandle(forReadingAtPath: p)' >"$d/e.swift"
    list="$(make_list "$d/l" "$d/e.swift")"
    assert_fires "$list" unclosed-handle "Handle acquired without scoped close" \
        "lifecycle: Swift FileHandle() fires"
}

# ============================================================================
# unpaired-listener — registration sites (JS + Swift)
# ============================================================================
test_unpaired_listener() {
    local d list

    # Each JS registration form is asserted in its OWN fixture so a regression in
    # one regex alternative can't hide behind another (the label is shared, so a
    # composite fixture would pass as long as any single alternative still fired).
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'el.addEventListener("click", h)' >"$d/aev.js"
    list="$(make_list "$d/l" "$d/aev.js")"
    assert_fires "$list" unpaired-listener "Listener/timer registered without visible removal" \
        "lifecycle: JS addEventListener fires"

    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'const t = setInterval(tick, 1000)' >"$d/iv.js"
    list="$(make_list "$d/l" "$d/iv.js")"
    assert_fires "$list" unpaired-listener "Listener/timer registered without visible removal" \
        "lifecycle: JS setInterval fires"

    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'emitter.on("data", cb)' >"$d/on.js"
    list="$(make_list "$d/l" "$d/on.js")"
    assert_fires "$list" unpaired-listener "Listener/timer registered without visible removal" \
        "lifecycle: JS .on( fires"

    # Both Swift alternatives (addObserver, scheduledTimer) asserted independently.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'NotificationCenter.default.addObserver(self, selector: s)' >"$d/obs.swift"
    list="$(make_list "$d/l" "$d/obs.swift")"
    assert_fires "$list" unpaired-listener "Listener/timer registered without visible removal" \
        "lifecycle: Swift addObserver fires"

    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'let t = Timer.scheduledTimer(withTimeInterval: 1)' >"$d/tmr.swift"
    list="$(make_list "$d/l" "$d/tmr.swift")"
    assert_fires "$list" unpaired-listener "Listener/timer registered without visible removal" \
        "lifecycle: Swift scheduledTimer fires"

    # KNOWN TRADE-OFF (pinned): the broad `\.on\s*\(` alternative also matches any
    # object's `.on()` method (state-machine DSLs, promise-like APIs), not just
    # EventEmitter registration. A DELIBERATE false positive the MEDIUM certainty
    # + LLM pass-2 absorbs — pinned so a future regex tightening is intentional.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' "machine.on('idle', handler)" >"$d/dsl.js"
    list="$(make_list "$d/l" "$d/dsl.js")"
    assert_fires "$list" unpaired-listener "Listener/timer registered without visible removal" \
        "lifecycle: generic .on() fires (pinned FP; pass-2 dismisses)"
}

# ============================================================================
# Ruled-out false positives — the motivating issue's REQUIRED negative fixtures
# ============================================================================
test_ruled_out_false_positives() {
    local d list

    # A background pipe-reader that drains and signals correctly — no acquisition
    # in ASSIGNMENT/open form, so no unclosed-handle row (the issue's #3a FP).
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n%s\n%s\n' \
        'for line in pipe:' \
        '    handler(line)' \
        'done.set()' >"$d/reader.py"
    list="$(make_list "$d/l" "$d/reader.py")"
    assert_silent "$list" unclosed-handle \
        "lifecycle: draining pipe-reader is not an unclosed-handle (issue FP #3a)"

    # A dict that IS cleared on removal — bounded, so no deterministic row at all
    # (unbounded-growth is LLM-only; the pre-scan must stay silent here — the
    # issue's #3b FP).
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n%s\n' 'cache[k] = v' 'del cache[k]' >"$d/cache.py"
    list="$(make_list "$d/l" "$d/cache.py")"
    assert_silent "$list" unbounded-growth \
        "lifecycle: a cleared dict is bounded — no deterministic unbounded-growth row (issue FP #3b)"
}

# ============================================================================
# Wholesale test-file skip — check-lifecycle skips a WHOLE test file
# ============================================================================
test_test_file_and_skip() {
    local d list

    # A spawn under a tests/ segment is suppressed WHOLESALE.
    d="$(fresh_dir)"
    /usr/bin/mkdir -p "$d/tests"
    /usr/bin/printf '%s\n' 'let task = Process()' >"$d/tests/helper.swift"
    list="$(make_list "$d/l" "$d/tests/helper.swift")"
    assert_silent "$list" unreaped-subprocess \
        "lifecycle: Process() under a tests/ segment is suppressed (wholesale)"

    # ...but contest.swift is NOT a test file (segment-anchored, not substring).
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'let task = Process()' >"$d/contest.swift"
    list="$(make_list "$d/l" "$d/contest.swift")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: contest.swift is NOT a test file (segment-anchoring negative)"

    # A *.md carrying a spawn-shaped line is skipped wholesale (SKIP_GLOBS).
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'Example: `let task = Process()`' >"$d/notes.md"
    list="$(make_list "$d/l" "$d/notes.md")"
    assert_silent "$list" unreaped-subprocess \
        "lifecycle: a spawn inside a *.md is skipped (SKIP_GLOBS)"
}

# ============================================================================
# Evidence truncation parity — >80-char multibyte line, bash == python
# ============================================================================
# Drives emit()'s EVIDENCE_CAP=80 CHARACTER truncation and the bash
# truncate_chars char-vs-byte slicing (#17) for THIS port: a lifecycle-triggering
# line padded past 80 chars with a multibyte em-dash. The two impls must emit the
# byte-identical truncated evidence (char-count, not byte-count) — the same
# property the whole-repo differential gate pins generally, asserted here for a
# row this scanner actually produces.
test_evidence_truncation_parity() {
    local d list long
    d="$(fresh_dir)"
    # `p = open(...)` fires unclosed-handle; pad the arg with an em-dash (—, 3
    # UTF-8 bytes) run so the line exceeds 80 characters and truncation engages.
    long="p = open(\"$(printf '%0.s—' $(seq 1 60))\")"
    /usr/bin/printf '%s\n' "$long" >"$d/long.py"
    list="$(make_list "$d/l" "$d/long.py")"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_equals \
            "$(emit_rows sh "$list" unclosed-handle)" \
            "$(emit_rows py "$list" unclosed-handle)" \
            "lifecycle: >80-char multibyte evidence truncates identically (bash==python)"
    else
        skip_test "lifecycle: truncation parity needs python3>=3.11 (bash path still runs)"
        emit_rows sh "$list" unclosed-handle >/dev/null
    fi
}

run_test test_unreaped_subprocess "check-lifecycle: swift/py/js/go subprocess spawn arms + word-boundary negative"
run_test test_terminate_without_kill "check-lifecycle: .terminate() + os.Interrupt terminate arms"
run_test test_unclosed_handle "check-lifecycle: py/go/js handle assignment fires, scoped with-open stays silent"
run_test test_unpaired_listener "check-lifecycle: JS addEventListener/setInterval/.on + Swift addObserver"
run_test test_ruled_out_false_positives "check-lifecycle: draining pipe-reader + cleared dict negative fixtures (issue FPs)"
run_test test_test_file_and_skip "check-lifecycle: wholesale test-file skip + segment anchoring + SKIP_GLOBS"
run_test test_evidence_truncation_parity "check-lifecycle: >80-char multibyte evidence truncation parity (bash==python)"

generate_report
