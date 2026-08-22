#!/usr/bin/env python3
"""next-issue — plan-lens sizing pre-scan (Python primary implementation).

THE THIRD LENS (issue #756). File-size discipline had two lenses, both reactive:

    lens    | question                      | growth signal
    --------|-------------------------------|--------------------
    audit   | is this file too long?        | none
    review  | did this diff make it worse?  | git diff --numstat
    plan    | will this plan make it worse? | PLANNER ESTIMATE   <- this file

The audit lens (check-decomposition) sweeps a whole repo and produces a backlog
nobody works through. The review lens (ship-issue/sizing.{py,sh}) runs per-PR and
fires only once the work already exists, when reworking means unpicking a
finished implementation. Neither runs during PLANNING, which is the one moment a
decomposition is cheap.

WHY THIS CANNOT BE A THRESHOLD TWEAK ON THE REVIEW LENS. Both existing lenses
return early for a file UNDER its threshold, so the case that matters most here
produces no row at all today: a file at 640 lines against a 700 budget is silent,
and it is exactly the file a planner needs warned about when the plan will add
200 lines to it. Answering "will this plan make it worse?" requires projecting
`current + estimate` against the budget — an arithmetic neither lens performs.

THE ESTIMATE IS THE WEAK INPUT, deliberately. It is a planner's guess made before
implementation and will sometimes be wrong. That is acceptable because the output
is advisory — it expands a plan a human still approves — and it is the reason
this lens must never become blocking.

THE LOC ENGINE IS NOT RE-DERIVED. This scanner shells out to
`sizing.{py,sh} --measure`, which emits the 13-field metrics record computed by
the SAME code the review lens uses (and which is itself pinned byte-for-byte
against check-decomposition through the `# >>> shared:loc-*` sentinel regions).
A fourth hand-copy of the counting rules is precisely what #663 was filed to
kill, and a sentinel region cannot pin text in a file it does not cover — it
could not have stopped this scanner from counting production LOC its own way.
So measure mode is a SEAM: sizing owns "how big is it and by which budget", this
file owns only the projection on top.

Input:  argv[1] = file containing paths to scan (one per line)
        argv[2] = OPTIONAL estimate sidecar: `added<TAB>path` rows, the planner's
                  per-file estimate of lines this plan will add. Deliberately
                  the same shape numstat uses (count first, path last) so the
                  rename-aware parser is reused rather than re-derived.
                  ABSENT => no growth signal, so already-over files are reported
                  LOW/informational and NO headroom row is emitted (there is
                  nothing to project).
Output: TSV to stdout: file<TAB>line<TAB>category<TAB>evidence<TAB>certainty

The 5-column contract is NOT widened — it is the language boundary every check-*
skill and all three parity gates depend on.

Exit codes:
  0 = success (zero or more findings)
  1 = usage error (missing argument) or file list not found
  2 = required runtime absent (fail loud — never a silent "no findings")
"""

from __future__ import annotations

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# Headroom band. A file is a headroom candidate when it is UNDER its budget today
# but the planner's estimate would carry it over. PLAN_HEADROOM_MIN_ESTIMATE is
# the floor below which a projection is not worth acting on: without it, a file
# one line under budget would fire on a 1-line estimate, which is noise and gets
# the lens turned off. Mirrors thresholds.yml § plan_size_thresholds.
DEFAULT_MIN_ESTIMATE = 25


def _int_env(name: str, default: int) -> int:
    """Read an integer threshold from the environment, falling back to DEFAULT.

    Mirrors _int_env in sizing.py / patterns.py so thresholds.yml values pass
    through identically in every scanner.
    """
    val = os.environ.get(name, "")
    try:
        return int(val)
    except ValueError:
        return default


def emit(path: str, line_no: int, category: str, evidence: str, certainty: str) -> None:
    """Write one TSV finding row."""
    sys.stdout.write(
        "\t".join((path, str(line_no), category, evidence, certainty)) + "\n"
    )


