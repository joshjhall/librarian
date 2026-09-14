#!/usr/bin/env python3
"""okf-migrate — the OKF migration engine (slice D, #671).

Slices A-C REPORT. This one changes things. A checker that only reports pushes
the whole adoption cost onto every consuming repo, one hand-edit at a time —
which is the failure #663 names, where detection without a mechanized
recommendation gets ignored. This is the adoption path.

THREE MODES:

  check   report what would need migrating. Read-only. THE DEFAULT.
  plan    render the full change set as a reviewable diff. Read-only.
  apply   execute a plan. Explicit subcommand + --confirm. Never the default.

`plan` is the important one: a repo owner reviews a diff rather than trusting a
bulk rewrite.

TWO KINDS OF FAILURE, KEPT STRICTLY APART — the same split slice A draws, and
for the same reason (#664 says conflating them is how this lands wrong):

  * THE BUNDLE is never rejected. A non-conformant bundle is exactly what this
    tool exists to fix, so every migration finding is reported at EXIT 0.
  * THE TOOL fails loud. A usage error, an unresolvable version pin, a dirty
    tree under `apply`, or an ambiguity requiring a human exits NON-ZERO with an
    actionable message (#538/#571).

WHY NOT A pre-scan. This is deliberately not named `check-*` and its tool is
deliberately not `patterns.sh`: those names are auto-discovered by the checker
agent, by bin/check-patterns-coverage.sh (which would demand a contract.md
Categories table this tool has no business having), and by
tests/validate-prescans.sh (which imposes a file-list CLI). A migration engine
is not a scanner. Its bash<->python parity is pinned by its own suite,
tests/validate-okf-migrate.sh, per the scope rule at
tests/validate-python-ports.sh:99-105 — the same call split-verify.{py,sh} made.

Exit codes:
  0 = success (including "this bundle needs migrating")
  1 = usage error, unresolvable version pin, or an unreadable bundle
  2 = apply refused (dirty tree, missing --confirm, or a plan-only transform)
  3 = apply blocked on an ambiguity that requires a human choice

Runtime: Python 3.11+ primary, mirrored by migrate.sh for bash-3.2 hosts.
"""

from __future__ import annotations

import os
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

# The transform bodies travel with this file exactly as bundle_graph.py travels
# with the validator's patterns.py. Wrapped so a missing sibling produces the
# SAME actionable message the bash twin gives, rather than a raw
# ModuleNotFoundError traceback: both exit non-zero either way, so this is about
# the diagnostic, not the verdict — and a tool that cannot load its transforms
# must say so in terms that name the consequence, because an empty plan reads as
# "this bundle needs no migration".
try:
    from moves import (  # noqa: E402
        is_index_name,  # noqa: F401
        parse_taxonomy_rules,
        plan_directory_indexes,
        plan_moves,
        rewrite_inbound_links,
    )
    from transforms import (  # noqa: E402
        Ambiguity,
        Edit,
        adopt_bundle,
        backfill_type,
        convert_wikilinks,
        parse_type_rules,
        read_lines,
        strip_quotes,
    )
except ImportError:
    sys.stderr.write(
        "ERROR: transforms.py/moves.py not found beside migrate.py in "
        + _HERE
        + " — no transform can run, and an empty plan would read as a bundle"
        + " needing no migration\n"
    )
    sys.exit(1)

MODES = ("check", "plan", "apply")

# Reserved OKF filenames (§3.1) — never concepts, at any level.
RESERVED = ("index.md", "log.md")

# The version pin lives in the VALIDATOR's thresholds.yml, which is the single
# source for the whole toolset. adopt-bundle stamps it into the index.md it
# writes, so a second copy here would let this engine create a bundle the
# validator immediately reports as drifted. Same rule as ruff's required-version
# (CLAUDE.md § "The ruff version is pinned in exactly one place").
VALIDATOR_DIR = os.path.join(os.path.dirname(_HERE), "check-okf-conformance")


