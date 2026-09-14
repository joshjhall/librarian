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


def strip_eol_cr(content: str) -> str:
    r"""One trailing CR off a line before it becomes evidence (#902, #980).

    Mirrors truncate_chars() in the bash fallback, which has stripped it since
    #902 -- same strip, same before-the-slice order. read_lines() deliberately
    KEEPS a CRLF's `\r` in the line so `$`-anchored regexes behave as they do
    under grep (#980); without this the retained `\r` would reach the TSV and
    the two runtimes' evidence would differ by one byte on any CRLF match.
    """
    return content[:-1] if content.endswith("\r") else content


def read_lines(path: str) -> list[str]:
    r"""PATH's lines under grep's line model: split on `\n` ONLY (#980).

    `newline=""` disables universal-newline translation. Without it a lone `\r`
    is rewritten to `\n` by read() BEFORE any split can see it, so even
    `.split("\n")` reports two lines where `grep -n` reports one -- the bash
    fallback reaches every line through grep, so grep's model is the contract.
    str.splitlines(), which this replaced, additionally splits on `\x0b`,
    `\x0c`, `\x1c`-`\x1e` and U+2028/2029, none of which grep treats as a
    separator.

    The trailing empty left by a final newline is dropped so the count matches
    `grep -n` at both ends (a file with no trailing newline keeps its last line;
    a file that is a bare newline still has one, empty, line).

    A CRLF's `\r` STAYS in the line, exactly as it does under grep -- stripping
    it here would silently change every `$`-anchored regex in every scanner.
    It comes off at the evidence cap instead, mirroring truncate_chars (#902).
    """
    with open(path, "r", encoding="utf-8", errors="replace", newline="") as fh:
        lines = fh.read().split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines


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
    evidence = label + ": " + strip_eol_cr(content)[:EVIDENCE_CAP]
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
            # terminate-without-kill keys on the GRACEFUL SEND site, the way the
            # Rust and Bash arms below/above read this category -- flag the
            # SIGTERM, let pass-2 confirm it escalates.
            #
            # It used to key on the bare token os.Interrupt (#871). That was
            # wrong in a way worth recording: in Go that token is not a send
            # site on its own. Its ordinary spelling is as an ARGUMENT to a
            # registration, `signal.Notify(c, os.Interrupt)`, so the
            # scanner filed the registration under this category -- a worse
            # failure than silence, because the evidence reads as a different
            # defect. The send site in Go is an explicit Signal() call, and
            # syscall.SIGTERM is what names it.
            #
            # The EXCLUSION is what stops the same bug returning under a new
            # token: a registration is just as commonly spelled
            # `signal.Notify(c, syscall.SIGTERM)`, which matches the pattern
            # above and is not a send site either. Excluding the registration
            # leaves that line to the unpaired-listener arm below, so it emits
            # exactly one row of the right category. The bash twin spells this
            # with emit_rows_unless and an UNANCHORED exclusion -- read the note
            # at that helper's definition before touching either side.
            #
            # The exclusion matches any QUALIFIED `.Notify(`, not the literal
            # `signal.Notify(`, so an ALIASED import (`import sig "os/signal"`,
            # then `sig.Notify(c, syscall.SIGTERM)`) is still excluded. Keying
            # on the literal package name left aliased code mis-filed here AND
            # dropped from unpaired-listener -- a silent double loss rather than
            # a category swap. The listener arm below is widened the same way so
            # the two stay in step.
            #
            # LIMITATION, stated rather than papered over: both tests are
            # per-LINE, so a call whose argument list is WRAPPED across lines
            # puts `Notify(` and `syscall.SIGTERM` on different lines, and the
            # second is mis-filed exactly as before. Closing that needs
            # multi-line state this single-line scanner does not have. It is
            # fixture-pinned in tests/validate-lifecycle-detectors.sh so the
            # behaviour is a recorded decision, not an unnoticed gap.
            if re.search(r"\bsyscall\.SIGTERM\b", line) and not re.search(
                r"[A-Za-z_][A-Za-z0-9_]*\.Notify\s*\(", line
            ):
                emit(path, idx, "terminate-without-kill", L_TERMINATE, line)
            if re.search(r"\bos\.(Open|Create)\s*\(", line):
                emit(path, idx, "unclosed-handle", L_HANDLE, line)
            # Registration sites (#871). Go has no DOM-style addEventListener;
            # the registrations that outlive their statement and want an
            # explicit teardown are a signal-channel registration
            # (signal.Stop), a ticker (ticker.Stop) and a bound listening
            # socket (ln.Close).
            #
            # time.NewTimer and time.AfterFunc are deliberately NOT matched. A
            # one-shot timer that fires is self-retiring, so flagging one would
            # report the ordinary case as the defect -- the same trade #838
            # refused for Rust's `let _ =`. NewTicker is different in kind: it
            # re-arms forever and leaks until stopped.
            #
            # ONE re.search over a single alternation, mirroring the bash
            # twin's single emit_rows -- a split would make a line matching two
            # members emit two rows on one runtime and one on the other.
            if re.search(
                r"[A-Za-z_][A-Za-z0-9_]*\.Notify\s*\(|\btime\.NewTicker\s*\("
                r"|\bnet\.Listen(TCP|Unix)?\s*\(",
                line,
            ):
                emit(path, idx, "unpaired-listener", L_LISTENER, line)
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
            # shell corpus (304 tracked `.sh` files) rather than reasoned about:
            #
            #   `&&`  — a control operator, not a job-control `&`.
            #   `>&`  — an fd-dup (`2>&1`), which is why the class before the
            #           space excludes `>` and `|` as well.
            #   a TRAILING COMMENT ending in `&` — `… # `>&2` fd-dup … strip &`
            #           (plugins/workflow/hooks/bash-guard.sh:701), the corpus's
            #           sole false positive. is_comment() is line-START only, so
            #           the lexical model cannot suppress a comment that begins
            #           mid-line; this exclusion is what removes it.
            #
            # The comment exclusion keys on the COMMENT, which is the property
            # that actually makes the line a false positive. An earlier draft
            # keyed on the line being ASSIGNMENT-shaped instead — a proxy that
            # happened to cover this one line while silently suppressing every
            # env-prefixed background job (`FOO=bar task &`) and every compound
            # one-liner (`x=1; task &`), both genuine COMMANDS. Likewise the
            # class before the space must NOT exclude the quote characters:
            # doing so made `curl "$url" &` — a backgrounded job whose last
            # token is quoted, which is most of them — invisible. Both were
            # shared across the two runtimes, so parity stayed green while both
            # halves were wrong; see the fixtures that now pin each shape.
            #
            # The exclusion's `[^"']` middle is deliberate and cuts the other
            # way from the class above: it stops a `#` INSIDE a quoted argument
            # from reading as a comment, so `run --opt "a # b" &` stays a
            # finding. The cost is a comment that both contains a quote and ends
            # in `&` — zero corpus occurrences, and the failure is a false
            # POSITIVE at MEDIUM, which the LLM pass dismisses.
            #
            # Measured after those exclusions: 18 rows corpus-wide, all genuine
            # background jobs, 0 false positives. Like every other arm here this
            # is a single-line CANDIDATE for the LLM pass to confirm against its
            # `wait` — deliberately not a lookahead, since a reaping `wait` may
            # sit anywhere (a trap, a later loop, a caller).
            if re.search(r"[^&>|`}][ \t]&[ \t]*$", line) and not re.search(
                r"[ \t]#[^\"']*&[ \t]*$", line
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
            lines = read_lines(path)
        except OSError:
            continue
        if any(fnmatch(path, g) for g in SKIP_GLOBS):
            continue
        scan_file(path, lines)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
