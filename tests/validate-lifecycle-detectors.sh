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

# PHYSICAL path: macOS $TMPDIR is under /var, a symlink to /private/var, so
# `mktemp -d` returns /var/... while git and realpath-based code resolve the
# same dir to /private/var/... Any prefix match between the two spellings
# fails, silently dropping rows or refusing valid paths (#932).
WORKDIR="$(command mktemp -d)"
WORKDIR="$(cd "$WORKDIR" && command pwd -P)"
trap 'command rm -rf "$WORKDIR"' EXIT

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
    fi | command awk -F '\t' -v c="$cat" '$3 == c'
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
fresh_dir() { command mktemp -d "$WORKDIR/case.XXXXXX"; }

# make_list OUTFILE PATH... — write a newline file list, echo its path.
make_list() {
    local out="$1"
    shift
    : >"$out"
    local p
    for p in "$@"; do
        command printf '%s\n' "$p" >>"$out"
    done
    command printf '%s' "$out"
}

# ============================================================================
# unreaped-subprocess — spawn sites across all four languages
# ============================================================================
test_unreaped_subprocess() {
    local d list

    # Swift Process()
    d="$(fresh_dir)"
    command printf '%s\n' 'let task = Process()' >"$d/a.swift"
    list="$(make_list "$d/l" "$d/a.swift")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: Swift Process() spawn fires"

    # Python Popen / subprocess.Popen
    d="$(fresh_dir)"
    command printf '%s\n%s\n' 'proc = subprocess.Popen(["ls"])' 'p2 = Popen(cmd)' >"$d/b.py"
    list="$(make_list "$d/l" "$d/b.py")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: Python Popen spawn fires"

    # JS spawn / execFile / bare exec (child_process.exec — the common Node form)
    d="$(fresh_dir)"
    command printf '%s\n%s\n%s\n' \
        'const child = spawn("ls", args)' \
        'const r = execFile("cat", [f])' \
        'const e = exec("ls -la", cb)' >"$d/c.js"
    list="$(make_list "$d/l" "$d/c.js")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: JS spawn/execFile/exec fires"

    # ESM/CJS (#840). This scanner has ONE arm covering all four categories, so
    # the missing .mjs/.cjs made every lifecycle category blind to them at once.
    # The .js case above is the control for these two.
    d="$(fresh_dir)"
    command printf '%s\n' 'const child = spawn("ls", args)' >"$d/c.mjs"
    list="$(make_list "$d/l" "$d/c.mjs")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: ESM (.mjs) spawn fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'const child = spawn("ls", args)' >"$d/c.cjs"
    list="$(make_list "$d/l" "$d/c.cjs")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: CJS (.cjs) spawn fires"

    # Go exec.Command
    d="$(fresh_dir)"
    command printf '%s\n' 'cmd := exec.Command("ls")' >"$d/d.go"
    list="$(make_list "$d/l" "$d/d.go")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: Go exec.Command fires"

    # Rust Command::new (#838)
    d="$(fresh_dir)"
    command printf '%s\n' 'let mut child = Command::new("ls");' >"$d/e.rs"
    list="$(make_list "$d/l" "$d/e.rs")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: Rust Command::new fires"

    # KNOWN TRADE-OFF (pinned): the arm also matches `clap::Command::new`, the
    # CLI-builder idiom, which spawns nothing. A DELIBERATE false positive the
    # MEDIUM certainty + LLM pass-2 absorbs — the same treatment the broad JS
    # `.on(` alternative gets below. Pinned so a future narrowing is intentional
    # rather than an accidental behavior change.
    d="$(fresh_dir)"
    command printf '%s\n' 'let m = clap::Command::new("app").version("1.0");' >"$d/clap.rs"
    list="$(make_list "$d/l" "$d/clap.rs")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: clap::Command::new also fires (documented trade-off)"

    # The remaining JS spawn-family alternatives (spawnSync/execFileSync/execSync)
    # asserted independently so a regression dropping one can't hide behind
    # another (same isolation principle as the listener category).
    d="$(fresh_dir)"
    command printf '%s\n' 'const a = spawnSync("ls")' >"$d/ss.js"
    list="$(make_list "$d/l" "$d/ss.js")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: JS spawnSync fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'const b = execFileSync("cat", [f])' >"$d/efs.js"
    list="$(make_list "$d/l" "$d/efs.js")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: JS execFileSync fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'const c = execSync("ls -la")' >"$d/es.js"
    list="$(make_list "$d/l" "$d/es.js")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: JS execSync fires"

    # Negative: a plain function call that merely CONTAINS "spawn" as a substring
    # of another identifier must NOT fire (word-boundary anchor).
    d="$(fresh_dir)"
    command printf '%s\n' 'const n = respawnCounter(x)' >"$d/neg.js"
    list="$(make_list "$d/l" "$d/neg.js")"
    assert_silent "$list" unreaped-subprocess \
        "lifecycle: respawnCounter (substring, not a call) does NOT fire"

    # KNOWN TRADE-OFF (pinned): the broad `\bexec\s*\(` alternative also matches
    # the unrelated JS idiom `regex.exec(str)` (RegExp.prototype.exec). This is a
    # DELIBERATE false positive the MEDIUM certainty + LLM pass-2 confirm/dismiss
    # absorbs — pinning it here makes any future regex tightening a reviewed,
    # intentional change rather than a silent drift.
    d="$(fresh_dir)"
    command printf '%s\n' 'const m = /ab+c/.exec(input)' >"$d/re.js"
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
    command printf '%s\n' 'task.terminate()' >"$d/a.swift"
    list="$(make_list "$d/l" "$d/a.swift")"
    assert_fires "$list" terminate-without-kill "Terminate without kill escalation" \
        "lifecycle: Swift .terminate() fires"

    # Python .terminate() — the arm exists for all four languages, assert it.
    d="$(fresh_dir)"
    command printf '%s\n' 'proc.terminate()' >"$d/b.py"
    list="$(make_list "$d/l" "$d/b.py")"
    assert_fires "$list" terminate-without-kill "Terminate without kill escalation" \
        "lifecycle: Python .terminate() fires"

    # ESM (#840). The JS arm covers all four categories at once, so each one
    # needs its own .mjs proof — a single spawn() fixture would leave the other
    # three asserted by comment only. `.cjs` is deliberately not repeated for
    # these three: both extensions enter through the SAME case arm, and the
    # spawn .mjs/.cjs pair in test_unreaped_subprocess already proves that arm
    # treats them identically. What needed proving here is per-CATEGORY reach,
    # not per-extension.
    d="$(fresh_dir)"
    command printf '%s\n' 'proc.terminate()' >"$d/t.mjs"
    list="$(make_list "$d/l" "$d/t.mjs")"
    assert_fires "$list" terminate-without-kill "Terminate without kill escalation" \
        "lifecycle: ESM (.mjs) .terminate() fires"

    # JS .terminate() (e.g. a Worker) — assert the JS arm independently.
    d="$(fresh_dir)"
    command printf '%s\n' 'child.terminate()' >"$d/c.js"
    list="$(make_list "$d/l" "$d/c.js")"
    assert_fires "$list" terminate-without-kill "Terminate without kill escalation" \
        "lifecycle: JS .terminate() fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'signal.Notify(c, os.Interrupt)' >"$d/d.go"
    list="$(make_list "$d/l" "$d/d.go")"
    assert_fires "$list" terminate-without-kill "Terminate without kill escalation" \
        "lifecycle: Go os.Interrupt fires"

    # Rust explicit SIGTERM (#838) — the graceful send site, which is what this
    # category asks about.
    d="$(fresh_dir)"
    command printf '%s\n' 'signal::kill(pid, Signal::SIGTERM)?;' >"$d/e.rs"
    list="$(make_list "$d/l" "$d/e.rs")"
    assert_fires "$list" terminate-without-kill "Terminate without kill escalation" \
        "lifecycle: Rust SIGTERM send fires"

    # BOUNDARY: `Child::kill()` IS SIGKILL in std::process — it is the
    # ESCALATION this category checks for, not a graceful stop missing one. An
    # arm keying on `.kill()` would invert the question, so it must stay silent.
    d="$(fresh_dir)"
    command printf '%s\n' 'child.kill();' >"$d/k.rs"
    list="$(make_list "$d/l" "$d/k.rs")"
    assert_silent "$list" terminate-without-kill \
        "lifecycle: Rust child.kill() is SIGKILL itself and stays silent"
}

