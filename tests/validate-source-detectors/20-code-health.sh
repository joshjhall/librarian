# shellcheck shell=bash
# check-code-health detector fixtures — area fragment of
# validate-source-detectors (issue #859 split; gate introduced by #348).
#
# Covers tech-debt-marker, the per-language debug-statement arms, empty-handler,
# is_test_file segment anchoring + SKIP_GLOBS, and the #686 stdout-policy family
# (dispatch order, fail-closed on a hanging git, stdout_is_output exemption, and
# match-repo cleanup).
#
# health_rows_in / assert_health_in / stdout_sandbox / STDOUT_LIST live HERE
# rather than in the shared sandbox: no check-security case uses them, and the
# shared library must not accrete single-use code (CLAUDE.md).
#
# Sourced, not executed. SK_HEALTH / REAL_BASH / HAVE_PY come from the entry
# point and the shared sandbox.

test_health_debt() {
    local d list
    d="$(fresh_dir)"
    command printf '%s\n' 'x = 1  # TODO: refactor this' >"$d/a.py"
    list="$(make_list "$d/l" "$d/a.py")"
    assert_fires "$SK_HEALTH" "$list" tech-debt-marker "Tech debt marker" \
        "health: a TODO marker fires"
}

test_health_debug() {
    local d list

    # Python print() fires...
    d="$(fresh_dir)"
    command printf '%s\n' 'print("hi")' >"$d/p.py"
    list="$(make_list "$d/l" "$d/p.py")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debug print statement" \
        "health: Python print() fires"

    # ...but print() that is a logging call is NOT a debug statement (negative).
    d="$(fresh_dir)"
    command printf '%s\n' 'logger.print("structured")' >"$d/log.py"
    list="$(make_list "$d/l" "$d/log.py")"
    assert_silent "$SK_HEALTH" "$list" debug-statement \
        "health: a logger.print() line stays silent (logging negative)"

    # Python debugger statement.
    d="$(fresh_dir)"
    command printf '%s\n' 'breakpoint()' >"$d/bp.py"
    list="$(make_list "$d/l" "$d/bp.py")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debugger statement" \
        "health: Python breakpoint() fires"

    # JS console + debugger.
    d="$(fresh_dir)"
    command printf '%s\n' 'console.log("x");' >"$d/c.js"
    list="$(make_list "$d/l" "$d/c.js")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Console debug statement" \
        "health: JS console.log fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'debugger;' >"$d/d.js"
    list="$(make_list "$d/l" "$d/d.js")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debugger keyword" \
        "health: JS debugger keyword fires"

    # Ruby debugger.
    d="$(fresh_dir)"
    command printf '%s\n' 'binding.pry' >"$d/r.rb"
    list="$(make_list "$d/l" "$d/r.rb")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Ruby debugger" \
        "health: Ruby binding.pry fires"

    # Go debug print.
    d="$(fresh_dir)"
    command printf '%s\n' 'fmt.Println("x")' >"$d/g.go"
    list="$(make_list "$d/l" "$d/g.go")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debug print statement" \
        "health: Go fmt.Println fires"

    # Java debug print.
    d="$(fresh_dir)"
    command printf '%s\n' 'System.out.println("x");' >"$d/J.java"
    list="$(make_list "$d/l" "$d/J.java")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debug print statement" \
        "health: Java System.out.println fires"

    # Rust print macros (#838) — the stdout family, so `stdout_is_output` can
    # exempt them. Both spellings asserted independently: the arm is one regex
    # with an optional `e` prefix and an optional `ln` suffix, so a composite
    # fixture would stay green with either half broken.
    d="$(fresh_dir)"
    command printf '%s\n' 'println!("x");' >"$d/p.rs"
    list="$(make_list "$d/l" "$d/p.rs")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debug print statement" \
        "health: Rust println! fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'eprintln!("x");' >"$d/ep.rs"
    list="$(make_list "$d/l" "$d/ep.rs")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debug print statement" \
        "health: Rust eprintln! fires"

    # Rust dbg! — the DEBUGGER family, never exempted (#680 AC3). Its distinct
    # label is what pins that it landed in the right family: a dbg! misfiled
    # under the print family would still emit a debug-statement row, so only the
    # label distinguishes the two.
    d="$(fresh_dir)"
    command printf '%s\n' 'dbg!(value);' >"$d/dg.rs"
    list="$(make_list "$d/l" "$d/dg.rs")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Rust debug macro" \
        "health: Rust dbg! fires in the debugger family"

    # Swift print family (#839). Both spellings asserted independently — one
    # regex with an alternation, so a composite fixture stays green with either
    # half broken.
    d="$(fresh_dir)"
    command printf '%s\n' 'print("x")' >"$d/p.swift"
    list="$(make_list "$d/l" "$d/p.swift")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debug print statement" \
        "health: Swift print() fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'debugPrint(x)' >"$d/dp.swift"
    list="$(make_list "$d/l" "$d/dp.swift")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debug print statement" \
        "health: Swift debugPrint() fires"

    # BOUNDARY: Swift has NO debugger arm and that `—` cell is deliberate (a
    # breakpoint is an lldb/Xcode action, not a source token). Asserting the
    # ABSENCE needs a line that would fire if someone added a careless arm —
    # `breakpoint()` is a real Swift stdlib call AND the exact literal the
    # PYTHON debugger arm matches, so this pins that .swift does not leak into
    # it. Without a fixture the empty column is unfalsifiable.
    d="$(fresh_dir)"
    command printf '%s\n' 'breakpoint()' >"$d/bp.swift"
    list="$(make_list "$d/l" "$d/bp.swift")"
    assert_silent "$SK_HEALTH" "$list" debug-statement \
        "health: Swift breakpoint() does NOT fire (no debugger arm; py arm must not leak)"

    # BOUNDARY: a debug print inside a TEST file is suppressed (not test_file only
    # applies debug scanning to non-test files).
    d="$(fresh_dir)"
    command printf '%s\n' 'print("hi")' >"$d/test_mod.py"
    list="$(make_list "$d/l" "$d/test_mod.py")"
    assert_silent "$SK_HEALTH" "$list" debug-statement \
        "health: a print() inside a test file is suppressed (is_test_file boundary)"
}

