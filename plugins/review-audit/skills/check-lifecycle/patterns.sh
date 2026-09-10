#!/usr/bin/env bash
# check-lifecycle — Deterministic Pre-Scan
#
# Detects resource-lifecycle CANDIDATES catchable by a single-line regex:
# subprocess spawn sites, SIGTERM/terminate sites, unscoped handle acquisitions,
# and listener/timer registrations. Each is suspicious on one line but the paired
# release may live elsewhere in the scope, so every row is certainty MEDIUM — a
# candidate the LLM pass-2 confirms/dismisses, never an auto-fix. The
# judgment-heavy categories (unjoined-worker, unbounded-growth) are LLM-only.
#
# Input:  $1 = file containing paths to scan (one per line)
# Output: TSV to stdout: file\tline\tcategory\tevidence\tcertainty
#
# Exit codes:
#   0 = success (zero or more findings)
#   1 = usage error (missing argument)
#
# Note: Uses full paths for commands per project shell-scripting conventions.
#
# Runtime: Python 3.11+ primary (patterns.py) with this bash script as the
# portable fallback. The shim below exec's patterns.py when a python3>=3.11 is
# present (identical TSV contract); PATTERNS_FORCE_BASH=1 forces this bash body.
# The is_test_file() block mirrors the segment-anchored check-code-health /
# ship-issue copies for classification uniformity, but is NOT wired into the
# validate-shared-scanner-sync.sh drift gate (that gate covers only the
# check-code-health <-> ship-issue pair); this copy stands alone, and #836
# recorded the decision to keep it that way — see the rationale above
# is_test_file() below. Standing alone is why its anchoring drifted unnoticed,
# so the behavioral gate tests/validate-lifecycle-detectors.sh pins it instead.
# See CLAUDE.md § Key conventions.
set -euo pipefail

# --- runtime selection: prefer python3>=3.11, else this bash fallback --------
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${PATTERNS_FORCE_BASH:-0}" != "1" ] && [ -f "$_here/patterns.py" ] &&
    command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    exec python3 "$_here/patterns.py" "$@"
fi

FILE_LIST="${1:?Usage: patterns.sh <file-list>}"

if [ ! -f "$FILE_LIST" ]; then
    echo "Error: file list not found: $FILE_LIST" >&2
    exit 1
fi

# --- input-shape guard (#816) -----------------------------------------------
# The file-list argument is a list of PATHS, one per line -- not a diff. Handed
# a diff, the scan loop reads each diff line as a path, matches nothing, emits
# nothing, and exits 0: an output indistinguishable from a genuinely clean scan.
# That is the #538/#571 failure (a gate that sits inert and reads as a pass)
# reached through the INPUT rather than the runtime, and it is easy to hit --
# both inputs come from adjacent `git diff` invocations differing only by
# `--name-only`, and both are plausibly named `*.diff`.
#
# Two checks, deliberately different in severity:
#
#   DIFF SHAPE -> hard failure (exit 1). Unambiguous: no file list contains a
#     `diff --git`/`@@`/`+++`/`--- ` line, so there is no legitimate input this
#     rejects, and the silent-zero scan is exactly what the caller must not get.
#
#   NOTHING RESOLVES -> stderr warning, exit code UNCHANGED. This one cannot be
#     an error: a list naming only deleted files is legitimate (the paths are
#     gone by design), and an EMPTY list exiting 0 in silence is a contract
#     tests/validate-prescans.sh pins for every pre-scan. So it is a warning
#     that catches stale lists and wrong-cwd invocations without breaking either
#     real case -- which is why it is guarded on a NON-EMPTY list.
#
# BASH_SOURCE[0], not $0: inside a function it names the file this function was
# DEFINED in, so the message stays correct under a symlink, a relative
# invocation from another cwd, or a `source` -- the same reasoning the SCRIPT_DIR
# computation elsewhere in these scanners uses.
# The multi-byte Unicode format characters the reflected line must not carry:
# the zero-width family (U+200B-200F), bidi overrides/embeddings (U+202A-202E),
# bidi isolates (U+2066-2069) and BOM (U+FEFF). A bidi override is the dangerous
# one: it makes the reflected text RENDER reversed, so a hostile path can display
# as something other than what it is.
#
# Built with printf as LITERAL UTF-8 bytes, not written as \xNN escapes -- those
# are a GNU sed extension that BSD sed reads as literal text, which is the silent
# #679 failure class (the pattern stops matching and nothing reports it).
# An ALTERNATION, not a bracket class: a bracket over multi-byte sequences
# matches byte-wise and can split a character.
#
# This is what keeps the bash fallback in step with _strip_control() in the
# python primary, whose isprintable() rejects category Cf for free. Without it
# the two runtimes diverge on exactly the path the fallback exists to serve
# (measured: RTLO survived in bash, was stripped in python).
_PRESCAN_BIDI_BYTES="$(command printf '\342\200\213|\342\200\214|\342\200\215|\342\200\216|\342\200\217|')"
_PRESCAN_BIDI_BYTES="${_PRESCAN_BIDI_BYTES}$(command printf '\342\200\252|\342\200\253|\342\200\254|\342\200\255|\342\200\256|')"
_PRESCAN_BIDI_BYTES="${_PRESCAN_BIDI_BYTES}$(command printf '\342\201\246|\342\201\247|\342\201\250|\342\201\251|\357\273\277')"