def sidecar_path(field: str) -> str:
    """The POST-rename path from a sidecar path field.

    Reused verbatim from sizing.py's numstat_path() rationale: git prints a
    rename as `old.py => new.py` or `a/{x => y}/f.py`, neither of which matches
    the plain path in the caller's file list. Left unresolved the lookup misses,
    the estimate silently reads 0, and the file can never be reported — the one
    case the lens most wants to see.

    The plan lens's own sidecar is hand-written by a planner and will rarely
    carry a rename, but accepting the same shape means a caller can feed a real
    numstat file (e.g. estimates derived from a prior branch) without surprise.
    """
    if "=>" not in field:
        return field
    start = field.find("{")
    if start != -1:
        end = field.find("}", start)
        if end != -1:
            inner = field[start + 1 : end]
            after = inner.split("=>", 1)[1].strip() if "=>" in inner else inner
            return (field[:start] + after + field[end + 1 :]).replace("//", "/")
    return field.split("=>", 1)[1].strip()


def read_estimates(path: str) -> dict[str, int]:
    """Per-file estimated added lines from the sidecar.

    Accepts both the 2-column plan shape (`added<TAB>path`) and the 3-column
    numstat shape (`added<TAB>deleted<TAB>path`), keying off field count, so a
    caller may hand this a real `git diff --numstat` file unchanged.

    A missing/unreadable sidecar yields {} — which the caller treats as 'no
    growth signal', NOT as 'no growth'. The distinction is the whole disposition
    table below.
    """
    counts: dict[str, int] = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for row in fh:
                parts = row.rstrip("\n").split("\t")
                if len(parts) < 2:
                    continue
                added, name = parts[0], parts[-1]
                try:
                    counts[sidecar_path(name)] = int(added)
                except ValueError:
                    continue
    except OSError:
        return {}
    return counts


def measure_all(file_list: str) -> list[list[str]]:
    """The 13-field metrics record per file, from sizing's measure mode.

    FAIL LOUD (exit 2) rather than returning nothing when the engine cannot be
    reached: a scanner with no runtime must never report 'no findings', because
    a clean empty report is indistinguishable from 'everything is fine' and lets
    the gate sit inert unnoticed (the #538/#571 sentinel discipline). The
    PLANNER's tolerance for that failure is a separate matter — it catches this
    exit and proceeds with a note (#756 AC12) — but the scanner itself refuses.
    """
    engine_py = os.path.join(HERE, "sizing.py")
    engine_sh = os.path.join(HERE, "sizing.sh")
    if os.path.isfile(engine_py):
        cmd = [sys.executable, engine_py, "--measure", file_list]
    elif os.path.isfile(engine_sh):
        cmd = ["bash", engine_sh, "--measure", file_list]
    else:
        sys.stderr.write(
            "Error: plan-lens requires the sibling sizing.{py,sh} LOC engine; "
            "found neither.\n"
            "  This scanner refuses to report 'no findings' when it cannot scan.\n"
        )
        raise SystemExit(2)

    try:
        out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        sys.stderr.write(f"Error: plan-lens could not run the sizing engine: {exc}\n")
        raise SystemExit(2) from exc

    rows = []
    for line in out.split("\n"):
        if not line:
            continue
        fields = line.split("\t")
        if len(fields) >= 13:
            rows.append(fields)
    return rows