test_health_empty_handler() {
    local d list

    # Python empty except (pass).
    d="$(fresh_dir)"
    command printf '%s\n' 'try:' '    risky()' 'except Exception:' '    pass' >"$d/e.py"
    list="$(make_list "$d/l" "$d/e.py")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Empty except block" \
        "health: Python empty except (pass) fires"

    # ...but an except with a real body stays silent.
    d="$(fresh_dir)"
    command printf '%s\n' 'try:' '    risky()' 'except Exception:' '    log(e)' >"$d/ok.py"
    list="$(make_list "$d/l" "$d/ok.py")"
    assert_silent "$SK_HEALTH" "$list" empty-handler \
        "health: a handled except stays silent"

    # JS empty catch.
    d="$(fresh_dir)"
    command printf '%s\n' 'try { risky(); } catch (e) {}' >"$d/c.js"
    list="$(make_list "$d/l" "$d/c.js")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Empty catch block" \
        "health: JS empty catch fires"

    # Ruby empty rescue.
    d="$(fresh_dir)"
    command printf '%s\n' 'begin' '  risky' 'rescue' 'end' >"$d/r.rb"
    list="$(make_list "$d/l" "$d/r.rb")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Empty rescue block" \
        "health: Ruby empty rescue fires"

    # Go swallowed error.
    d="$(fresh_dir)"
    command printf '%s\n' 'if err != nil {}' >"$d/g.go"
    list="$(make_list "$d/l" "$d/g.go")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Swallowed error" \
        "health: Go swallowed error fires"

    # Rust empty Err arm (#838), both body spellings asserted independently —
    # one regex with an alternation, so a composite fixture would stay green
    # with either half broken.
    d="$(fresh_dir)"
    command printf '%s\n' 'match r { Err(_) => {}, Ok(v) => use_it(v) }' >"$d/m.rs"
    list="$(make_list "$d/l" "$d/m.rs")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Empty Err match arm" \
        "health: Rust empty Err(_) => {} match arm fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'match r { Err(_) => (), Ok(v) => use_it(v) }' >"$d/u.rs"
    list="$(make_list "$d/l" "$d/u.rs")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Empty Err match arm" \
        "health: Rust empty Err(_) => () match arm fires"

    # BOUNDARY: a HANDLED Err arm stays silent.
    d="$(fresh_dir)"
    command printf '%s\n' 'match r { Err(e) => log(e), Ok(v) => use_it(v) }' >"$d/h.rs"
    list="$(make_list "$d/l" "$d/h.rs")"
    assert_silent "$SK_HEALTH" "$list" empty-handler \
        "health: Rust handled Err arm stays silent"

    # BOUNDARY: `let _ = fallible();` is NOT implemented (see the note in
    # patterns.py) — it is a deliberate idiom far more often than a swallow, and
    # this scanner has no certainty tier low enough to carry it. Pinned so that
    # adding it later is a conscious decision with this fixture to update, not an
    # accident.
    d="$(fresh_dir)"
    command printf '%s\n' 'let _ = write!(buf, "{}", x);' >"$d/k.rs"
    list="$(make_list "$d/l" "$d/k.rs")"
    assert_silent "$SK_HEALTH" "$list" empty-handler \
        "health: Rust let _ = discard is deliberately not flagged at HIGH"

    # Swift empty catch (#839) — the motivating false negative of #622. Swift's
    # `catch` takes NO parenthesized parameter, so the JS/Java arm above
    # (`catch\s*\([^)]*\)\s*\{\s*\}`) can NEVER match it; before this arm a
    # Swift `catch { }` emitted zero rows. Each of the three catch spellings is
    # asserted independently: they are one regex with an optional middle group,
    # so a composite fixture would stay green with the group broken.
    d="$(fresh_dir)"
    command printf '%s\n' 'do { try risky() } catch { }' >"$d/c.swift"
    list="$(make_list "$d/l" "$d/c.swift")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Empty catch block" \
        "health: Swift bare empty catch fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'do { try risky() } catch let e { }' >"$d/b.swift"
    list="$(make_list "$d/l" "$d/b.swift")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Empty catch block" \
        "health: Swift bound empty catch (catch let e) fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'do { try risky() } catch is FooError { }' >"$d/p.swift"
    list="$(make_list "$d/l" "$d/p.swift")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Empty catch block" \
        "health: Swift typed empty catch (catch is FooError) fires"

    # BOUNDARY: a Swift catch with a real body stays silent. This is what the
    # `[^{}]*` brace exclusion buys — without it the match runs past the
    # handler's opening brace and finds a later `{}` on the same line.
    d="$(fresh_dir)"
    command printf '%s\n' 'do { try risky() } catch { handle(error) }' >"$d/h.swift"
    list="$(make_list "$d/l" "$d/h.swift")"
    assert_silent "$SK_HEALTH" "$list" empty-handler \
        "health: Swift handled catch stays silent"

    # BOUNDARY: the same line plus a trailing empty closure. The handler is
    # non-empty, so this must STAY SILENT — it is the specific input that fires
    # if the brace exclusion is ever widened to `.*`, and neither fixture above
    # would notice that change.
    d="$(fresh_dir)"
    command printf '%s\n' 'do { try risky() } catch { handle() }; let noop = { }' >"$d/w.swift"
    list="$(make_list "$d/l" "$d/w.swift")"
    assert_silent "$SK_HEALTH" "$list" empty-handler \
        "health: Swift handled catch + later empty closure stays silent"

    # BOUNDARY: WORD BOUNDARY, BOTH SIDES. The python arm spells this
    # `\bcatch\b`; `\b` is a GNU extension BSD grep reads as a LITERAL, so the
    # bash arm must write both boundaries long-hand. Each side is asserted
    # separately because each was a real, separately-measured py/sh divergence —
    # and the leading-side fixture alone did NOT catch the trailing-side bug.
    #
    # An identifier ENDING in "catch" (leading boundary):
    d="$(fresh_dir)"
    command printf '%s\n' 'mycatch { }' >"$d/n.swift"
    list="$(make_list "$d/l" "$d/n.swift")"
    assert_silent "$SK_HEALTH" "$list" empty-handler \
        "health: Swift identifier ending in 'catch' is not a catch (leading boundary)"

    # An identifier STARTING with "catch" (trailing boundary). This direction
    # shipped UNTESTED behind the fixture above and was a live parity break:
    # bash fired on all three of these, python on none. Three spellings, since
    # the missing guard was on the character class rather than on any one name.
    d="$(fresh_dir)"
    command printf '%s\n' 'catches { }' >"$d/s.swift"
    list="$(make_list "$d/l" "$d/s.swift")"
    assert_silent "$SK_HEALTH" "$list" empty-handler \
        "health: Swift 'catches { }' is not a catch (trailing boundary)"

    d="$(fresh_dir)"
    command printf '%s\n' 'catcher { }' >"$d/r.swift"
    list="$(make_list "$d/l" "$d/r.swift")"
    assert_silent "$SK_HEALTH" "$list" empty-handler \
        "health: Swift 'catcher { }' is not a catch (trailing boundary)"

    d="$(fresh_dir)"
    command printf '%s\n' 'catchAllErrors { }' >"$d/a.swift"
    list="$(make_list "$d/l" "$d/a.swift")"
    assert_silent "$SK_HEALTH" "$list" empty-handler \
        "health: Swift 'catchAllErrors { }' is not a catch (trailing boundary)"

    # ...but the brace-adjacent form IS a catch and must still fire. This is the
    # case that fails if the trailing boundary is written as a CONSUMING
    # character class (ERE has no lookahead): the only thing following `catch`
    # here is the brace itself, so consuming it leaves nothing for `\{` to match
    # and the line goes silent in bash while python still fires. Found by
    # re-measuring after the first boundary fix rather than assuming it complete.
    d="$(fresh_dir)"
    command printf '%s\n' 'do { try risky() } catch{ }' >"$d/adj.swift"
    list="$(make_list "$d/l" "$d/adj.swift")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Empty catch block" \
        "health: Swift brace-adjacent 'catch{ }' still fires (boundary must not consume)"

    d="$(fresh_dir)"
    command printf '%s\n' 'do { try risky() } catch {}' >"$d/e2.swift"
    list="$(make_list "$d/l" "$d/e2.swift")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Empty catch block" \
        "health: Swift 'catch {}' (no inner space) fires"
}