# NOT named read_lines: this module IMPORTS transforms.read_lines at the top,
# and a same-named local would SHADOW it for the apply path below (which relies
# on the transforms version swallowing OSError and returning []). Measured --
# the shadow made an unreadable file RAISE where it used to yield no edits.
def _read_config_lines(path: str) -> list[str]:
    r"""PATH's lines under grep's line model: split on `\n` ONLY (#980).

    `newline=""` disables universal-newline translation. Without it a lone `\r`
    is rewritten to `\n` by read() BEFORE any split can see it, so even
    `.split("\n")` reports two lines where `grep -n` reports one -- and the bash
    twin reaches every line through grep. str.splitlines(), which this replaced,
    additionally splits on `\x0b`, `\x0c`, `\x1c`-`\x1e` and U+2028/2029, none of
    which grep treats as a separator. The trailing empty from a final newline is
    dropped so the count matches `grep -n` at both ends.

    Raises OSError on an unreadable path; each caller keeps its own fallback.
    """
    with open(path, "r", encoding="utf-8", errors="replace", newline="") as fh:
        lines = fh.read().split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines


def fail(message: str, code: int = 1) -> int:
    """Print an actionable TOOL-side error and return the non-zero code."""
    sys.stderr.write("ERROR: " + message + "\n")
    return code


def usage() -> int:
    sys.stderr.write(
        "Usage: migrate.py [check|plan|apply] [--transform NAME] [--confirm]\n"
        "                  [--allow-dirty]\n"
        "\n"
        "  check   report what needs migrating (default, read-only)\n"
        "  plan    render the change set for review (read-only)\n"
        "  apply   execute the plan (requires --confirm)\n"
    )
    return 1


def bundle_root() -> str:
    """The configured bundle root, normalized for matching.

    Resolution order and normalization are IDENTICAL to the validator's
    bundle_root() (check-okf-conformance/patterns.py) — the two tools must agree
    about which files are bundle files, or this engine migrates one set and the
    validator grades another. An empty value means no bundle is configured.
    """
    root = os.environ.get("OKF_BUNDLE_ROOT")
    if root is None:
        root = os.environ.get("MEMORY_BUNDLE_ROOT", ".claude/memory")
    root = root.strip()
    while root.startswith("./"):
        root = root[2:]
    while root.endswith("/"):
        root = root[:-1]
    return root


def read_index_names() -> list[str]:
    """The configured index basenames, from the VALIDATOR's own resolver.

    Delegated rather than reimplemented, for the same reason the version pin is:
    that file is the single source for the whole toolset, and a second copy here
    would let the two halves disagree about what an index IS — which decides
    both what the `index:` taxonomy source can route by and which files may
    relocate an index line. It also inherits `$OKF_INDEX_NAMES` and the
    empty-override semantics for free.

    $OKF_INDEX_NAMES IS READ HERE TOO, not only inside the validator, so the
    override still works when that import is unavailable. Without it the
    fallback returned librarian's own defaults and the env var was SILENTLY
    IGNORED — a consuming repo whose index is `catalog.md` got "nothing to move"
    at exit 0, which is the wrong-answer-quietly shape rather than a refusal.

    THE sys.path INSERT IS LOAD-BEARING: the validator is a sibling skill
    directory, not an installed package, so without it the import fails in the
    CLI (it only succeeded under a test harness that had already inserted the
    path). read_pinned_version does the same thing for the same reason.
    """
    env = os.environ.get("OKF_INDEX_NAMES")
    if env is not None:
        return env.split()
    if VALIDATOR_DIR not in sys.path:
        sys.path.insert(0, VALIDATOR_DIR)
    try:
        from patterns import read_index_names as validator_names  # noqa: PLC0415

        got = validator_names(os.path.join(VALIDATOR_DIR, "thresholds.yml"))
        if got:
            return got
    except (ImportError, AttributeError):
        pass
    return ["MEMORY.md", "index.md", "index-*.md"]


def read_pinned_version() -> str:
    """The toolset's pinned OKF version, or "" when unresolvable.

    Reads $OKF_PINNED_VERSION then the VALIDATOR's thresholds.yml. Importing the
    validator's own reader rather than reimplementing the parse: two parsers over
    one config is two things to drift, which is the whole argument for a single
    pin. Falls back to a local read only if that import is unavailable.
    """
    env = os.environ.get("OKF_PINNED_VERSION", "").strip()
    if env:
        return env
    if VALIDATOR_DIR not in sys.path:
        sys.path.insert(0, VALIDATOR_DIR)
    try:
        from patterns import read_pinned_version as validator_read  # noqa: PLC0415

        return validator_read(os.path.join(VALIDATOR_DIR, "thresholds.yml"))
    except ImportError:
        return ""