# ============================================================================
# unclosed-handle — ASSIGNMENT form fires; scoped form stays silent
# ============================================================================
test_unclosed_handle() {
    local d list

    # Python assignment form fires.
    d="$(fresh_dir)"
    command printf '%s\n' 'f = open("x.txt")' >"$d/a.py"
    list="$(make_list "$d/l" "$d/a.py")"
    assert_fires "$list" unclosed-handle "Handle acquired without scoped close" \
        "lifecycle: Python f = open() fires"

    # ESM (#840) — see the note in test_terminate_without_kill.
    d="$(fresh_dir)"
    command printf '%s\n' 'const s = fs.createReadStream(p)' >"$d/h.mjs"
    list="$(make_list "$d/l" "$d/h.mjs")"
    assert_fires "$list" unclosed-handle "Handle acquired without scoped close" \
        "lifecycle: ESM (.mjs) fs.createReadStream fires"

    # Python scoped `with open() as f:` stays SILENT (the low-FP boundary — no
    # `= open(` assignment).
    d="$(fresh_dir)"
    command printf '%s\n' 'with open("x.txt") as f:' >"$d/b.py"
    list="$(make_list "$d/l" "$d/b.py")"
    assert_silent "$list" unclosed-handle \
        "lifecycle: Python with open() as f is bounded (silent)"

    # Go os.Open / os.Create assignment fires.
    d="$(fresh_dir)"
    command printf '%s\n' 'f, err := os.Open("x.txt")' >"$d/c.go"
    list="$(make_list "$d/l" "$d/c.go")"
    assert_fires "$list" unclosed-handle "Handle acquired without scoped close" \
        "lifecycle: Go os.Open fires"

    # BOUNDARY: a Go handle WITH a following-line `defer f.Close()` STILL fires —
    # a single-line regex cannot see the next-line defer, so it is emitted as a
    # MEDIUM candidate that the LLM pass-2 confirms is actually closed and
    # dismisses. This documents the real (not defer-aware) behavior and guards
    # against a doc claim that the regex is boundary-aware when it is not.
    d="$(fresh_dir)"
    command printf '%s\n%s\n' 'f, err := os.Open("x.txt")' '	defer f.Close()' >"$d/deferred.go"
    list="$(make_list "$d/l" "$d/deferred.go")"
    assert_fires "$list" unclosed-handle "Handle acquired without scoped close" \
        "lifecycle: Go os.Open + defer still fires (candidate; pass-2 resolves)"

    # JS fs.openSync assignment fires.
    d="$(fresh_dir)"
    command printf '%s\n' 'const s = fs.openSync(path, "r")' >"$d/d.js"
    list="$(make_list "$d/l" "$d/d.js")"
    assert_fires "$list" unclosed-handle "Handle acquired without scoped close" \
        "lifecycle: JS fs.openSync fires"

    # JS createReadStream/createWriteStream alternatives asserted independently.
    d="$(fresh_dir)"
    command printf '%s\n' 'const rs = fs.createReadStream(path)' >"$d/crs.js"
    list="$(make_list "$d/l" "$d/crs.js")"
    assert_fires "$list" unclosed-handle "Handle acquired without scoped close" \
        "lifecycle: JS fs.createReadStream fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'const ws = fs.createWriteStream(path)' >"$d/cws.js"
    list="$(make_list "$d/l" "$d/cws.js")"
    assert_fires "$list" unclosed-handle "Handle acquired without scoped close" \
        "lifecycle: JS fs.createWriteStream fires"

    # Rust File::open / File::create assignment fires (#838).
    d="$(fresh_dir)"
    command printf '%s\n' 'let f = File::open("x.txt")?;' >"$d/e.rs"
    list="$(make_list "$d/l" "$d/e.rs")"
    assert_fires "$list" unclosed-handle "Handle acquired without scoped close" \
        "lifecycle: Rust File::open fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'let f = File::create("x.txt")?;' >"$d/c2.rs"
    list="$(make_list "$d/l" "$d/c2.rs")"
    assert_fires "$list" unclosed-handle "Handle acquired without scoped close" \
        "lifecycle: Rust File::create fires"

    # BOUNDARY: the arm requires the ASSIGNMENT form, matching every other
    # language here — a bare `File::open(p)?;` whose result is consumed inline
    # binds no handle to outlive the statement and stays silent.
    d="$(fresh_dir)"
    command printf '%s\n' 'read_to_string(File::open("x.txt")?)?;' >"$d/inline.rs"
    list="$(make_list "$d/l" "$d/inline.rs")"
    assert_silent "$list" unclosed-handle \
        "lifecycle: Rust non-assignment File::open is silent (assignment-anchored)"

    # Go os.Create alternative asserted independently (os.Open covered above).
    d="$(fresh_dir)"
    command printf '%s\n' 'g, err := os.Create("y.txt")' >"$d/cr.go"
    list="$(make_list "$d/l" "$d/cr.go")"
    assert_fires "$list" unclosed-handle "Handle acquired without scoped close" \
        "lifecycle: Go os.Create fires"

    # Swift FileHandle() assignment fires.
    d="$(fresh_dir)"
    command printf '%s\n' 'let fh = FileHandle(forReadingAtPath: p)' >"$d/e.swift"
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
    command printf '%s\n' 'el.addEventListener("click", h)' >"$d/aev.js"
    list="$(make_list "$d/l" "$d/aev.js")"
    assert_fires "$list" unpaired-listener "Listener/timer registered without visible removal" \
        "lifecycle: JS addEventListener fires"

    # ESM (#840) — see the note in test_terminate_without_kill.
    d="$(fresh_dir)"
    command printf '%s\n' 'el.addEventListener("click", h)' >"$d/aev.mjs"
    list="$(make_list "$d/l" "$d/aev.mjs")"
    assert_fires "$list" unpaired-listener "Listener/timer registered without visible removal" \
        "lifecycle: ESM (.mjs) addEventListener fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'const t = setInterval(tick, 1000)' >"$d/iv.js"
    list="$(make_list "$d/l" "$d/iv.js")"
    assert_fires "$list" unpaired-listener "Listener/timer registered without visible removal" \
        "lifecycle: JS setInterval fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'emitter.on("data", cb)' >"$d/on.js"
    list="$(make_list "$d/l" "$d/on.js")"
    assert_fires "$list" unpaired-listener "Listener/timer registered without visible removal" \
        "lifecycle: JS .on( fires"

    # Both Swift alternatives (addObserver, scheduledTimer) asserted independently.
    d="$(fresh_dir)"
    command printf '%s\n' 'NotificationCenter.default.addObserver(self, selector: s)' >"$d/obs.swift"
    list="$(make_list "$d/l" "$d/obs.swift")"
    assert_fires "$list" unpaired-listener "Listener/timer registered without visible removal" \
        "lifecycle: Swift addObserver fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'let t = Timer.scheduledTimer(withTimeInterval: 1)' >"$d/tmr.swift"
    list="$(make_list "$d/l" "$d/tmr.swift")"
    assert_fires "$list" unpaired-listener "Listener/timer registered without visible removal" \
        "lifecycle: Swift scheduledTimer fires"

    # Rust registration forms (#838), each in its own fixture for the same
    # isolation reason as the JS alternatives above. Rust has no DOM-style
    # addEventListener — the real long-lived registrations are a bound listening
    # socket and an installed signal handler.
    d="$(fresh_dir)"
    command printf '%s\n' 'let l = TcpListener::bind(addr)?;' >"$d/tcp.rs"
    list="$(make_list "$d/l" "$d/tcp.rs")"
    assert_fires "$list" unpaired-listener "Listener/timer registered without visible removal" \
        "lifecycle: Rust TcpListener::bind fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'let l = UnixListener::bind(path)?;' >"$d/unix.rs"
    list="$(make_list "$d/l" "$d/unix.rs")"
    assert_fires "$list" unpaired-listener "Listener/timer registered without visible removal" \
        "lifecycle: Rust UnixListener::bind fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'let mut s = signal::unix::signal(SignalKind::terminate())?;' >"$d/sig.rs"
    list="$(make_list "$d/l" "$d/sig.rs")"
    assert_fires "$list" unpaired-listener "Listener/timer registered without visible removal" \
        "lifecycle: Rust signal handler registration fires"

    # KNOWN TRADE-OFF (pinned): the broad `\.on\s*\(` alternative also matches any
    # object's `.on()` method (state-machine DSLs, promise-like APIs), not just
    # EventEmitter registration. A DELIBERATE false positive the MEDIUM certainty
    # + LLM pass-2 absorbs — pinned so a future regex tightening is intentional.
    d="$(fresh_dir)"
    command printf '%s\n' "machine.on('idle', handler)" >"$d/dsl.js"
    list="$(make_list "$d/l" "$d/dsl.js")"
    assert_fires "$list" unpaired-listener "Listener/timer registered without visible removal" \
        "lifecycle: generic .on() fires (pinned FP; pass-2 dismisses)"

    # Python registration forms (#841), each isolated for the same reason as the
    # JS and Rust alternatives above: the label is shared, so a composite fixture
    # would keep passing while all but one alternative rotted.
    d="$(fresh_dir)"
    command printf '%s\n' 'signal.signal(signal.SIGTERM, _handler)' >"$d/sig.py"
    list="$(make_list "$d/l" "$d/sig.py")"
    assert_fires "$list" unpaired-listener "Listener/timer registered without visible removal" \
        "lifecycle: Python signal.signal fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'atexit.register(_cleanup)' >"$d/exit.py"
    list="$(make_list "$d/l" "$d/exit.py")"
    assert_fires "$list" unpaired-listener "Listener/timer registered without visible removal" \
        "lifecycle: Python atexit.register fires"

    d="$(fresh_dir)"
    command printf '%s\n' 't = threading.Timer(5.0, _fire)' >"$d/timer.py"
    list="$(make_list "$d/l" "$d/timer.py")"
    assert_fires "$list" unpaired-listener "Listener/timer registered without visible removal" \
        "lifecycle: Python threading.Timer fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'loop.add_signal_handler(signal.SIGINT, _h)' >"$d/aio.py"
    list="$(make_list "$d/l" "$d/aio.py")"
    assert_fires "$list" unpaired-listener "Listener/timer registered without visible removal" \
        "lifecycle: Python add_signal_handler fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'loop.add_reader(fd, _on_readable)' >"$d/reader.py"
    list="$(make_list "$d/l" "$d/reader.py")"
    assert_fires "$list" unpaired-listener "Listener/timer registered without visible removal" \
        "lifecycle: Python add_reader fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'loop.add_writer(fd, _on_writable)' >"$d/writer.py"
    list="$(make_list "$d/l" "$d/writer.py")"
    assert_fires "$list" unpaired-listener "Listener/timer registered without visible removal" \
        "lifecycle: Python add_writer fires"

    # BOTH boundary edges, because one cannot fail on the other's bug (#839's
    # lesson: an identifier-ENDS-with fixture passed throughout while an
    # identifier-STARTS-with defect shipped).
    #
    # LEADING edge -- an identifier character before the token.
    d="$(fresh_dir)"
    command printf '%s\n%s\n' 'mysignal.signal(x)' 'xadd_reader(fd)' >"$d/lead.py"
    list="$(make_list "$d/l" "$d/lead.py")"
    assert_silent "$list" unpaired-listener \
        "lifecycle: Python listener leading-boundary negative (mysignal.signal / xadd_reader)"

    # TRAILING edge. `signal.signalx(` is written at LINE START on purpose: the
    # leading boundary is satisfied there (`^`), so this line can only be
    # rejected by the required `(` immediately following the token -- which is
    # what makes it a test of the trailing edge rather than a second test of the
    # leading one. A dotted `designal.signalx(` would NOT do: the leading class
    # already rejects it, so it would pass even with the trailing terminator
    # removed. The two edges must be probed by lines that only ONE of them can
    # reject (#839's lesson, applied to the other boundary).
    d="$(fresh_dir)"
    command printf '%s\n' 'signal.signalx(y)' >"$d/trail.py"
    list="$(make_list "$d/l" "$d/trail.py")"
    assert_silent "$list" unpaired-listener \
        "lifecycle: Python listener trailing-boundary negative (signal.signalx at line start)"

    # TRAILING edge, SECOND alternation half. The `signal.signalx` case above
    # only exercises the first half; both halves carry their own copy of the
    # `[[:space:]]*\(` terminator, so a future edit touching only this one
    # would otherwise be unpinned -- the same one-fixture-per-half rule the
    # qualified-form fixtures above exist for.
    d="$(fresh_dir)"
    command printf '%s\n' 'add_readerx(fd)' >"$d/trail2.py"
    list="$(make_list "$d/l" "$d/trail2.py")"
    assert_silent "$list" unpaired-listener \
        "lifecycle: Python listener trailing-boundary negative, second half (add_readerx at line start)"

    # The bare-Timer exclusion, separately: `threading.Timer` is matched but a
    # bare `Timer(` is not (measured too generic for this certainty tier).
    d="$(fresh_dir)"
    command printf '%s\n' 't = Timer(5.0, fn)' >"$d/bare.py"
    list="$(make_list "$d/l" "$d/bare.py")"
    assert_silent "$list" unpaired-listener \
        "lifecycle: Python bare Timer( is excluded (only threading.Timer matches)"

    # The boundary class ADMITS `.`, so a QUALIFIED registration still fires.
    # This is the fixture the boundary mutation asked for: an earlier draft
    # excluded `.` from the class to reject `mysignal.signal(` -- which the
    # identifier boundary above already rejects on its own -- and the exclusion
    # silenced these instead. Without this fixture that false negative is
    # invisible, because every other listener fixture is written unqualified.
    # ONE FIXTURE PER ALTERNATION HALF, for the isolation reason stated at the
    # top of this function -- and it is not hypothetical here. A first draft put
    # both lines in one file; the boundary mutation then left `mod.threading`
    # silent while `self.loop.add_reader` (the OTHER half, unmutated) still
    # emitted the shared label, so assert_fires passed and the fixture proved
    # nothing.
    d="$(fresh_dir)"
    command printf '%s\n' 'mod.threading.Timer(1, fn)' >"$d/qual1.py"
    list="$(make_list "$d/l" "$d/qual1.py")"
    assert_fires "$list" unpaired-listener "Listener/timer registered without visible removal" \
        "lifecycle: Python QUALIFIED registration fires (mod.threading.Timer)"

    d="$(fresh_dir)"
    command printf '%s\n' 'self.loop.add_reader(fd, cb)' >"$d/qual2.py"
    list="$(make_list "$d/l" "$d/qual2.py")"
    assert_fires "$list" unpaired-listener "Listener/timer registered without visible removal" \
        "lifecycle: Python QUALIFIED registration fires (self.loop.add_reader)"

    # NON-ASCII BOUNDARY -- the UTF-8 behaviour is pinned; the C-locale gap is
    # named as a KNOWN LIMITATION rather than asserted away (#841).
    #
    # THE LOCALE IS THE POINT, so these run the scanners under `env -i` with an
    # explicit locale rather than inheriting the suite's. An earlier version ran
    # ambient and passed while a bug was live: the box's LANG=C.UTF-8 meant the
    # C-locale path was never exercised at all.
    #
    # The leading boundary is POSIX `grep -w` (see emit_rows_word in
    # patterns.sh). Under a UTF-8 locale it agrees with the python twin exactly,
    # on BOTH shapes below -- a multibyte LETTER prefix (rejected: it is part of
    # the identifier) and multibyte PUNCTUATION (accepted: a real boundary).
    # Under a strict `C` locale `-w` decides word-ness bytewise and the LETTER
    # case diverges; that gap is pinned separately below.
    d="$(fresh_dir)"
    command printf 'caf\303\251add_reader(fd)\n' >"$d/nonascii.py"
    list="$(make_list "$d/l" "$d/nonascii.py")"

    _na_sh="$(/usr/bin/env -i LANG=C.UTF-8 LC_ALL=C.UTF-8 "PATH=$PATH" \
        PATTERNS_FORCE_BASH=1 "$REAL_BASH" "$SK/patterns.sh" "$list" 2>/dev/null |
        command awk -F '\t' '$3 == "unpaired-listener"')"
    assert_output_empty "$_na_sh" \
        "lifecycle: non-ASCII IDENTIFIER boundary silent in bash under a UTF-8 locale"
    if [ "$HAVE_PY" -eq 1 ]; then
        _na_py="$(/usr/bin/env -i LANG=C.UTF-8 LC_ALL=C.UTF-8 "PATH=$PATH" \
            python3 "$SK/patterns.py" "$list" 2>/dev/null |
            command awk -F '\t' '$3 == "unpaired-listener"')"
        assert_output_empty "$_na_py" \
            "lifecycle: non-ASCII IDENTIFIER boundary silent in python (agrees under UTF-8)"
    fi

    # KNOWN LIMITATION, pinned so a locale change SURFACES here instead of
    # silently widening the gap. Under `LC_ALL=C` the same line fires in bash
    # and not in python -- a false positive on what is REAL CODE, since PEP 3131
    # permits non-ASCII identifiers, so `caf<e-acute>add_reader` compiles. This
    # is asserted as the CURRENT behaviour, not as desirable: if a future change
    # makes the two agree under C, this assertion SHOULD fail and be revisited.
    _na_sh_c="$(/usr/bin/env -i LANG=C LC_ALL=C "PATH=$PATH" \
        PATTERNS_FORCE_BASH=1 "$REAL_BASH" "$SK/patterns.sh" "$list" 2>/dev/null |
        command awk -F '\t' '$3 == "unpaired-listener"')"
    assert_contains "$_na_sh_c" "Listener/timer registered without visible removal" \
        "lifecycle: KNOWN GAP -- non-ASCII identifier fires in bash under LC_ALL=C (python does not)"

    # Multibyte PUNCTUATION abutting a call is a REAL boundary, and unlike the
    # identifier case the two runtimes agree on it under both locales. This is
    # what the earlier high-byte bracket class got wrong (it silenced bash here),
    # so it is pinned in both directions.
    d="$(fresh_dir)"
    command printf '\342\200\224add_reader(fd)\n' >"$d/emdash.py"
    list="$(make_list "$d/l" "$d/emdash.py")"
    for _loc in C C.UTF-8; do
        _em_sh="$(/usr/bin/env -i "LANG=$_loc" "LC_ALL=$_loc" "PATH=$PATH" \
            PATTERNS_FORCE_BASH=1 "$REAL_BASH" "$SK/patterns.sh" "$list" 2>/dev/null |
            command awk -F '\t' '$3 == "unpaired-listener"')"
        assert_contains "$_em_sh" "Listener/timer registered without visible removal" \
            "lifecycle: multibyte PUNCTUATION boundary fires in bash under LC_ALL=$_loc"
    done

    # `-w` alone would match a bare mention with no call, so the paren test is
    # re-imposed separately in emit_rows_word. This pins that it still applies.
    d="$(fresh_dir)"
    command printf '%s\n' 'add_reader = 5' >"$d/nocall.py"
    list="$(make_list "$d/l" "$d/nocall.py")"
    assert_silent "$list" unpaired-listener \
        "lifecycle: a bare mention with no call does not fire (the -w paren guard)"

    # ONE row, not two, for a line matching BOTH halves of the alternation --
    # the property that keeps the single-emit_rows spelling honest. Asserted on
    # the row COUNT because assert_fires only proves at least one row.
    d="$(fresh_dir)"
    command printf '%s\n' 'signal.signal(a) and atexit.register(b)' >"$d/both.py"
    list="$(make_list "$d/l" "$d/both.py")"
    assert_equals "1" "$(emit_rows sh "$list" unpaired-listener | command wc -l | command tr -d ' ')" \
        "lifecycle: Python line matching both alternation halves emits ONE row (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_equals "1" "$(emit_rows py "$list" unpaired-listener | command wc -l | command tr -d ' ')" \
            "lifecycle: Python line matching both alternation halves emits ONE row (python)"
    fi
}