test_health_test_file_and_skip() {
    local d list

    # is_test_file segment anchoring: tests/helper.py IS a test → debug suppressed.
    d="$(fresh_dir)"
    command mkdir -p "$d/tests"
    command printf '%s\n' 'print("dbg")' >"$d/tests/helper.py"
    list="$(make_list "$d/l" "$d/tests/helper.py")"
    assert_silent "$SK_HEALTH" "$list" debug-statement \
        "health: print() under a tests/ segment is suppressed"

    # ...but contest.py is NOT a test file (segment-anchored, not substring) → fires.
    d="$(fresh_dir)"
    command printf '%s\n' 'print("dbg")' >"$d/contest.py"
    list="$(make_list "$d/l" "$d/contest.py")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debug print statement" \
        "health: contest.py is NOT a test file (segment anchoring negative)"

    # test_*.py basename arm → test file.
    d="$(fresh_dir)"
    command printf '%s\n' 'print("dbg")' >"$d/test_widget.py"
    list="$(make_list "$d/l" "$d/test_widget.py")"
    assert_silent "$SK_HEALTH" "$list" debug-statement \
        "health: test_widget.py basename is a test file"

    # SKIP_GLOBS: a *.md carrying a TODO is skipped wholesale.
    d="$(fresh_dir)"
    command printf '%s\n' '# TODO: doc marker' >"$d/notes.md"
    list="$(make_list "$d/l" "$d/notes.md")"
    assert_silent "$SK_HEALTH" "$list" tech-debt-marker \
        "health: a TODO inside a *.md is skipped (SKIP_GLOBS)"
}