# emit_rows_word PATTERN CATEGORY LABEL FILE PAREN_RE -- like emit_rows, but the
# leading word boundary comes from POSIX `grep -w` instead of a bracket class,
# and PAREN_RE re-imposes the "must be a call" requirement that -w drops.
#
# WHY NOT A BRACKET CLASS (#841, found by CI on macos-latest). The Python
# listener arm needs a leading boundary that behaves like python's `\w`, which
# is Unicode-aware regardless of the OS locale. Two spellings were tried and
# both failed, in different ways:
#
#   `[^[:alnum:]_]`            -- portable, but under a strict `C` locale grep
#                                 classifies each BYTE alone, so the trailing
#                                 byte of a multibyte letter satisfies the
#                                 negated class and the arm FIRES where python
#                                 stays silent.
#   `[^[:alnum:]_\200-\377]`   -- fixed that on GNU grep, and BSD grep REJECTS
#                                 the pattern outright (exit >1): raw \200-\377
#                                 is not a valid range under its collation. It
#                                 passed every local check because this box has
#                                 GNU grep; tests/probe-bsd-regex.sh caught it
#                                 on the only macos-latest job.
#
# `-w` is a FLAG, not a regex construct, so it sidesteps the dialect question
# entirely -- the same reasoning probe-bsd-regex.sh already records for the
# `\b` sites. It is POSIX and probe-verified SUPPORTED on BSD.
#
# KNOWN LIMITATION -- the boundary is correct under a UTF-8 locale, NOT under a
# strict `C` locale. Say it plainly rather than calling the boundary "correct":
# under `LC_ALL=C`, `-w` decides word-ness bytewise, so a line whose call is
# prefixed by a non-ASCII IDENTIFIER character emits a false positive here while
# the python twin stays silent. The concrete case, and it is real code rather
# than prose: an identifier such as caf<e-acute>add_reader (PEP 3131 permits
# non-ASCII identifiers, so this COMPILES) followed by `(` fires in bash under
# `LC_ALL=C` only. Under any UTF-8 locale -- including C.UTF-8, the default on
# the containers and CI runners this scanner targets -- the two runtimes agree
# exactly, on this shape and on multibyte PUNCTUATION alike. The UTF-8 behaviour
# is fixture-pinned in tests/validate-lifecycle-detectors.sh so a future locale
# change surfaces there instead of silently widening the gap.
emit_rows_word() {
    command grep -nEw -- "$1" "$4" 2>/dev/null |
        command grep -E -- "$5" |
        while IFS= read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$4" "$line_num" "$2" "$3: ${evidence}" "MEDIUM"
        done || true
}

