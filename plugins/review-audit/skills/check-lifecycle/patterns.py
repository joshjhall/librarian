#!/usr/bin/env python3
"""check-lifecycle — Deterministic Pre-Scan (Python primary implementation).

Detects resource-lifecycle CANDIDATES catchable by a single-line regex:
subprocess spawn sites, SIGTERM/terminate sites, unscoped handle acquisitions,
and listener/timer registrations. These are suspicious on one line but the paired
release may live elsewhere in the scope, so every row is emitted at certainty
MEDIUM — a candidate the LLM pass-2 confirms or dismisses, never an auto-fix.
The judgment-heavy categories (`unjoined-worker`, `unbounded-growth`) are LLM-only
and produced by pass-2, not here.

Python 3.11+ primary implementation behind the language-agnostic TSV contract;
the sibling patterns.sh is the portable bash fallback (it exec's this file when a
python3>=3.11 is present). Both emit byte-identical findings — the parity is
pinned by tests/validate-python-ports.sh and tests/validate-prescan-differential.sh
(whole-repo diff), and the classification behavior by
tests/validate-lifecycle-detectors.sh. See CLAUDE.md § Key conventions.

The is_test_file() helper mirrors the segment-anchored check-code-health /
ship-issue copies for classification uniformity (it is NOT wired into the
validate-shared-scanner-sync.sh drift gate, which covers only the
check-code-health <-> ship-issue pair — this copy stands alone, a decision
re-affirmed in #836). check-lifecycle skips test files WHOLESALE (lifecycle
shortcuts in test scaffolding are expected), so the helper gates the whole
per-file scan rather than a single category — which is precisely why an
anchoring drift here is expensive: it silences the file entirely, not one
category. The name arms match the BASENAME so a directory named `test_*/` can
never suppress the real source inside it (#836); keep patterns.sh in step.

Input:  argv[1] = file containing paths to scan (one per line)
Output: TSV to stdout: file<TAB>line<TAB>category<TAB>evidence<TAB>certainty

Exit codes:
  0 = success (zero or more findings)
  1 = usage error (missing argument) or file list not found
"""

from __future__ import annotations

import os
import re
import sys
from fnmatch import fnmatch

CERTAINTY = "MEDIUM"
EVIDENCE_CAP = 80  # matches printf '%.80s' in patterns.sh

# Non-source files skipped wholesale (lock files before generic extensions) —
# mirrors the leading `case "$file"` skip arms in patterns.sh.
SKIP_GLOBS = (
    "*.lock",
    "*lock.json",
    "*go.sum",
    "*.md",
    "*.txt",
    "*.json",
    "*.yaml",
    "*.yml",
    "*.toml",
    "*.ini",
    "*.cfg",
    "*.conf",
)


def is_test_file(path: str) -> bool:
    """Return True if PATH is a test file by path/name convention. Mirrors the
    is_test_file() block in patterns.sh (segment-anchored so contest.py /
    latest.js are NOT matched, while tests/helper.py IS). PATH-only:
    content-colocated tests are not this function's concern."""
    for seg in ("tests", "test", "__tests__", "spec", "__pycache__"):
        if path.startswith(seg + "/") or ("/" + seg + "/") in path:
            return True
    base = path.rsplit("/", 1)[-1]
    if fnmatch(base, "test_*.*"):
        return True
    for pat in ("*_test.*", "*_spec.*", "*.test.*", "*.spec.*"):
        if fnmatch(base, pat):
            return True
    return False


def emit(path: str, line_no: int, category: str, label: str, content: str) -> None:
    """Write one TSV finding row: '<label>: <first 80 chars of the code line>'."""
    evidence = label + ": " + content[:EVIDENCE_CAP]
    sys.stdout.write(
        "\t".join((path, str(line_no), category, evidence, CERTAINTY)) + "\n"
    )