# ============================================================================
# check-code-health — declared `stdout_is_output` (#686)
# ============================================================================
#
# The declaration is read from `<repo-root>/.claude/pre-review.yml`, and the
# scanner finds that root with `git rev-parse --show-toplevel` at runtime. So
# these fixtures need a real git sandbox AND the scanner has to run FROM INSIDE
# it — the shared emit_rows driver does not cd, which would make every case here
# resolve THIS repo's config instead of the fixture's. Hence the local drivers.

# health_rows_in DIR IMPL LIST CAT — like emit_rows, but cd'd into DIR first.
# `command env`, not a hardcoded /usr/bin/env: CLAUDE.md bans absolute paths to
# core utilities (#443). The sibling emit_rows above predates that rule and still
# hardcodes one; new code should not add instances.
health_rows_in() {
    local dir="$1" impl="$2" list="$3" cat="$4"
    if [ "$impl" = py ]; then
        (cd "$dir" && command env python3 "$SK_HEALTH/patterns.py" "$list" 2>/dev/null)
    else
        (cd "$dir" && command env PATTERNS_FORCE_BASH=1 "$REAL_BASH" \
            "$SK_HEALTH/patterns.sh" "$list" 2>/dev/null)
    fi | command awk -F '\t' -v c="$cat" '$3 == c'
}