# emit_rows_unless PATTERN CATEGORY LABEL FILE EXCLUDE — as emit_rows, but drops
# any matching line that ALSO matches EXCLUDE. The mirror of emit_rows_word's
# extra-filter shape (#841), inverted; added for the Bash unreaped-subprocess arm
# (#842), whose correctness depends on an exclusion the match pattern cannot
# express (see the *.[Ss][Hh] arm for which exclusions and why).
#
# `grep -v` is the second stage rather than a negative lookahead because ERE has
# none. Note the -v grep is NOT `-q`: a `-q` here would exit on its first match
# and SIGPIPE the upstream writer, which under this file's `set -o pipefail`
# reports 141 and inverts the result (the lesson recorded at :210).
#
# EXCLUDE is matched against the `-n` OUTPUT, so it sees a `NNN:` line-number
# prefix that the python twin's per-line regex does not. A caller anchoring with
# `^` must therefore spell that prefix — the arms below use `^[0-9]+:` — or the
# anchor binds to the digits and the exclusion silently never fires. Measured:
# omitting it let the one corpus false positive through on the bash runtime
# ONLY, which is precisely the asymmetric divergence validate-python-ports.sh
# exists to catch.
emit_rows_unless() {
    command grep -nE -- "$1" "$4" 2>/dev/null |
        command grep -vE -- "$5" |
        while IFS= read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$4" "$line_num" "$2" "$3: ${evidence}" "MEDIUM"
        done || true
}

assert_file_list_shape() {
    local list="$1"
    local tool="${BASH_SOURCE[0]##*/}"
    local line total=0 resolved=0

    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        total=$((total + 1))
        case "$line" in
            'diff --git '* | '--- '* | '+++ '* | '@@ '*)
                # STRIP CONTROL BYTES before echoing the line back. The input is
                # caller-supplied and may come from an untrusted diff; raw ESC/BEL
                # reaching the operator's terminal can move the cursor, hide
                # following output, or drive an OSC title-bar sequence. Keep tab
                # (\011) so indentation still reads. Measured: without this, a
                # crafted `diff --git \033[31m...\033]0;X\007` line renders as
                # live escapes rather than text.
                # Two passes, because one tool cannot do both portably.
                # (1) tr strips single-byte C0 controls + DEL (ESC, BEL, ...).
                #     Tab (\011) is kept so indentation still reads.
                # (2) sed strips the MULTI-BYTE Unicode format characters that
                #     tr cannot express: bidi overrides/isolates (U+202A-202E,
                #     U+2066-2069), the zero-width family (U+200B-200F) and BOM
                #     (U+FEFF). A bidi override is the dangerous one -- it makes
                #     the reflected path RENDER in reverse, so `evil.js` can be
                #     displayed as something else entirely. `tr -d '[:cntrl:]'`
                #     does NOT cover these (locale-dependent, and C0-only in the
                #     C locale, measured), which is why they are enumerated as
                #     literal UTF-8 byte sequences -- a spelling that behaves
                #     identically under BSD and GNU sed.
                #     This mirrors _strip_control() in the python primary, whose
                #     `isprintable()` rejects category Cf for free. Without pass
                #     (2) the two runtimes DIVERGE on exactly the fallback path
                #     the bash body exists to serve (verified: RTLO survived in
                #     bash and was stripped in python).
                _safe_line="$(command printf '%s' "$line" |
                    command tr -d '\000-\010\013-\037\177' |
                    command sed -E "s/(${_PRESCAN_BIDI_BYTES})//g")"
                echo "Error: ${tool}: input looks like a DIFF, not a file list: ${list}" >&2
                echo "  Offending line: ${_safe_line}" >&2
                echo "  Expected one path per line -- did you mean 'git diff --name-only'?" >&2
                echo "  Refusing to scan: a diff matches no path, so this would emit nothing and exit 0, which reads as a clean scan." >&2
                exit 1
                ;;
        esac
        if [ -e "$line" ]; then
            resolved=$((resolved + 1))
        fi
    done <"$list"

    if [ "$total" -gt 0 ] && [ "$resolved" -eq 0 ]; then
        echo "Warning: ${tool}: no path listed in ${list} exists (${total} non-empty lines); scanning nothing." >&2
        echo "  A stale list or a wrong working directory yields an empty scan that reads as clean. Findings below (if any) are from a partial view." >&2
    fi
}