# Per-category labels — kept ONE string per category across every language arm so
# the bash fallback can reuse the identical literal (byte-parity insurance).
L_SUBPROCESS = "Subprocess spawned without visible reap"
L_TERMINATE = "Terminate without kill escalation"
L_HANDLE = "Handle acquired without scoped close"
L_LISTENER = "Listener/timer registered without visible removal"


def scan_file(path: str, lines: list[str]) -> None:
    # Lifecycle shortcuts in test scaffolding are expected — skip test files
    # WHOLESALE (unlike check-code-health, which only gates debug-statement).
    if is_test_file(path):
        return
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""

    for idx, line in enumerate(lines, start=1):
        if ext == "swift":
            if re.search(r"\bProcess\s*\(", line):
                emit(path, idx, "unreaped-subprocess", L_SUBPROCESS, line)
            if re.search(r"\.terminate\s*\(\)", line):
                emit(path, idx, "terminate-without-kill", L_TERMINATE, line)
            if re.search(r"=\s*FileHandle\s*\(", line):
                emit(path, idx, "unclosed-handle", L_HANDLE, line)
            if re.search(r"\.addObserver\s*\(|\bscheduledTimer\b", line):
                emit(path, idx, "unpaired-listener", L_LISTENER, line)
        elif ext == "py":
            if re.search(r"\b(subprocess\.)?Popen\s*\(", line):
                emit(path, idx, "unreaped-subprocess", L_SUBPROCESS, line)
            if re.search(r"\.terminate\s*\(\)", line):
                emit(path, idx, "terminate-without-kill", L_TERMINATE, line)
            if re.search(r"=\s*open\s*\(", line):
                emit(path, idx, "unclosed-handle", L_HANDLE, line)
            # Registration sites (#841). Python has no DOM-style
            # addEventListener; the long-lived registrations are a signal
            # handler, an interpreter-exit hook, a timer thread, and an asyncio
            # loop callback -- each outlives the statement and wants a matching
            # teardown (signal.SIG_DFL, atexit.unregister, .cancel(),
            # remove_signal_handler/remove_reader).
            #
            # `threading.Timer` is matched though the 3.12 stdlib itself never
            # calls it (measured 0, against 17 signal.signal / 11
            # atexit.register / 4 add_signal_handler / 2 add_reader): it is the
            # canonical Python timer idiom, and the stdlib not using its own
            # convenience wrapper says nothing about application code. A BARE
            # `Timer(` is deliberately NOT matched -- too generic to carry this
            # category's confidence.
            #
            # The leading boundary is `[^\w]` and deliberately ADMITS `.`.
            # An earlier draft excluded `.` too, on the theory that
            # `mysignal.signal(` would otherwise match on its attribute-access
            # tail. Measured: it does not -- the `y` of `mysignal` already fails
            # `[^\w]`, so the exclusion bought no negative. What it DID buy was
            # a false NEGATIVE, silencing the qualified forms that are true
            # positives -- a dotted-qualified `mod.threading.Timer` or
            # `self.loop.add_reader` call. Both runtimes therefore spell it
            # `[^\w]` / `[^[:alnum:]_]`, and the negative fixtures pin the
            # boundary that actually does the work.
            #
            # NON-ASCII: do NOT add `re.ASCII` here. Python's `\w` is
            # Unicode-aware regardless of the OS locale, which is the behaviour
            # the bash twin is written to match -- it uses POSIX `grep -w`
            # after two bracket-class spellings failed (one bytewise under a
            # `C` locale, one rejected outright by BSD grep). Read the
            # emit_rows_word comment in the twin before touching either side.
            #
            # The twin agrees with this arm exactly under a UTF-8 locale; under
            # a strict `C` locale it over-fires on a non-ASCII IDENTIFIER
            # prefix, a documented and fixture-pinned limitation. `re.ASCII`
            # here would "fix" that by breaking this side instead.
            #
            # An earlier draft of this comment asserted the two agreed "under C
            # and C.UTF-8". That was measured with `LC_ALL=C` alone while the
            # ambient `LANG=C.UTF-8` still applied, so the C case was never
            # exercised -- the claim was false and hid a real bug. Measure
            # locale behaviour with `env -i`, never by setting one locale
            # variable over an inherited environment.
            #
            # Note the idiom names above are written WITHOUT a trailing
            # paren on purpose. This scanner has no lexical gating -- every
            # detector is language-specific, so an unmodeled file is skipped
            # rather than mis-scanned, and the price is that a COMMENT in a
            # modeled file is read like code. Spelling a call form in this
            # prose would make the file emit a row about its own comment.
            #
            # ONE re.search over a single alternation, mirroring the bash
            # twin's single emit_rows -- see there for the measurement showing
            # a two-pattern split reverses row order under parity.
            if re.search(
                r"(^|[^\w])(signal\.signal|atexit\.register"
                r"|threading\.Timer)\s*\("
                r"|(^|[^\w])(add_signal_handler|add_reader|add_writer)\s*\(",
                line,
            ):
                emit(path, idx, "unpaired-listener", L_LISTENER, line)
        elif ext in ("js", "ts", "jsx", "tsx", "mjs", "cjs"):
            if re.search(
                r"\b(spawn|spawnSync|exec|execFile|execFileSync|execSync)\s*\(", line
            ):
                emit(path, idx, "unreaped-subprocess", L_SUBPROCESS, line)
            if re.search(r"\.terminate\s*\(\)", line):
                emit(path, idx, "terminate-without-kill", L_TERMINATE, line)
            if re.search(
                r"=\s*fs\.(openSync|createReadStream|createWriteStream)\s*\(", line
            ):
                emit(path, idx, "unclosed-handle", L_HANDLE, line)
            if re.search(r"\.addEventListener\s*\(|\bsetInterval\s*\(|\.on\s*\(", line):
                emit(path, idx, "unpaired-listener", L_LISTENER, line)
        elif ext == "go":
            if re.search(r"\bexec\.Command\s*\(", line):
                emit(path, idx, "unreaped-subprocess", L_SUBPROCESS, line)
            if re.search(r"\bos\.Interrupt\b", line):
                emit(path, idx, "terminate-without-kill", L_TERMINATE, line)
            if re.search(r"\bos\.(Open|Create)\s*\(", line):
                emit(path, idx, "unclosed-handle", L_HANDLE, line)
        elif ext == "rs":
            # Rust (#838). std::process::Command is the spawn site.
            #
            # terminate-without-kill asks whether a GRACEFUL stop escalates to
            # SIGKILL (SKILL.md: "confirm the timeout/cancel branch escalates to
            # SIGKILL and issues a final wait"). std::process has no graceful
            # stop at all — `Child::kill()` IS SIGKILL — so keying on `.kill()`
            # would invert the question, flagging the escalation as if it were
            # the thing missing it. The graceful send site in Rust is an explicit
            # SIGTERM via libc/nix, so that is what this arm matches.
            if re.search(r"\bCommand::new\s*\(", line):
                emit(path, idx, "unreaped-subprocess", L_SUBPROCESS, line)
            if re.search(r"\bSIGTERM\b", line):
                emit(path, idx, "terminate-without-kill", L_TERMINATE, line)
            if re.search(r"=\s*File::(open|create)\s*\(", line):
                emit(path, idx, "unclosed-handle", L_HANDLE, line)
            # Registration sites. Rust has no DOM-style addEventListener; the
            # real long-lived registrations are a bound listening socket and an
            # installed signal handler, both of which outlive the statement and
            # want a matching teardown.
            if re.search(
                r"\b(TcpListener|UnixListener)::bind\s*\(|\bsignal::unix::signal\s*\(",
                line,
            ):
                emit(path, idx, "unpaired-listener", L_LISTENER, line)
        elif ext in ("sh", "bash"):
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
            if re.search(r"[^&>|`\"'}][ \t]&[ \t]*$", line) and not re.search(
                r"^[ \t]*[A-Za-z_][A-Za-z0-9_]*=", line
            ):
                emit(path, idx, "unreaped-subprocess", L_SUBPROCESS, line)
            # terminate-without-kill: the GRACEFUL send site, matching how the
            # Rust arm above reads this category — flag the SIGTERM, let the
            # pass confirm it escalates. `-15` and `-s TERM` are the same signal
            # spelled two other ways; all three appear in the wild.
            if re.search(r"\bkill[ \t]+(-TERM|-15|-s[ \t]+TERM)\b", line):
                emit(path, idx, "terminate-without-kill", L_TERMINATE, line)
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