# assert_health_in DIR LIST CAT MODE NEEDLE MSG — assert in BOTH impls, from
# inside DIR. MODE is "fires" (rows contain NEEDLE) or "absent" (they do not).
# Both impls are checked because python is the PRIMARY runtime and bash the
# fallback: a fix landing in only one is the exact defect this pair invites.
assert_health_in() {
    local dir="$1" list="$2" cat="$3" mode="$4" needle="$5" msg="$6"
    local out
    out="$(health_rows_in "$dir" sh "$list" "$cat")"
    if [ "$mode" = fires ]; then
        assert_contains "$out" "$needle" "$msg (bash)"
    else
        assert_not_contains "$out" "$needle" "$msg (bash)"
    fi
    if [ "$HAVE_PY" -eq 1 ]; then
        out="$(health_rows_in "$dir" py "$list" "$cat")"
        if [ "$mode" = fires ]; then
            assert_contains "$out" "$needle" "$msg (python)"
        else
            assert_not_contains "$out" "$needle" "$msg (python)"
        fi
    fi
}

# stdout_sandbox VARNAME [CONFIG_LINE...] — a git sandbox holding a declared CLI
# file (cli.py: a print AND a breakpoint) plus an undeclared control
# (other.py: a print). Writes .claude/pre-review.yml only when CONFIG_LINEs are
# given, so the no-config case is the same fixture minus the declaration.
STDOUT_LIST=""
stdout_sandbox() {
    local __out="$1" dir=""
    shift
    dir="$(fresh_dir)"
    command git init -q "$dir" 2>/dev/null
    command mkdir -p "$dir/src"
    # cli.py carries BOTH families on purpose: the exemption must reach the
    # print and NOT the breakpoint, and one file proves both halves at once.
    command printf '%s\n' 'print("real output")' 'breakpoint()' >"$dir/src/cli.py"
    command printf '%s\n' 'print("debug leftover")' >"$dir/src/other.py"
    if [ "$#" -gt 0 ]; then
        command mkdir -p "$dir/.claude"
        command printf '%s\n' "$@" >"$dir/.claude/pre-review.yml"
    fi
    STDOUT_LIST="$(make_list "$dir/l" "$dir/src/cli.py" "$dir/src/other.py")"
    printf -v "$__out" '%s' "$dir"
}