assert_file_list_shape "$FILE_LIST"

# --- char-aware evidence truncation (#17 bash<->python equivalence) ----------
# Evidence is truncated to a fixed number of CHARACTERS to match the Python
# primary's str[:N]. `printf '%.Ns'` truncates by BYTES (and can split a UTF-8
# character), so multibyte evidence diverged between the two impls. Detect a
# UTF-8 locale once, then slice with bash parameter expansion under it
# (char-wise); fall back to the byte-wise printf if no UTF-8 locale exists.
_PRESCAN_UTF8_LOCALE=""
for _cand in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    # NOT `grep -qixF`: `-q` exits on the FIRST match, `locale -a` then dies of
    # SIGPIPE, and under this file's `set -o pipefail` the pipeline reports 141 —
    # so a locale that EXISTS reads as absent (measured on macOS: rc=0 without
    # pipefail, rc=141 with it). truncate_chars then silently fell back to the
    # byte-wise printf and split a multibyte character mid-sequence, which is the
    # bash<->python divergence #932 surfaced. Same trap the repo recorded in
    # 7a7c0ac. Dropping -q lets grep drain the input; the redirect keeps it quiet.
    if locale -a 2>/dev/null | command grep -ixF "$_cand" >/dev/null 2>&1; then
        _PRESCAN_UTF8_LOCALE="$_cand"
        break
    fi
done
unset _cand
# truncate_chars <maxchars> <string> — first <maxchars> characters on stdout.
truncate_chars() {
    local n="$1" s="$2"
    # Strip a trailing CR before slicing (#902). Evidence is captured from the
    # matched source line; python's text-mode read drops the CRLF `\r` while
    # bash's `grep` keeps it, so a CRLF-terminated line emitted TSV rows
    # differing by one byte between the runtimes. bash normalizes toward python
    # because python is the primary impl and its CR-free evidence is the
    # contract tests/validate-python-ports.sh pins. It runs before the slice by
    # convention, so all 15 copies stay identical and one grep can gate them
    # all — NOT because the order is observable here: for a single trailing CR
    # the two orders were measured equivalent at every n and in both slice
    # spellings.
    s=${s%$'\r'}
    if [ -n "$_PRESCAN_UTF8_LOCALE" ]; then
        local LC_CTYPE="$_PRESCAN_UTF8_LOCALE"
        printf '%s' "${s:0:$n}"
    else
        command printf "%.${n}s" "$s"
    fi
}