def _thresholds_path() -> str:
    """thresholds.yml beside THIS file — resolved from the module location, not
    $PWD, so the tool works from any working directory.

    $OKF_MIGRATE_CONFIG_DIR overrides the directory, for the same reason
    $OKF_BUNDLE_ROOT exists: a tool that runs against SOMEONE ELSE'S bundle must
    be able to take its config from somewhere other than its own install dir.
    It is also what lets a fixture exercise a configured taxonomy without
    editing the shipped file.
    """
    return os.path.join(
        os.environ.get("OKF_MIGRATE_CONFIG_DIR") or _HERE, "thresholds.yml"
    )


def read_config_list(path: str, section: str, key: str) -> list[str]:
    """The `- item` list under `<section>.<key>` in a thresholds.yml.

    The same tiny two-level parse the validator's read_config_list uses, for the
    same reason: a full YAML parser is a much larger surface for the bash and
    python halves to disagree across, and these files' shape is fixed. The
    top-level test is `line[0]` not being whitespace, matching the bash twin's
    glob rather than str.isalpha(), which is Unicode-aware where a glob is not
    (the #686 divergence).
    """
    try:
        lines = _read_config_lines(path)
    except OSError:
        return []
    in_section = False
    in_key = False
    out: list[str] = []
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if not line[0].isspace():
            in_section = stripped.startswith(section + ":")
            in_key = False
            continue
        if not in_section:
            continue
        if stripped.startswith("- "):
            if in_key:
                item = stripped[2:]
                hash_at = item.find(" #")
                if hash_at >= 0:
                    item = item[:hash_at]
                out.append(strip_quotes(item.strip()))
            continue
        in_key = stripped.startswith(key + ":")
    return out


def read_config_scalar(path: str, section: str, key: str, default: str) -> str:
    """The scalar `<section>.<key>` in a thresholds.yml, or DEFAULT."""
    try:
        lines = _read_config_lines(path)
    except OSError:
        return default
    in_section = False
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if not line[0].isspace():
            in_section = stripped.startswith(section + ":")
            continue
        if not in_section or not stripped.startswith(key + ":"):
            continue
        val = stripped[len(key) + 1 :]
        hash_at = val.find("#")
        if hash_at >= 0:
            val = val[:hash_at]
        val = strip_quotes(val.strip())
        return val if val else default
    return default


def collect_bundle(root: str) -> tuple[list[str], list[str]]:
    """(concepts, all_markdown) under ROOT.

    A concept is any `.md` that is not a reserved OKF filename. Non-markdown
    files inside a bundle are code or data, not concepts, and are ignored — the
    same exclusion the validator applies.

    SYMLINKS ARE SKIPPED, and this is a SAFETY boundary, not tidiness. `os.walk`
    lists a symlink-to-a-file among `filenames` (it only declines to *descend*
    symlinked directories), and `open(path, "w")` follows it — so a `.md`
    symlink inside the bundle made `apply` write through to wherever it pointed,
    including outside the bundle root and outside the repo. Measured: a bundle
    containing `feedback/lesson.md -> ../../../outside/target.md` had
    `backfill-type` rewrite `outside/target.md`, while the plan displayed only
    the in-bundle path — so the reviewed plan and the actual write target were
    different files, which is exactly the guarantee "the plan is the write
    allowlist" claims to provide.
    That matters because this tool's whole premise is running against SOMEONE
    ELSE'S bundle — content the operator did not author line by line.

    It is also a parity break: `find -type f` in the bash twin never matched a
    symlink (its type is `l`), so the two runtimes disagreed about the bundle's
    membership. Skipping in both is what makes them agree again.

    DOT-DIRECTORIES ARE PRUNED in both runtimes for the same reason — a
    `.attic/` of scratch markdown under the bundle root is not part of the
    bundle, and only this impl was skipping it.
    """
    concepts: list[str] = []
    every: list[str] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [
            d
            for d in dirnames
            if not d.startswith(".") and not os.path.islink(os.path.join(dirpath, d))
        ]
        for name in filenames:
            if not name.endswith(".md"):
                continue
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                continue
            every.append(full)
            if name not in RESERVED:
                concepts.append(full)
    return (sorted(concepts), sorted(every))