# The bash dispatcher's SHAPE, mirroring the Python source-order assertion in
# validate-python-ports.sh (#687). Both are source-level for the same reason:
# every pattern in both families is `^\s*`-anchored, so no single line can match
# both, and no input exists for which the call order changes the emitted bytes.
# Behaviour cannot witness the order — only the source can.
#
# It also pins the exemption's SHAPE, which behaviour alone leaves ambiguous:
# the two calls must be SEPARATE statements. Written as one `if`, a declaration
# would suppress the debugger row too; written this way, no such control path
# exists. That is #680 AC3 enforced structurally rather than asserted in prose.
test_health_dispatch_order_and_shape() {
    local block
    # The dispatch block: from the debug-statement marker to the end of its `if`.
    block="$(command awk '/--- Category: debug-statement ---/,/^    fi$/' \
        "$SK_HEALTH/patterns.sh")"

    assert_not_empty "$block" "the bash debug-statement dispatch block was found"

    local print_ln dbg_ln
    print_ln="$(command printf '%s\n' "$block" | command grep -n 'scan_debug_prints "\$file"' | command head -1 | command cut -d: -f1)"
    dbg_ln="$(command printf '%s\n' "$block" | command grep -n 'scan_debugger_statements "\$file"' | command head -1 | command cut -d: -f1)"

    assert_not_empty "$print_ln" "the dispatcher calls scan_debug_prints"
    assert_not_empty "$dbg_ln" "the dispatcher calls scan_debugger_statements"
    assert_true "[ \"${print_ln:-0}\" -lt \"${dbg_ln:-0}\" ]" \
        "bash dispatch order is print-then-debugger, matching patterns.py (#686)"

    # The print call is guarded by the predicate; the debugger call is NOT.
    assert_contains "$block" 'matches_declared_stdout_pattern "$file" || scan_debug_prints "$file"' \
        "the print call is gated by the stdout declaration (#686)"
    assert_not_contains "$block" 'matches_declared_stdout_pattern "$file" || scan_debugger_statements' \
        "the debugger call is NOT gated by the declaration (#680 AC3)"
}