# is_test_file PATH — return 0 (true) if PATH is a test file by path/name
# convention. Segment-anchored so that contest.py / latest.js / attestation.go
# (which a bare *test* glob wrongly matches) are NOT skipped, while
# tests/helper.py IS. Mirrors the check-code-health / ship-issue copies for
# classification uniformity. check-lifecycle skips a test file WHOLESALE (below).
#
# The two arm groups anchor DIFFERENTLY, and the split is load-bearing
# (#568, and #836 for this copy): in a bash `case` glob, `*` crosses `/`, so a
# path arm like `*/test_*.*` also matches a DIRECTORY named `test_helpers/` —
# and because this scanner skips WHOLESALE, that silenced every lifecycle
# finding for real source at `src/test_helpers/production.py`. Directory arms
# are meant to cross slashes; the name arms are matched against the BASENAME so
# they cannot. The patterns.py twin is basename-anchored for the same reason —
# keep the two in step.
#
# DELIBERATELY NOT in validate-shared-scanner-sync.sh's SHARED_PAIRS (#836).
# That gate pins byte-identity between the check-code-health <-> pre-review-gates
# pair, where the predicate gates ONE category. This copy gates the WHOLE
# per-file scan, so byte-identity with a differently-purposed copy is the wrong
# contract to enforce; the behavioral gate
# (tests/validate-lifecycle-detectors.sh, which drives BOTH runtimes) is what
# pins this one. Anchoring is still the shared invariant — if you edit the arms
# here, edit patterns.py's is_test_file() to match.
is_test_file() {
    case "$1" in
        tests/* | */tests/* | test/* | */test/* | \
            __tests__/* | */__tests__/* | spec/* | */spec/* | \
            __pycache__/* | */__pycache__/*) return 0 ;;
    esac
    case "${1##*/}" in
        test_*.*) return 0 ;;
        *_test.* | *_spec.* | *.test.* | *.spec.*) return 0 ;;
    esac
    return 1
}

# emit_rows PATTERN CATEGORY LABEL FILE — one MEDIUM row per matching line,
# evidence = "LABEL: <first 80 chars of the line>". Mirrors patterns.py emit().
emit_rows() {
    command grep -nE -- "$1" "$4" 2>/dev/null |
        while IFS= read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$4" "$line_num" "$2" "$3: ${evidence}" "MEDIUM"
        done || true
}

# Per-category labels — ONE literal per category across every language arm, kept
# identical to patterns.py's L_* constants (byte-parity insurance).
L_SUBPROCESS="Subprocess spawned without visible reap"
L_TERMINATE="Terminate without kill escalation"
L_HANDLE="Handle acquired without scoped close"
L_LISTENER="Listener/timer registered without visible removal"