def tree_is_dirty(root: str) -> tuple[bool, str]:
    """(dirty, detail) for the git tree containing ROOT.

    A NON-REPO IS NOT DIRTY. This tool migrates any repo's bundle, including a
    plain directory that is not under version control at all, and refusing there
    would make the safety gate a portability bug. The gate exists so an applied
    change is reviewable as a diff; where there is no git there is no diff to
    muddy.

    `-C <root>` IS LOAD-BEARING: git is run inside the BUNDLE's directory, not
    the caller's. Without it the status is taken in whatever repo the process
    happens to sit in, so a bundle passed as an absolute path elsewhere is
    checked against the WRONG tree — and when that path lies outside the current
    repo, git errors, the error reads as "not a repo", and the gate silently
    passes a genuinely dirty bundle. Measured: the gate reported clean for a
    dirty fixture bundle whenever the caller's cwd was a different repository,
    which is the normal case for a tool whose whole purpose is running against
    someone else's bundle.
    """
    try:
        proc = subprocess.run(
            ["git", "-C", root, "status", "--porcelain", "--", "."],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return (False, "")
    if proc.returncode != 0:
        return (False, "")
    out = proc.stdout.strip()
    return (bool(out), out)


def build_plan(
    root: str, version: str
) -> tuple[list[Edit], list[Ambiguity], list[str]]:
    """(edits, ambiguities, plan_only_notes) for the whole bundle.

    Every transform runs; the caller filters by --transform. Running them all
    unconditionally is what makes `check` a complete picture rather than a view
    of whichever transform was asked about.
    """
    cfg = _thresholds_path()
    concepts, every = collect_bundle(root)

    applicable = read_config_list(cfg, "transforms", "applicable")
    plan_only = read_config_list(cfg, "transforms", "plan_only")
    rules = parse_type_rules(read_config_list(cfg, "type_inference", "rules"))
    known = read_config_list(cfg, "type_inference", "known_types")
    form = read_config_scalar(cfg, "links", "form", "bundle_relative")
    convert_unresolvable = (
        read_config_scalar(cfg, "links", "convert_unresolvable", "true") != "false"
    )
    title = read_config_scalar(cfg, "adopt", "title", "Memory Bundle")
    taxonomy = parse_taxonomy_rules(read_config_list(cfg, "taxonomy", "rules"))
    index_names = read_index_names()

    edits: list[Edit] = []
    ambiguities: list[Ambiguity] = []

    if "adopt-bundle" in applicable:
        edits.extend(adopt_bundle(root, concepts, version, title))
    if "backfill-type" in applicable:
        type_edits, type_ambiguities = backfill_type(root, concepts, rules, known)
        edits.extend(type_edits)
        ambiguities.extend(type_ambiguities)
    if "wikilink-convert" in applicable:
        edits.extend(convert_wikilinks(root, every, form, convert_unresolvable))
    if "move-concept" in applicable:
        # The link rewrites are derived from the SAME mapping the moves are, so
        # the two cannot disagree about where a file lands. Apply ordering (link
        # rewrites before renames) is the driver's job — see apply_edits.
        move_edits, mapping = plan_moves(root, concepts, every, taxonomy, index_names)
        # §8 ORDER: build each new directory's index first, because it CLAIMS the
        # index lines that named the moved concepts. The inbound rewriter then
        # repoints those claimed lines at the sub-index rather than at the
        # concept — naming the concept in both places would be memory-multi-index.
        index_edits, relocated = plan_directory_indexes(root, every, mapping)
        edits.extend(index_edits)
        edits.extend(
            rewrite_inbound_links(root, every, mapping, relocated, index_names)
        )
        edits.extend(move_edits)

    # PLAN-ONLY TRANSFORMS are surfaced as notes rather than silently omitted.
    # Each executes a judgment made elsewhere — split-index needs a chosen seam
    # (#663's finder emits recommendations), confirmed-merge needs slice C's
    # human confirmation — so the engine renders what it would do and refuses to
    # do it. Silence here would read as "nothing to migrate", which is the
    # silence-is-a-pass shape this repo keeps filing issues about.
    notes = [
        name + ": plan-only — requires a human decision this engine did not make"
        for name in plan_only
    ]
    return (edits, ambiguities, notes)


def render_check(
    edits: list[Edit], ambiguities: list[Ambiguity], notes: list[str]
) -> None:
    """A per-transform summary — what would change, without the change itself."""
    counts: dict[str, int] = {}
    files: dict[str, set] = {}
    for edit in edits:
        counts[edit.transform] = counts.get(edit.transform, 0) + 1
        files.setdefault(edit.transform, set()).add(edit.path)
    for name in sorted(counts):
        sys.stdout.write(
            "%-18s %4d file(s)  %4d edit(s)  [applicable]\n"
            % (name, len(files[name]), counts[name])
        )
    for note in notes:
        sys.stdout.write(note + "\n")
    for amb in ambiguities:
        sys.stdout.write(
            "AMBIGUOUS  "
            + amb.path
            + "  "
            + amb.reason
            + "  candidates: "
            + (", ".join(amb.candidates) if amb.candidates else "(none)")
            + "\n"
        )
    if not counts and not ambiguities:
        sys.stdout.write("bundle needs no mechanized migration\n")


def render_plan(
    edits: list[Edit], ambiguities: list[Ambiguity], notes: list[str]
) -> None:
    """The full change set as a unified-diff-shaped preview.

    THIS IS THE REVIEWABLE ARTIFACT (AC2) — every file, every edit, before
    anything is touched. It is also the WRITE ALLOWLIST: apply writes only paths
    that appear here.
    """
    by_file: dict[str, list[Edit]] = {}
    for edit in edits:
        by_file.setdefault(edit.path, []).append(edit)
    for path in sorted(by_file):
        sys.stdout.write("--- a/" + path + "\n+++ b/" + path + "\n")
        for edit in sorted(by_file[path], key=lambda e: e.line):
            sys.stdout.write("@@ " + edit.transform + ": " + edit.note + " @@\n")
            if edit.kind == "move":
                # RENDERED AS A RENAME HEADER, not as a +/- line pair. A move
                # changes no bytes, so showing it as content would misrepresent
                # what apply does — and the destination is the single fact a
                # reviewer is approving here.
                sys.stdout.write(
                    "rename from " + edit.old + "\nrename to " + edit.new + "\n"
                )
                continue
            if edit.kind == "create":
                for line in edit.new.splitlines():
                    sys.stdout.write("+" + line + "\n")
                continue
            if edit.old:
                sys.stdout.write("-" + edit.old + "\n")
            # An insert-block renders as SEVERAL `+` lines: the plan is the
            # reviewable artifact AND the write allowlist, so it must show the
            # lines that will actually be written.
            pieces = edit.new.split("\n") if edit.kind == "insert-block" else [edit.new]
            for piece in pieces:
                sys.stdout.write("+" + piece + "\n")
    for note in notes:
        sys.stdout.write("# " + note + "\n")
    for amb in ambiguities:
        sys.stdout.write(
            "# AMBIGUOUS "
            + amb.path
            + ": "
            + amb.reason
            + " — choose one of: "
            + (", ".join(amb.candidates) if amb.candidates else "(none offered)")
            + "\n"
        )


def under_root(path: str, root: str) -> bool:
    """True when PATH resolves to a location inside ROOT.

    RESOLVED, not lexical: `os.path.realpath` expands every symlink in the path,
    which is the point — a lexically-fine `<root>/x.md` that is a symlink to
    `/etc/x` is not inside the bundle in any sense that matters to a writer.

    `os.path.realpath` rather than the GNU-only `realpath -m` its bash twin
    cannot use; the twin's own note records that trap (#932).
    """
    real_root = os.path.realpath(root)
    real_path = os.path.realpath(path)
    return real_path == real_root or real_path.startswith(real_root + os.sep)


def apply_edits(edits: list[Edit], allowlist: set, root: str) -> int:
    """Write EDITS, refusing any path not in ALLOWLIST or not under ROOT.

    THE ALLOWLIST IS THE PLAN (AC7). A transform that discovered a new file
    between plan and apply is a bug, not a permitted widening, so the refusal is
    a hard error rather than a skip: silently writing more than was reviewed is
    exactly what the plan/apply split exists to prevent.

    THE ROOT CHECK IS THE SECOND, INDEPENDENT HALF, and it is the one that can
    actually fail. The allowlist is derived from these same edits by the caller,
    so on its own it is a tautology — it documents the contract without
    enforcing it. The resolved-root check enforces a claim the caller cannot
    launder: whatever a transform nominated, a write that would land outside the
    bundle is refused. Both are kept: the allowlist states the contract at the
    boundary a future caller might pass a wider set through, the root check
    holds the line today.

    Edits are applied per file, highest line first, so an insert cannot shift
    the line numbers of edits not yet applied.
    """
    # PRE-FLIGHT: EVERY edit is validated before ANY of them is written.
    #
    # "Partial application is not a thing" (contract.md) is a claim about the
    # whole apply, and a check that runs when its own edit's turn comes cannot
    # make it. move-concept is what forced this: renames run LAST (a link rewrite
    # must read the file at its old path), so a destination check inside the
    # rename loop fired only after every link rewrite had already been written to
    # disk. Measured: a taxonomy rule spelled `= ../../../escaped` exited 2 with
    # the right message and left the bundle's links rewritten to point outside
    # it — a refusal that had already done most of the damage.
    for edit in edits:
        # Resolved through the nearest EXISTING ancestor: move-concept creates
        # `<root>/<dir>/index.md` for a directory that does not exist yet, so
        # requiring the path itself to resolve would refuse a legitimate
        # in-bundle create. Still fail-closed — an escaping path resolves
        # outside the root no matter how much of it exists.
        anchor = edit.path
        while anchor != root and not os.path.exists(anchor):
            parent = os.path.dirname(anchor)
            if not parent or parent == anchor:
                break
            anchor = parent
        if not under_root(anchor, root):
            return fail(
                "apply refused: "
                + edit.path
                + " resolves outside the bundle root "
                + root
                + " — refusing to write through it",
                2,
            )
        if edit.path not in allowlist:
            return fail(
                "apply refused: " + edit.path + " is not in the reviewed plan", 2
            )
        if edit.kind != "move":
            continue
        # THE DESTINATION IS THE NEW SURFACE A MOVE INTRODUCES — every other
        # transform only ever writes a path that already existed in the bundle.
        # It is where a taxonomy rule spelled `= ../../etc` would aim, so it is
        # resolved through its nearest EXISTING ancestor (the directory itself
        # need not exist yet) and required to land under the root.
        probe = os.path.dirname(os.path.join(root, edit.new)) or root
        while probe != root and not os.path.isdir(probe):
            parent = os.path.dirname(probe) or root
            if parent == probe:
                break
            probe = parent
        if not under_root(probe, root):
            return fail(
                "apply refused: "
                + edit.new
                + " resolves outside the bundle root "
                + root
                + " — refusing to move through it",
                2,
            )

    by_file: dict[str, list[Edit]] = {}
    moves: list[Edit] = []
    for edit in edits:
        if edit.kind == "move":
            moves.append(edit)
            continue
        by_file.setdefault(edit.path, []).append(edit)

    for path in sorted(by_file):
        group = by_file[path]
        creates = [e for e in group if e.kind == "create"]
        if creates:
            os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(creates[0].new)
            continue
        lines = read_lines(path)
        for edit in sorted(group, key=lambda e: e.line, reverse=True):
            idx = edit.line - 1
            if edit.kind == "replace-line":
                if 0 <= idx < len(lines):
                    lines[idx] = edit.new
            elif edit.kind == "insert-line":
                lines.insert(min(max(idx, 0), len(lines)), edit.new)
            elif edit.kind == "insert-block":
                # SEVERAL lines as ONE edit. move-concept appends a whole ordered
                # block this way because N separate appends interleave — edits
                # apply highest-line-first against a growing list, so len+1,
                # len+2, len+3 do not land in that order. The distinct KIND (not
                # a payload convention) is what keeps a line whose content holds
                # the two characters `\n` from being split.
                at = min(max(idx, 0), len(lines))
                for offset, piece in enumerate(edit.new.split("\n")):
                    lines.insert(at + offset, piece)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")

    # RENAMES RUN LAST, after every link rewrite. A rewrite reads the file at
    # its OLD path, so renaming first would leave those edits pointed at a path
    # that no longer exists — the edits would silently no-op and every inbound
    # link would be left dangling, which is the exact failure this transform
    # exists to prevent.
    return apply_moves(moves, root)


def apply_moves(moves: list[Edit], root: str) -> int:
    """Rename each moved concept, preserving git history where there is any.

    `git mv` RATHER THAN delete+create (AC7), because the history is the reason
    a memory can be trusted: `git log --follow` on a relocated concept must still
    reach the commit that explains why it was written. A delete+create severs
    that at exactly the moment the file becomes hardest to place.

    A NON-REPO FALLS BACK TO os.rename, the same line tree_is_dirty draws: this
    tool migrates any repo's bundle including a plain directory under no version
    control, and refusing there would make a history guarantee into a
    portability bug. A `git mv` that fails for any other reason also falls back —
    the move is the contract, the history is the bonus.
    """
    for edit in sorted(moves, key=lambda e: e.old):
        src = edit.path
        dest = os.path.join(root, edit.new)
        if not os.path.exists(src):
            continue
        os.makedirs(os.path.dirname(dest) or root, exist_ok=True)
        moved = False
        try:
            proc = subprocess.run(
                ["git", "-C", root, "mv", "--", edit.old, edit.new],
                capture_output=True,
                text=True,
                check=False,
            )
            moved = proc.returncode == 0
        except OSError:
            moved = False
        if not moved:
            os.rename(src, dest)
    return 0


def main(argv: list[str]) -> int:
    mode = "check"
    transform = ""
    confirm = False
    allow_dirty = False

    args = argv[1:]
    if args and not args[0].startswith("-"):
        mode = args[0]
        args = args[1:]
        if mode not in MODES:
            sys.stderr.write("ERROR: unknown mode: " + mode + "\n")
            return usage()

    idx = 0
    while idx < len(args):
        arg = args[idx]
        if arg == "--transform":
            idx += 1
            if idx >= len(args):
                return fail("--transform requires a value")
            transform = args[idx]
        elif arg == "--confirm":
            confirm = True
        elif arg == "--allow-dirty":
            allow_dirty = True
        elif arg in ("-h", "--help"):
            usage()
            return 0
        else:
            sys.stderr.write("ERROR: unknown argument: " + arg + "\n")
            return usage()
        idx += 1

    root = bundle_root()
    if not root:
        # No bundle configured is not an error: "nothing to migrate" is exit 0,
        # the same posture the validator takes.
        return 0
    if not os.path.isdir(root):
        return 0

    version = read_pinned_version()
    if not version:
        return fail(
            "no OKF version pin — set OKF_PINNED_VERSION or provide"
            " `okf.pinned_version` in check-okf-conformance/thresholds.yml."
            " adopt-bundle stamps that version into the index.md it writes, so"
            " without it this engine would create a bundle it cannot declare."
        )

    cfg = _thresholds_path()
    plan_only = read_config_list(cfg, "transforms", "plan_only")
    if transform and transform in plan_only:
        if mode == "apply":
            return fail(
                "apply refused: '" + transform + "' is plan-only — it executes a"
                " decision this engine did not make. Review its plan output and"
                " apply the chosen change yourself.",
                2,
            )

    edits, ambiguities, notes = build_plan(root, version)
    if transform:
        edits = [e for e in edits if e.transform == transform]
        if transform != "backfill-type":
            ambiguities = []

    if mode == "check":
        render_check(edits, ambiguities, notes)
        return 0
    if mode == "plan":
        render_plan(edits, ambiguities, notes)
        return 0

    # --- apply -------------------------------------------------------------
    if not confirm:
        return fail(
            "apply requires --confirm. Run `plan` first and review the diff;"
            " apply writes only what that plan listed.",
            2,
        )
    if ambiguities:
        sys.stderr.write(
            "ERROR: apply blocked: "
            + str(len(ambiguities))
            + " file(s) need a human choice. Nothing was written.\n"
        )
        for amb in ambiguities:
            sys.stderr.write(
                "  "
                + amb.path
                + ": "
                + amb.reason
                + " — candidates: "
                + (", ".join(amb.candidates) if amb.candidates else "(none)")
                + "\n"
            )
        return 3
    if not allow_dirty:
        dirty, detail = tree_is_dirty(root)
        if dirty:
            sys.stderr.write(
                "ERROR: apply refused: the bundle has uncommitted changes."
                " Commit or stash them so the migration is reviewable as its own"
                " diff, or pass --allow-dirty.\n" + detail + "\n"
            )
            return 2
    if not edits:
        return 0
    return apply_edits(edits, {e.path for e in edits}, root)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