# ============================================================================
# Ruled-out false positives — the motivating issue's REQUIRED negative fixtures
# ============================================================================
test_ruled_out_false_positives() {
    local d list

    # A background pipe-reader that drains and signals correctly — no acquisition
    # in ASSIGNMENT/open form, so no unclosed-handle row (the issue's #3a FP).
    d="$(fresh_dir)"
    command printf '%s\n%s\n%s\n' \
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
    command printf '%s\n%s\n' 'cache[k] = v' 'del cache[k]' >"$d/cache.py"
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
    command mkdir -p "$d/tests"
    command printf '%s\n' 'let task = Process()' >"$d/tests/helper.swift"
    list="$(make_list "$d/l" "$d/tests/helper.swift")"
    assert_silent "$list" unreaped-subprocess \
        "lifecycle: Process() under a tests/ segment is suppressed (wholesale)"

    # ...but contest.swift is NOT a test file (segment-anchored, not substring).
    d="$(fresh_dir)"
    command printf '%s\n' 'let task = Process()' >"$d/contest.swift"
    list="$(make_list "$d/l" "$d/contest.swift")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: contest.swift is NOT a test file (segment-anchoring negative)"

    # A *.md carrying a spawn-shaped line is skipped wholesale (SKIP_GLOBS).
    d="$(fresh_dir)"
    command printf '%s\n' 'Example: `let task = Process()`' >"$d/notes.md"
    list="$(make_list "$d/l" "$d/notes.md")"
    assert_silent "$list" unreaped-subprocess \
        "lifecycle: a spawn inside a *.md is skipped (SKIP_GLOBS)"
}