while IFS= read -r file; do
    [ -f "$file" ] || continue

    # Skip non-source files (lock files before generic extensions)
    case "$file" in
        *.lock | *lock.json | *go.sum) continue ;;
        *.md | *.txt | *.json | *.yaml | *.yml | *.toml | *.ini | *.cfg | *.conf) continue ;;
    esac

    # Lifecycle shortcuts in test scaffolding are expected — skip test files
    # WHOLESALE (unlike check-code-health, which only gates debug-statement).
    is_test_file "$file" && continue

    # CASE-INSENSITIVE extension arms (#754), matching patterns.py's `.lower()`
    # before dispatch. A literal `case` here left `Server.PY` unscanned under
    # bash while python scanned it — silent, exit 0, no output. The SKIP block
    # above stays literal on purpose: both impls already agree there, and
    # widening it is a separate decision.
    #
    # Bracket classes keep the match fork-free and bash-3.2 clean (`${file,,}`
    # is bash 4; macOS ships 3.2).
    case "$file" in
        *.[Ss][Ww][Ii][Ff][Tt])
            emit_rows '\bProcess[[:space:]]*\(' "unreaped-subprocess" "$L_SUBPROCESS" "$file"
            emit_rows '\.terminate[[:space:]]*\(\)' "terminate-without-kill" "$L_TERMINATE" "$file"
            emit_rows '=[[:space:]]*FileHandle[[:space:]]*\(' "unclosed-handle" "$L_HANDLE" "$file"
            emit_rows '\.addObserver[[:space:]]*\(|\bscheduledTimer\b' "unpaired-listener" "$L_LISTENER" "$file"
            ;;
        *.[Pp][Yy])
            emit_rows '\b(subprocess\.)?Popen[[:space:]]*\(' "unreaped-subprocess" "$L_SUBPROCESS" "$file"
            emit_rows '\.terminate[[:space:]]*\(\)' "terminate-without-kill" "$L_TERMINATE" "$file"
            emit_rows '=[[:space:]]*open[[:space:]]*\(' "unclosed-handle" "$L_HANDLE" "$file"
            # Registration sites (#841) -- signal handler, exit hook, timer
            # thread, asyncio loop callback. Twin of the patterns.py arm; see
            # there for why threading.Timer is in and a bare `Timer(` is not.
            #
            # BOTH boundaries spelled long-hand: `\w` and `\b` are GNU
            # extensions BSD grep reads as literals, so the leading side is a
            # negated bracket class. It admits `.` on purpose -- see the twin in
            # patterns.py for the measurement (excluding `.` bought no negative
            # and silenced the qualified true positives). The trailing side is
            # carried by the REQUIRED `[[:space:]]*\(`, a genuine terminator
            # unlike Phase 2's `[^{}]*`, which admitted identifier characters
            # and let `catches { }` through on bash alone.
            #
            # Registration sites (#841), leading boundary via POSIX `grep -w`
            # -- see emit_rows_word above for why no bracket class works here
            # and for the C-locale limitation this spelling still carries.
            #
            # -w drops the "must be a call" requirement (it needs the match to
            # END on a word character, which `(` is not), so the paren test is
            # re-imposed as the fifth argument rather than folded in. ONE call,
            # not two: emit_rows_word greps the whole file, so a second call
            # would emit its rows AFTER the first pattern's while the python
            # twin walks line by line -- a ROW ORDER divergence that
            # validate-python-ports.sh compares byte-for-byte (measured: the
            # two-call spelling emits 2,1 where python emits 1,2). A single
            # alternation also keeps a line matching both halves at ONE row.
            emit_rows_word '(signal\.signal|atexit\.register|threading\.Timer|add_signal_handler|add_reader|add_writer)' "unpaired-listener" "$L_LISTENER" "$file" '(signal\.signal|atexit\.register|threading\.Timer|add_signal_handler|add_reader|add_writer)[[:space:]]*\('
            ;;
        *.[Jj][Ss] | *.[Tt][Ss] | *.[Jj][Ss][Xx] | *.[Tt][Ss][Xx] | *.[Mm][Jj][Ss] | *.[Cc][Jj][Ss])
            emit_rows '\b(spawn|spawnSync|exec|execFile|execFileSync|execSync)[[:space:]]*\(' "unreaped-subprocess" "$L_SUBPROCESS" "$file"
            emit_rows '\.terminate[[:space:]]*\(\)' "terminate-without-kill" "$L_TERMINATE" "$file"
            emit_rows '=[[:space:]]*fs\.(openSync|createReadStream|createWriteStream)[[:space:]]*\(' "unclosed-handle" "$L_HANDLE" "$file"
            emit_rows '\.addEventListener[[:space:]]*\(|\bsetInterval[[:space:]]*\(|\.on[[:space:]]*\(' "unpaired-listener" "$L_LISTENER" "$file"
            ;;
        *.[Gg][Oo])
            emit_rows '\bexec\.Command[[:space:]]*\(' "unreaped-subprocess" "$L_SUBPROCESS" "$file"
            emit_rows '\bos\.Interrupt\b' "terminate-without-kill" "$L_TERMINATE" "$file"
            emit_rows '\bos\.(Open|Create)[[:space:]]*\(' "unclosed-handle" "$L_HANDLE" "$file"
            ;;
        *.[Rr][Ss])
            # Rust (#838). std::process::Command is the spawn site.
            #
            # terminate-without-kill asks whether a GRACEFUL stop escalates to
            # SIGKILL (SKILL.md: "confirm the timeout/cancel branch escalates to
            # SIGKILL and issues a final wait"). std::process has no graceful
            # stop at all — `Child::kill()` IS SIGKILL — so keying on `.kill()`
            # would invert the question, flagging the escalation as if it were
            # the thing missing it. The graceful send site in Rust is an explicit
            # SIGTERM via libc/nix, so that is what this arm matches.
            emit_rows '\bCommand::new[[:space:]]*\(' "unreaped-subprocess" "$L_SUBPROCESS" "$file"
            emit_rows '\bSIGTERM\b' "terminate-without-kill" "$L_TERMINATE" "$file"
            emit_rows '=[[:space:]]*File::(open|create)[[:space:]]*\(' "unclosed-handle" "$L_HANDLE" "$file"
            # Registration sites. Rust has no DOM-style addEventListener; the
            # real long-lived registrations are a bound listening socket and an
            # installed signal handler, both of which outlive the statement and
            # want a matching teardown.
            emit_rows '\b(TcpListener|UnixListener)::bind[[:space:]]*\(|\bsignal::unix::signal[[:space:]]*\(' "unpaired-listener" "$L_LISTENER" "$file"
            ;;
        *.[Ss][Hh] | *.[Bb][Aa][Ss][Hh])
            # Bash (#842, ADR 0002 Phase 5). Two of the four categories are
            # modeled; the other two are `—` for the reasons below, not for want
            # of an arm.
            #
            # unreaped-subprocess: a command backgrounded with a trailing `&`.
            # THREE exclusions, each measured necessary against this repo's own
            # 299-file shell corpus rather than reasoned about:
            #
            #   `&&`  — a control operator, not a job-control `&`.
            #   `>&`  — an fd-dup (`2>&1`), which is why the class before the
            #           space excludes `>` and `|` as well.
            #   an ASSIGNMENT-shaped line — `_tgt="${_tgt#&}"`. This one is the
            #           interesting exclusion: that line's `&` sits inside a
            #           TRAILING comment, and is_comment() is line-START only,
            #           so the lexical model cannot suppress it. It was the sole
            #           false positive in the corpus, and excluding assignments
            #           is what removes it. A backgrounded job is a COMMAND, so
            #           the exclusion costs no true positive.
            #
            # Measured after those exclusions: 6 rows over the non-test corpus,
            # all genuine background jobs, 0 false positives. Like every other
            # arm here this is a single-line CANDIDATE for the LLM pass to
            # confirm against its `wait` — deliberately not a lookahead, since a
            # reaping `wait` may sit anywhere (a trap, a later loop, a caller).
            #
            # The exclusion rides emit_rows_unless because ERE has no negative
            # lookahead. `[ \t]` is spelled as a bracket expression here (not
            # `\t`, which BSD grep reads literally) — the class before it must
            # keep excluding the backtick and both quote characters.
            emit_rows_unless '[^&>|`"'"'"'}][[:space:]]&[[:space:]]*$' "unreaped-subprocess" "$L_SUBPROCESS" "$file" '^[0-9]+:[[:space:]]*[A-Za-z_][A-Za-z0-9_]*='
            # terminate-without-kill: the GRACEFUL send site, matching how the
            # Rust arm above reads this category — flag the SIGTERM, let the
            # pass confirm it escalates. `-15` and `-s TERM` are the same signal
            # spelled two other ways; all three appear in the wild.
            emit_rows '\bkill[[:space:]]+(-TERM|-15|-s[[:space:]]+TERM)\b' "terminate-without-kill" "$L_TERMINATE" "$file"
            # unclosed-handle is `—`: bash's analogue would be `exec 3>file`
            # without a closing `exec 3>&-`, and that idiom measures ZERO
            # occurrences across the corpus. An arm for it would be unfalsifiable
            # by this repo's own evidence. Pinned by a silence fixture instead,
            # the way Swift's empty `debugger` column is.
            #
            # unpaired-listener is `—`: bash has no in-process registration that
            # outlives the statement. `trap` is the nearest shape, but a trap is
            # scoped to the shell's own lifetime and needs no paired removal —
            # flagging it would report the correct idiom as the defect.
            ;;
    esac

done <"$FILE_LIST"