# The FAIL-CLOSED contract, forced (#686).
#
# patterns.py bounds each git call and treats a timeout like an OSError. Every
# other fixture here runs against a real, fast git, so the except-branch never
# executes — and "fails closed" was only a claim in a comment. This forces it
# with a stub `git` that sleeps well past _GIT_TIMEOUT_S.
#
# Three things must hold, and they are different failures:
#   - the scan COMPLETES (a hang would take the whole audit down),
#   - the declared file's print STILL fires — a call that could not answer must
#     not grant an exemption, or a broken git silently deletes findings,
#   - nothing is left in TMPDIR, covering the early-cleanup branch that runs
#     when git fails BEFORE atexit is registered.
#
# Python only: the bash twin deliberately has no bound (see its comment — the
# portable helper lives in another plugin), so there is no contract to test.
test_health_stdout_git_failure_fails_closed() {
    local d="" stub="" scratch="" out="" rc=0

    if [ "$HAVE_PY" -ne 1 ]; then
        skip_test "python3 unavailable (the bash fallback has no timeout to test)"
        return 0
    fi
    if ! command -v timeout >/dev/null 2>&1; then
        skip_test "timeout(1) unavailable to bound the TEST itself"
        return 0
    fi

    stdout_sandbox d "stdout_is_output:" "  - src/cli.py"

    # A git that never returns. PREPENDED to PATH so python3 itself still
    # resolves — replacing PATH outright would break the interpreter, not the
    # git call, and the case would pass for the wrong reason.
    stub="$(fresh_dir)"
    command printf '%s\n' '#!/usr/bin/env bash' 'sleep 60' >"$stub/git"
    command chmod +x "$stub/git"

    scratch="$(fresh_dir)"
    # Outer bound well above _GIT_TIMEOUT_S (5s) but far below the stub's 60s:
    # exit 124 here means the scanner did NOT honor its own timeout.
    # `timeout env ...`, not `timeout command env ...`: `command` is a shell
    # builtin, so timeout(1) would try to exec a binary named "command" and fail
    # before reaching python — the scan would emit nothing and the fail-closed
    # assertion would fail while the code was correct (which is what happened
    # writing this).
    out="$(cd "$d" && command timeout 30 env \
        PATH="$stub:$PATH" TMPDIR="$scratch" \
        python3 "$SK_HEALTH/patterns.py" "$STDOUT_LIST" 2>/dev/null)" || rc=$?

    assert_true "[ \"$rc\" -ne 124 ]" \
        "health: a hanging git does not wedge the scan — the timeout fires (#686)"
    assert_contains "$out" 'print("real output")' \
        "health: a git that cannot answer does NOT grant an exemption — fails CLOSED (#686)"
    assert_equals "" "$(command ls -A "$scratch" 2>/dev/null)" \
        "health: the early-failure path leaves no temp dir behind (#686)"

    # The case above hangs git for the WHOLE run, so _load_stdout_policy never
    # builds a match repo and the predicate returns at its empty-repo guard —
    # the timeout branch inside _matches_declared_stdout is never reached. That
    # makes the assertion above pass even with the branch flipped to fail OPEN
    # (verified by mutation), so it does not cover what its name suggests.
    #
    # This second stub lets the LOADER succeed and hangs only afterwards, by
    # counting invocations: rev-parse and init run for real, then check-ignore —
    # the third call, and the one made per file — hangs. Now the branch under
    # test is genuinely the one executing.
    local stub2="" scratch2="" out2="" rc2=0
    stub2="$(fresh_dir)"
    {
        command printf '%s\n' '#!/usr/bin/env bash'
        command printf '%s\n' 'n="$(cat "$COUNTER" 2>/dev/null || echo 0)"'
        command printf '%s\n' 'echo $((n + 1)) >"$COUNTER"'
        # Hang from the third call on — rev-parse and init are calls 1 and 2.
        command printf '%s\n' 'if [ "$n" -ge 2 ]; then sleep 60; fi'
        command printf '%s\n' 'exec "$REAL_GIT" "$@"'
    } >"$stub2/git"
    command chmod +x "$stub2/git"

    scratch2="$(fresh_dir)"
    out2="$(cd "$d" && command timeout 30 env \
        PATH="$stub2:$PATH" TMPDIR="$scratch2" \
        COUNTER="$stub2/n" REAL_GIT="$(command -v git)" \
        python3 "$SK_HEALTH/patterns.py" "$STDOUT_LIST" 2>/dev/null)" || rc2=$?

    assert_true "[ \"$rc2\" -ne 124 ]" \
        "health: a check-ignore that hangs does not wedge the scan (#686)"
    assert_contains "$out2" 'print("real output")' \
        "health: a TIMED-OUT check-ignore does not grant an exemption (#686)"
}