# ============================================================================
# #836 — a test_*-named DIRECTORY must NOT skip the real source inside it
# ============================================================================
# The name arms of is_test_file() are matched against the BASENAME; the path
# arms above them are the ones meant to cross `/`. Before the fix the bash copy
# used the pre-#568 path-crossing form `test_*.* | */test_*.*`, whose `*` crosses
# `/` in a bash `case` glob — so a DIRECTORY named `test_helpers/` matched, and
# check-lifecycle (which skips a test file WHOLESALE) dropped every finding for
# real source beneath it. The Python twin was already basename-anchored, making
# this a live TSV-parity violation invisible to every existing gate: the
# whole-repo differential (validate-prescan-differential.sh) can only diff inputs
# the repo actually contains, and this repo has no test_*-named directory at all.
#
# Both halves of this fixture assert the row FIRES. The control under a plainly
# non-test directory is what distinguishes "the fix works" from "emit_rows broke
# and everything is silent" — without it, a scanner that emitted nothing at all
# would still satisfy a bare-silence assertion elsewhere in this file.
test_test_dir_does_not_skip_source() {
    local d list

    # The regression: real source under src/test_helpers/ MUST still be scanned.
    d="$(fresh_dir)"
    command mkdir -p "$d/src/test_helpers"
    command printf '%s\n' 'proc = subprocess.Popen(["ls"])' \
        >"$d/src/test_helpers/production.py"
    list="$(make_list "$d/l" "$d/src/test_helpers/production.py")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: source under a test_*-named DIRECTORY is still scanned (#836)"

    # Control: byte-identical content under a plain directory also fires, so a
    # silent scanner cannot masquerade as a passing fix.
    d="$(fresh_dir)"
    command mkdir -p "$d/src/helpers"
    command printf '%s\n' 'proc = subprocess.Popen(["ls"])' \
        >"$d/src/helpers/production.py"
    list="$(make_list "$d/l" "$d/src/helpers/production.py")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: identical source under a plain directory fires (#836 control)"

    # The BASENAME form still skips — the fix narrows the arm, it does not
    # remove it. test_production.py is a genuine test file and stays suppressed.
    d="$(fresh_dir)"
    command mkdir -p "$d/src/helpers"
    command printf '%s\n' 'proc = subprocess.Popen(["ls"])' \
        >"$d/src/helpers/test_production.py"
    list="$(make_list "$d/l" "$d/src/helpers/test_production.py")"
    assert_silent "$list" unreaped-subprocess \
        "lifecycle: a test_-prefixed FILE is still skipped wholesale (#836 narrowness)"
}