# --- input-shape guard (#816) -----------------------------------------------
# Mirrors assert_file_list_shape() in the bash fallback. Same two checks, same
# severities, same messages -- the two runtimes must agree on WHEN they fail or
# their exit codes diverge under tests/validate-python-ports.sh parity. Both
# write to stderr ONLY, so the stdout TSV that parity compares is untouched.
#
# Why the two differ in severity: a diff is an unambiguous wrong shape and its
# silent-zero scan is exactly the #816 defect, so it is fatal. A list whose
# paths do not resolve may be legitimate (a diff that only deletes files), and
# an EMPTY list must stay silent -- tests/validate-prescans.sh pins that for
# every pre-scan -- so that one warns and lets the scan proceed.
def _strip_control(text: str) -> str:
    """TEXT with control characters removed (tab kept).

    The offending line is caller-supplied and may come from an untrusted diff.
    Raw ESC/BEL echoed to the operator's terminal can move the cursor, hide
    following output, or drive an OSC title-bar sequence, so it is stripped
    before it is reflected. Mirrors the `tr -d` in the bash fallback.
    """
    return "".join(c for c in text if c == "\t" or (c.isprintable() and c != "\x7f"))


_DIFF_PREFIXES = ("diff --git ", "--- ", "+++ ", "@@ ")