test_health_stdout_is_output() {
    local d=""

    # --- declared: the print is exempt ---
    # The needle is the print's EVIDENCE TEXT, not the filename: cli.py still
    # appears in this run via its breakpoint row (the next assertion), so
    # "cli.py is absent" could never hold and would fail whatever the code did.
    stdout_sandbox d "stdout_is_output:" "  - src/cli.py"
    assert_health_in "$d" "$STDOUT_LIST" debug-statement absent 'print("real output")' \
        "health: a declared file's print() is exempt (#686)"

    # --- AC3: the SAME declared file's breakpoint still fires ---
    # This is the boundary #680 AC3 asks for, and the reason the dispatcher uses
    # two statements rather than an if/else. Without this case, widening the
    # exemption to cover the debugger family would pass every other assertion.
    assert_health_in "$d" "$STDOUT_LIST" debug-statement fires "Debugger statement" \
        "health: a declared file's breakpoint() STILL fires (#680 AC3)"

    # --- control: an undeclared sibling in the same run is untouched ---
    # Proves the exemption is per-file, not a global off-switch. Keyed on the
    # control's own print evidence for the same reason as above.
    assert_health_in "$d" "$STDOUT_LIST" debug-statement fires 'print("debug leftover")' \
        "health: an UNDECLARED file's print() still fires (#686)"

    # --- no config at all: pre-#686 behaviour, exactly ---
    # The common path. If the predicate ever defaulted true, every repo without
    # a config would silently lose its print findings — so this is the case that
    # would catch it.
    local noconf=""
    stdout_sandbox noconf
    assert_health_in "$noconf" "$STDOUT_LIST" debug-statement fires 'print("real output")' \
        "health: with NO .claude/pre-review.yml, print() fires as before (#686)"

    # --- config present but key absent ---
    # A repo declaring some OTHER key must not accidentally enable the
    # exemption: the loader reads the file but finds no patterns.
    local otherkey=""
    stdout_sandbox otherkey "test_skip_patterns:" "  - vendor/**"
    assert_health_in "$otherkey" "$STDOUT_LIST" debug-statement fires 'print("real output")' \
        "health: a config without stdout_is_output leaves print() firing (#686)"

    # --- a GLOB, not just a literal path ---
    # SKILL.md documents these values as gitignore-style patterns and gives
    # `bin/*.js` as the worked example, but every case above declares an exact
    # path. Matching is delegated to `git check-ignore`, so a glob should work —
    # "should" being the point: a documented example nothing exercises is how
    # docs drift from behaviour.
    #
    # `src/*.py` matches BOTH fixture files, so this also shows the exemption
    # applying to a file never named literally.
    local globbed=""
    stdout_sandbox globbed "stdout_is_output:" "  - src/*.py"
    assert_health_in "$globbed" "$STDOUT_LIST" debug-statement absent 'print("real output")' \
        "health: a glob pattern exempts the file it matches (#686)"
    assert_health_in "$globbed" "$STDOUT_LIST" debug-statement absent 'print("debug leftover")' \
        "health: a glob exempts a file never named literally (#686)"
    # ...and the AC3 boundary holds under a glob too, not just a literal.
    assert_health_in "$globbed" "$STDOUT_LIST" debug-statement fires "Debugger statement" \
        "health: a glob-declared file's breakpoint() STILL fires (#680 AC3)"
}

# The temp match-repo must not leak. #680 added a repo to the reference impl
# without a cleanup branch and leaked one per run; the failure is silent (a
# stray /tmp dir, no error, no wrong output), so it needs a behavioural check
# rather than a code read.
#
# Each impl runs with TMPDIR pointed at a PRIVATE, EMPTY scratch dir, and the
# assertion is that the dir is empty afterwards. Two reasons that beats counting
# /tmp:
#
#   1. It is naming-agnostic. `mktemp -d` produces `tmp.XXXX` but Python's
#      `tempfile.mkdtemp()` produces `tmpXXXX` with NO dot, so a `tmp.*` glob
#      silently misses every Python leak — and Python is the PRIMARY runtime, so
#      the check would have covered only the fallback while claiming both.
#   2. Nothing else writes there, so a busy /tmp on the host cannot make it flap.
#
# Asserted per-impl rather than once at the end: a shared counter cannot say
# WHICH runtime leaked, and "one of the two leaked" is the report you least want
# at 2am.
test_health_stdout_repo_cleaned_up() {
    local d="" scratch=""

    stdout_sandbox d "stdout_is_output:" "  - src/cli.py"

    scratch="$(fresh_dir)"
    TMPDIR="$scratch" health_rows_in "$d" sh "$STDOUT_LIST" debug-statement >/dev/null
    assert_equals "" "$(command ls -A "$scratch" 2>/dev/null)" \
        "health: the bash impl leaves no temp match-repo behind (#686)"

    if [ "$HAVE_PY" -eq 1 ]; then
        scratch="$(fresh_dir)"
        TMPDIR="$scratch" health_rows_in "$d" py "$STDOUT_LIST" debug-statement >/dev/null
        assert_equals "" "$(command ls -A "$scratch" 2>/dev/null)" \
            "health: the python impl leaves no temp match-repo behind (#686)"
    fi
}