# ============================================================================
# Bash arms (#842, ADR 0002 Phase 5) — two modeled categories, two pinned `—`
# ============================================================================
# Every positive below sits in its OWN fresh_dir. The evidence label is shared
# across languages, so a composite file would pass as long as ANY arm still
# fired — the vacuous-fixture trap Phase 4 hit while writing a fixture FOR a
# mutation.
#
# The negatives are the load-bearing half here: this arm's correctness is almost
# entirely its exclusions, and each was measured necessary against the repo's own
# shell corpus rather than reasoned about.
test_bash_lifecycle_arms() {
    local d list

    # --- unreaped-subprocess: the backgrounded job -------------------------
    d="$(fresh_dir)"
    command printf '%s\n' 'command sleep 30 &' >"$d/bg.sh"
    list="$(make_list "$d/l" "$d/bg.sh")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: bash trailing-& background job fires"

    # The .bash extension reaches the same arm (both runtimes dispatch on the
    # pair, and the bash case must be bracket-classed for the -case-dispatch gate).
    d="$(fresh_dir)"
    command printf '%s\n' 'run_worker &' >"$d/bg.bash"
    list="$(make_list "$d/l" "$d/bg.bash")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: .bash extension reaches the unreaped-subprocess arm"

    # A backgrounded command whose last token is QUOTED — `curl "$url" &` and
    # its single-quoted twin. This is most real background jobs, and an earlier
    # draft's character class excluded the quote characters, so every one of
    # them was invisible in BOTH runtimes. Parity stayed green throughout: the
    # shared-defect blind spot this repo keeps filing issues about.
    d="$(fresh_dir)"
    command printf '%s\n' 'curl "$url" &' >"$d/dq.sh"
    list="$(make_list "$d/l" "$d/dq.sh")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: bash background job ending in a double-quoted arg fires"

    d="$(fresh_dir)"
    command printf '%s\n' "run_task '5' &" >"$d/sq.sh"
    list="$(make_list "$d/l" "$d/sq.sh")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: bash background job ending in a single-quoted arg fires"

    # An inline env-var prefix, and a compound assignment-then-command one-liner.
    # Both are genuine COMMANDS. The first draft excluded any line that merely
    # STARTED with `NAME=`, which silenced both while still covering the one
    # corpus false positive — a proxy that happened to work on its sample.
    d="$(fresh_dir)"
    command printf '%s\n' 'FOO=bar long_running_task &' >"$d/envpfx.sh"
    list="$(make_list "$d/l" "$d/envpfx.sh")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: bash env-prefixed background job fires (not an assignment)"

    d="$(fresh_dir)"
    command printf '%s\n' 'x=1; long_task &' >"$d/compound.sh"
    list="$(make_list "$d/l" "$d/compound.sh")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: bash assignment-then-command one-liner still fires"

    # --- unreaped-subprocess negatives: the three exclusions ---------------
    # `&&` is a control operator. Written WITHOUT a trailing background job so
    # only the && exclusion can keep it silent.
    d="$(fresh_dir)"
    command printf '%s\n' 'make build && make test' >"$d/andand.sh"
    list="$(make_list "$d/l" "$d/andand.sh")"
    assert_silent "$list" unreaped-subprocess \
        "lifecycle: bash && control operator is not a background job"

    # `>&` fd-dup. `2>&1` ending the line is the shape that would slip past a
    # pattern keying on a bare trailing ampersand.
    d="$(fresh_dir)"
    command printf '%s\n' 'command ls >/dev/null 2>&1' >"$d/fddup.sh"
    list="$(make_list "$d/l" "$d/fddup.sh")"
    assert_silent "$list" unreaped-subprocess \
        "lifecycle: bash >& fd-dup is not a background job"

    # The TRAILING-COMMENT exclusion — the sole corpus false positive
    # (plugins/workflow/hooks/bash-guard.sh:701). Its `&` sits inside a trailing
    # comment, which is_comment() cannot suppress (it is line-START only), so
    # this exclusion is what removes it. Note what the fixture pins: the line is
    # silent because the `&` is COMMENTED, not because the line is an
    # assignment — the four positives above are what keep that distinction
    # honest. Mutating the exclusion away turns this red.
    d="$(fresh_dir)"
    command printf '%s\n' '_tgt="${_tgt#&}"   # `>&2` fd-dup, not a file — strip &' >"$d/assign.sh"
    list="$(make_list "$d/l" "$d/assign.sh")"
    assert_silent "$list" unreaped-subprocess \
        "lifecycle: bash assignment with & in a trailing comment stays silent"

    # A `#` inside a QUOTED ARGUMENT is not a comment, so the exclusion's
    # `[^"']` middle must keep this a finding. Pins the one thing that stops the
    # comment exclusion from being written as the simpler `#.*&$`.
    d="$(fresh_dir)"
    command printf '%s\n' 'run --opt "a # b" &' >"$d/hashinarg.sh"
    list="$(make_list "$d/l" "$d/hashinarg.sh")"
    assert_fires "$list" unreaped-subprocess "Subprocess spawned without visible reap" \
        "lifecycle: bash # inside a quoted arg is not a comment — job still fires"

    # --- terminate-without-kill: all three SIGTERM spellings ---------------
    # One fixture per alternation half. They share an evidence label, so a
    # composite file would keep passing with two of the three mutated away.
    d="$(fresh_dir)"
    command printf '%s\n' 'command kill -TERM "$pid"' >"$d/term.sh"
    list="$(make_list "$d/l" "$d/term.sh")"
    assert_fires "$list" terminate-without-kill "Terminate without kill escalation" \
        "lifecycle: bash kill -TERM fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'command kill -15 "$pid"' >"$d/term15.sh"
    list="$(make_list "$d/l" "$d/term15.sh")"
    assert_fires "$list" terminate-without-kill "Terminate without kill escalation" \
        "lifecycle: bash kill -15 fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'command kill -s TERM "$pid"' >"$d/termS.sh"
    list="$(make_list "$d/l" "$d/termS.sh")"
    assert_fires "$list" terminate-without-kill "Terminate without kill escalation" \
        "lifecycle: bash kill -s TERM fires"

    # A SIGKILL is the escalation, not the thing missing one — flagging it would
    # invert the category the way the Rust arm's comment warns about.
    d="$(fresh_dir)"
    command printf '%s\n%s\n' 'command kill -KILL "$pid"' 'command kill -9 "$pid"' >"$d/kill.sh"
    list="$(make_list "$d/l" "$d/kill.sh")"
    assert_silent "$list" terminate-without-kill \
        "lifecycle: bash kill -KILL/-9 is the escalation, not a candidate"

    # --- the two `—` cells, pinned ----------------------------------------
    # An empty column is otherwise unfalsifiable: without these, deleting the
    # matrix cell and adding an arm would both pass. Same reasoning that pins
    # Swift's empty `debugger` column.
    d="$(fresh_dir)"
    command printf '%s\n%s\n' 'exec 3>"$logfile"' 'exec 4<"$infile"' >"$d/fd.sh"
    list="$(make_list "$d/l" "$d/fd.sh")"
    assert_silent "$list" unclosed-handle \
        "lifecycle: bash unclosed-handle is — (exec N> measures zero in the corpus)"

    d="$(fresh_dir)"
    command printf '%s\n' 'trap cleanup EXIT' >"$d/trap.sh"
    list="$(make_list "$d/l" "$d/trap.sh")"
    assert_silent "$list" unpaired-listener \
        "lifecycle: bash unpaired-listener is — (a trap needs no paired removal)"

    # The issue's second `unclosed-handle` idiom: a temp file with no `trap`.
    # Refused on the OPPOSITE ground from `exec N>` — not absent but far too
    # common to be a signal (48 of 123 corpus mktemp callers declare no trap, and
    # nearly all are correct, most being sourced fragments whose PARENT traps).
    # This file is exactly that shape, and must stay silent.
    d="$(fresh_dir)"
    command printf '%s\n%s\n' 'work="$(mktemp -d)"' 'command cp x "$work/"' >"$d/tmpnotrap.sh"
    list="$(make_list "$d/l" "$d/tmpnotrap.sh")"
    assert_silent "$list" unclosed-handle \
        "lifecycle: bash mktemp without a trap stays silent (— by flood, not absence)"
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
    command printf '%s\n' "$long" >"$d/long.py"
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
run_test test_unpaired_listener "check-lifecycle: JS/Swift/Rust/Python registration arms + Python boundary and single-row negatives"
run_test test_ruled_out_false_positives "check-lifecycle: draining pipe-reader + cleared dict negative fixtures (issue FPs)"
run_test test_test_file_and_skip "check-lifecycle: wholesale test-file skip + segment anchoring + SKIP_GLOBS"
run_test test_test_dir_does_not_skip_source "check-lifecycle: a test_*-named DIRECTORY does not skip the source inside it (#836)"
run_test test_bash_lifecycle_arms "check-lifecycle: bash subprocess/terminate arms, the three exclusions, and the two pinned — cells (#842)"
run_test test_evidence_truncation_parity "check-lifecycle: >80-char multibyte evidence truncation parity (bash==python)"

generate_report