def assert_file_list_shape(paths: list[str], list_path: str, tool: str) -> int:
    """Return 1 when PATHS is a diff (caller must exit), else 0. Warns on stderr
    when nothing in a non-empty list resolves."""
    total = 0
    resolved = 0
    for line in paths:
        if not line:
            continue
        total += 1
        if line.startswith(_DIFF_PREFIXES):
            sys.stderr.write(
                "Error: "
                + tool
                + ": input looks like a DIFF, not a file list: "
                + list_path
                + "\n  Offending line: "
                + _strip_control(line)
                + "\n  Expected one path per line -- did you mean"
                + " 'git diff --name-only'?"
                + "\n  Refusing to scan: a diff matches no path, so this"
                + " would emit nothing and exit 0, which reads as a clean"
                + " scan.\n"
            )
            return 1
        if os.path.exists(line):
            resolved += 1

    if total > 0 and resolved == 0:
        sys.stderr.write(
            "Warning: "
            + tool
            + ": no path listed in "
            + list_path
            + " exists ("
            + str(total)
            + " non-empty lines); scanning nothing."
            + "\n  A stale list or a wrong working directory yields an empty"
            + " scan that reads as clean. Findings below (if any) are from a"
            + " partial view.\n"
        )
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2 or not argv[1]:
        sys.stderr.write("Usage: patterns.py <file-list>\n")
        return 1

    file_list = argv[1]
    try:
        with open(file_list, "r", encoding="utf-8", errors="replace") as fh:
            paths = [ln.rstrip("\n") for ln in fh]
    except OSError:
        sys.stderr.write("Error: file list not found: " + file_list + "\n")
        return 1

    if assert_file_list_shape(paths, file_list, os.path.basename(__file__)):
        return 1

    for path in paths:
        if not path:
            continue
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        if any(fnmatch(path, g) for g in SKIP_GLOBS):
            continue
        scan_file(path, lines)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
