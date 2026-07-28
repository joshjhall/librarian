#!/usr/bin/env python3
"""agnix-normalize — map `agnix --format json` findings to the TSV contract.

The boundary object of the agnix integration spine (issue #397; ADR
plugins/review-audit/docs/adr/0001-agnix-check-ai-config-boundary.md). agnix is
an external Rust linter for AI-config files whose findings enrich the
check-ai-config pre-scan on the overlap set. agnix speaks github|json|sarif, NOT
this repo's TSV finding contract (file<TAB>line<TAB>category<TAB>evidence<TAB>
certainty). This tool bridges that gap: it runs agnix over the manifest, maps
each CC-* rule to a check-ai-config category, and emits the TSV rows so the
checker path (issue #401) can merge them with the always-present floor.

Python 3.11+ primary implementation behind the language-agnostic TSV contract;
the sibling agnix-normalize.sh is the portable bash fallback (it exec's this file
when a python3>=3.11 is present). Both emit byte-identical findings — the parity
is pinned by tests/validate-agnix-normalize.sh. See CLAUDE.md § Key conventions.

Input:  argv[1] = file containing paths to scan (one per line)
Output: TSV to stdout: file<TAB>line<TAB>category<TAB>evidence<TAB>certainty
        evidence is `[<RULE-ID>|<agnix rule_severity>] <message>`; certainty is a
        fixed MEDIUM (see AGNIX_CERTAINTY below for why).

Environment:
  AGNIX_BIN     agnix executable to run (default: `agnix`)
  AGNIX_CONFIG  operator-controlled config file -> agnix --config (ADR §5 trust
                posture; wired fully by #398/#401). Absent -> agnix's own default.

Exit codes:
  0 = success (zero or more findings), OR the agnix binary is absent (no-op)
  1 = usage error (missing argument) or file list not found
  2 = agnix ran but failed / emitted unparsable output (fail loud)

**No-op when agnix is absent.** A missing binary is not an error: emit nothing to
stdout, log one clear skip line to stderr, exit 0. The floor (patterns.*) stands
on its own on platforms without agnix (base macOS, bare host, best-effort
container install) — this normalizer simply contributes nothing there.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys

EVIDENCE_CAP = 80  # match patterns.py: evidence truncated to 80 codepoints

# Every agnix row is emitted at a fixed MEDIUM certainty (issue #470). agnix's
# `rule_severity` is issue *severity*, not detection *confidence*, and it marks
# essentially the whole CC-* schema surface HIGH — the checker's certainty=HIGH
# auto-include fast path (checker.md § Step 3) would therefore land agnix rows in
# the report with no Pass-2 LLM confirmation, including its heuristic and
# false-positive-prone rules. MEDIUM is this repo's established "candidate that
# needs LLM confirmation" tier (check-lifecycle emits it deliberately), so a flat
# MEDIUM routes every agnix row through that pass. It also closes the escalation
# path in the same issue's finding #1 structurally: under the
# CODEBASE_AUDIT_TRUST_PROJECT_SCRIPTS=1 opt-in agnix reads the audited repo's own
# .agnix.toml, whose [[overrides]] severity a hostile repo controls — with a fixed
# tier that value can no longer decide which findings skip confirmation.
AGNIX_CERTAINTY = "MEDIUM"

# CC-* rule-ID prefix -> check-ai-config category slug. Keyed on the rule-ID
# prefix (stable across agnix's per-rule additions), NOT agnix's own `category`
# field. Only agnix's OVERLAP SET with check-ai-config is imported (ADR §2); a
# rule whose prefix is absent here is dropped, so agnix's ~437-rule generic
# surface (VER-*, AS-*, spec rules) never lands at a location the floor does not
# own. Longest-prefix-first matching (CC-MCP- before MCP-, though disjoint here).
RULE_PREFIX_MAP = (
    ("CC-AG-", "agent-frontmatter"),
    ("CC-SK-", "skill-frontmatter"),
    ("CC-HK-", "hook-safety"),
    ("CC-MCP-", "mcp-misconfiguration"),
    ("CC-PL-", "config-inconsistency"),
    # CC-MEM bloat rules (CC-MEM-009/014) are agnix-disabled per ADR §3 so the
    # env-tunable ai-file-bloat thresholds stay authoritative; the non-bloat
    # memory rules (import-path drift, etc.) map to claude-md-drift.
    ("CC-MEM-", "claude-md-drift"),
    ("MCP-", "mcp-misconfiguration"),
)


def die(message: str, code: int) -> int:
    """Fail loud: actionable message on stderr, given exit code."""
    sys.stderr.write(message + "\n")
    return code


def map_rule(rule: str) -> str | None:
    """Map an agnix rule ID to a check-ai-config category, or None if unmapped."""
    for prefix, category in RULE_PREFIX_MAP:
        if rule.startswith(prefix):
            return category
    return None


def _scrub(value: str) -> str:
    """Replace the TSV framing characters (tab, newline, CR) with a space.

    agnix diagnostics are computed over the AUDITED repo's own files (untrusted
    per ADR §5), and many rule messages quote the matched source line — so an
    unsanitized `message` (or `file`) can smuggle literal tabs/newlines into the
    row. A tab forges extra COLUMNS; a newline forges an entire extra ROW with an
    attacker-chosen file, line, category, and `[<RULE-ID>|<SEVERITY>]` prefix.
    That is not cosmetic: checker.md Step 6 Guard 2 parses that severity prefix to
    decide whether to DROP a real check-ai-config floor finding, and the whole TSV
    stream is fed to the checker as LLM context. The floor's own patterns.* are
    structurally immune (grep is line-based, so a match can never contain a
    newline); this path has no such guarantee, so scrub explicitly. The
    EVIDENCE_CAP truncation does NOT help — an injected tab fits well inside 80
    codepoints.
    """
    return value.replace("\t", " ").replace("\n", " ").replace("\r", " ")


def emit(path: str, line_no: str, category: str, evidence: str, certainty: str) -> None:
    row = (path, line_no, category, evidence, certainty)
    sys.stdout.write("\t".join(_scrub(field) for field in row) + "\n")


def _field(diag: dict, key: str) -> str:
    """Read a diagnostic field as a string, coalescing a JSON `null` to "".

    A bare `str(diag.get(key, ""))` only defaults on an ABSENT key; a present
    key whose JSON value is `null` (a common serde `Option<T>` shape) would
    become the literal "None". The bash fallback's jq `// ""` treats null as
    absent, so this mirrors it — critical for the drop-empty-`file` guard (a
    null-file advisory like VER-001 must be dropped, not emitted at file "None")
    and for byte-identical parity.
    """
    val = diag.get(key)
    return "" if val is None else str(val)


def normalize(diagnostics: list[dict]) -> None:
    """Emit a TSV row per mappable diagnostic.

    Skips a diagnostic with an unmapped rule (outside the overlap set) or an
    empty `file` (project-level advisories like VER-001 have no location to
    dedup on downstream).
    """
    for diag in diagnostics:
        rule = _field(diag, "rule")
        category = map_rule(rule)
        if category is None:
            continue
        path = _field(diag, "file")
        if not path:
            continue
        line_no = _field(diag, "line")
        message = _field(diag, "message")
        # Preserve the rule ID AND agnix's own rule_severity inside the evidence
        # column (the TSV has no dedicated field for either); truncate to match
        # patterns.py. The severity rides here rather than in `certainty` so the
        # Step 6 precedence dedup can still compare it against the floor finding's
        # severity before dropping anything (#470 finding #1) while `certainty`
        # stays a fixed confirmation tier. A null/absent rule_severity coalesces
        # to "" via _field, rendering as "[CC-AG-001|] message".
        severity = _field(diag, "rule_severity")
        evidence = ("[" + rule + "|" + severity + "] " + message)[:EVIDENCE_CAP]
        emit(path, line_no, category, evidence, AGNIX_CERTAINTY)


def run_agnix(agnix_bin: str, paths: list[str]) -> str:
    """Run agnix over the paths and return its stdout JSON text.

    Fails loud (SystemExit-equivalent via the caller) on a run that produces no
    usable output. agnix exits non-zero when it finds errors, so a non-zero exit
    is NOT itself a failure — only an empty/blank stdout is.
    """
    # `--config` is a GLOBAL flag and MUST precede the `validate` subcommand —
    # agnix (clap-based) rejects `validate --config …` with "unexpected argument
    # '--config' found" and exit 2, verified on both the pinned 0.40.0 and
    # 0.41.0. Emitting it after `validate` made the whole AGNIX_CONFIG branch
    # non-functional; because stderr is captured but not surfaced, that appeared
    # only as the generic "produced no JSON output" fail-loud, never as the real
    # cause.
    cmd = [agnix_bin, "--format", "json", "--target", "claude-code"]
    config = os.environ.get("AGNIX_CONFIG", "")
    if config:
        cmd += ["--config", config]
    cmd += ["validate"]
    # A `--` end-of-options marker before the paths: the manifest is built from
    # the audited repo's tree (untrusted per ADR §5), and a Unix filename may
    # legally begin with `-`/`--`. Without the terminator, agnix (clap-based)
    # would parse a file literally named `--fix-unsafe` or `--config` as a FLAG,
    # defeating the observe-only fencing the ADR relies on. `--` forces every
    # following token to be a positional path. (Verified agnix accepts it.)
    cmd += ["--"]
    cmd += paths
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    except OSError as exc:
        raise RuntimeError("failed to execute agnix (" + str(exc) + ")") from exc
    if not proc.stdout.strip():
        detail = proc.stderr.strip() or "empty stdout"
        raise RuntimeError("agnix produced no JSON output (" + detail + ")")
    return proc.stdout


def main(argv: list[str]) -> int:
    if len(argv) < 2 or not argv[1]:
        sys.stderr.write("Usage: agnix-normalize.py <file-list>\n")
        return 1

    file_list = argv[1]
    try:
        with open(file_list, "r", encoding="utf-8", errors="replace") as fh:
            paths = [ln.rstrip("\n") for ln in fh if ln.strip()]
    except OSError:
        sys.stderr.write("Error: file list not found: " + file_list + "\n")
        return 1

    # No-op when the agnix binary is absent (not an error — see module docstring).
    agnix_bin = os.environ.get("AGNIX_BIN", "agnix")
    if shutil.which(agnix_bin) is None and not os.path.isfile(agnix_bin):
        sys.stderr.write(
            "[skip] agnix-normalize: agnix binary not found "
            "(AGNIX_BIN=" + agnix_bin + "); floor pre-scan stands alone\n"
        )
        return 0

    # An empty manifest is a legitimate no-work case: emit nothing, exit 0,
    # without invoking agnix over an empty path list.
    if not paths:
        return 0

    try:
        raw = run_agnix(agnix_bin, paths)
    except RuntimeError as exc:
        return die("agnix-normalize: " + str(exc), 2)

    try:
        data = json.loads(raw)
    except (ValueError, TypeError) as exc:
        return die("agnix-normalize: could not parse agnix JSON (" + str(exc) + ")", 2)

    # agnix's top-level output is a JSON object. A non-object (e.g. a bare array)
    # is malformed — fail loud (exit 2), matching the bash fallback, whose jq
    # `.diagnostics` index throws on a non-object. Do NOT silently no-op it.
    if not isinstance(data, dict):
        return die("agnix-normalize: agnix JSON is not an object", 2)
    diagnostics = data.get("diagnostics")
    # Coalesce a JSON `null` (or absent key) to [] — matching the bash fallback's
    # jq `(.diagnostics // [])`, where `//` treats null as empty. A present
    # `"diagnostics": null` (a plausible serde Option<Vec<..>> shape for zero
    # findings) is a clean empty result, NOT a hard failure.
    if diagnostics is None:
        diagnostics = []
    if not isinstance(diagnostics, list):
        return die("agnix-normalize: agnix JSON has no diagnostics array", 2)
    # Every diagnostic must be an object. A non-dict element is malformed output
    # (schema drift / buggy build / hostile input) — fail loud before emitting a
    # partial stream, matching the bash fallback's whole-parse failure, rather
    # than crashing with an unhandled AttributeError mid-loop.
    if not all(isinstance(diag, dict) for diag in diagnostics):
        return die("agnix-normalize: agnix diagnostics array holds a non-object", 2)

    normalize(diagnostics)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