def scan_record(fields: list[str], estimate: int, have_estimate: bool) -> None:
    """Emit plan-lens rows for one candidate file.

    THE DISPOSITION TABLE — and note it is NOT the review lens's:

      under budget, projection crosses    -> size-headroom, MEDIUM/HIGH  (AC2)
      already over budget                 -> file-length/bloat, MEDIUM   (AC3)
      already over, no estimate supplied  -> same category, LOW          (AC4)
      under budget, projection stays under-> nothing

    AC3 reports an already-over file REGARDLESS of estimate, which is the
    deliberate difference from the review lens. There, a one-line touch to a
    pre-existing oversized file is explicitly not the author's debt. Here the
    planner is about to open the file anyway, and that is the cheapest moment the
    split will ever have — so it is raised, with evidence that distinguishes it
    from a projected crossing.
    """
    (
        path,
        s_total,
        s_production,
        s_units,
        _comment_pct,
        _generated,
        lang,
        s_warn,
        s_high,
        s_bwarn,
        s_bhigh,
        b_type,
        b_cat,
    ) = fields[:13]

    total = int(s_total)
    production = int(s_production)
    units = int(s_units)
    b_warn = int(s_bwarn)

    # Classified prose is measured on TOTAL lines by its own per-type budget;
    # everything else on production LOC by the code thresholds. The choice is
    # made in sizing's shared bloat-spec region, not re-derived here — what a
    # file IS is a fact about its path and must not fork (#724).
    if b_warn > 0:
        current, warn, high = total, b_warn, int(s_bhigh)
        category, label, unit = b_cat, b_type, "lines"
    else:
        current, warn, high = production, int(s_warn), int(s_high)
        category = "file-length"
        label = lang if lang else "this file"
        unit = "production LOC"

    min_estimate = _int_env("PLAN_HEADROOM_MIN_ESTIMATE", DEFAULT_MIN_ESTIMATE)

    # ---- already over budget today (AC3) -----------------------------------
    if current > warn:
        band = "high" if current > high else "warning"
        limit = high if current > high else warn
        if have_estimate and estimate > 0:
            certainty = "HIGH" if current > high else "MEDIUM"
            evidence = (
                f"{label} is already over its {band} budget: {current} {unit} "
                f"(>{limit}); this plan adds ~{estimate} more. Decompose before "
                f"implementing — the seam is cheapest now, while the file is "
                f"already open"
            )
        elif have_estimate:
            # A sidecar EXISTS but names no growth for this file. Distinct from
            # the no-sidecar case below and must not borrow its wording: saying
            # "no estimate supplied" here would be false, and would hide that
            # the planner did size this file and expects it not to grow.
            certainty = "LOW"
            evidence = (
                f"{label} is already over its {band} budget: {current} {unit} "
                f"(>{limit}); this plan does not add to it — informational only"
            )
        else:
            certainty = "LOW"
            evidence = (
                f"{label} is already over its {band} budget: {current} {unit} "
                f"(>{limit}); no plan estimate supplied — informational only"
            )
        emit(path, 1, category, evidence, certainty)
        return

    # ---- headroom: under budget, but the plan would cross it (AC2) ---------
    # THE ROW NEITHER OTHER LENS CAN PRODUCE. Both return early above their
    # threshold check; this arm exists precisely for the file they skip.
    if not have_estimate or estimate < min_estimate:
        return

    projected = current + estimate
    if projected <= warn:
        return

    band = "high" if projected > high else "warning"
    limit = high if projected > high else warn
    certainty = "HIGH" if projected > high else "MEDIUM"
    headroom = warn - current
    evidence = (
        f"{label} has {headroom} {unit} of headroom ({current}/{warn}); this "
        f"plan adds ~{estimate}, projecting {projected} — over the {limit} "
        f"{band} budget. Fold the decomposition into the plan before adding to "
        f"this file ({units} top-level units)"
    )
    emit(path, 1, "size-headroom", evidence, certainty)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        sys.stderr.write("Usage: plan-lens.py <file-list> [estimate-sidecar]\n")
        return 1
    file_list = argv[1]
    if not os.path.isfile(file_list):
        sys.stderr.write(f"Error: file list not found: {file_list}\n")
        return 1

    estimates = read_estimates(argv[2]) if len(argv) > 2 else {}
    have_estimate = bool(estimates)

    for fields in measure_all(file_list):
        scan_record(fields, estimates.get(fields[0], 0), have_estimate)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
