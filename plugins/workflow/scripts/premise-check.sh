#!/usr/bin/env bash
# premise-check.sh — check an escalation option's PREMISE before the operator
# sees it (issue #911).
#
# THE DEFECT. A golem's escalation builds its options from the issue body plus
# its own worktree, and from nothing else. Nothing consults the backlog or the
# decisions the issue and repo already recorded, so an option can be premised on
# something being absent when it is already filed, already closed, or already
# merged. Observed FOUR times in one orchestration session (2026-09-03/04):
#
#   #707  "file the split as its own issue"  -> already filed as #859
#   #860  all four options assumed the split did not exist
#                                           -> #859 had merged in PR #905
#   #550  four options on `clean` semantics -> all four dropped the issue's own
#                                              stated constraint
#   #551  four options on the swamp gate    -> none mentioned the baseline entry
#                                              pinning the file
#
# The first two are a stale view of WHAT EXISTS; the second two a stale view of
# WHAT WAS ALREADY DECIDED. Both hand the operator a decision whose premise is
# false, and the golem cannot see it.
#
# WHY THE EXISTING DEDUPE DOES NOT COVER THIS. agents/issue-filer.md already
# dedupes, and that guard works. But the swamp gate never reaches it:
# plan-sizing.md offers "file the decomposition separately" as an OPTION TO THE
# OPERATOR, and the operator's answer is what decides. The dedupe sits one layer
# BELOW the decision, so a human is asked to approve creating the duplicate
# before anything can catch it. This script moves the check ABOVE the decision —
# and, because issue-filer.md now calls it too, there is exactly ONE dedupe query
# in the repo rather than a second copy (acceptance criterion 3).
#
# Subcommands (emit `key=value` lines to stdout):
#
#   exists --title "<text>" [--platform github|gitlab]
#       Is work matching <title> already tracked?
#         verdict=open        an OPEN issue matches   -> caller REWRITES the
#                             option to reference it ("#859 already tracks this")
#         verdict=closed      a CLOSED issue matches  -> caller REMOVES the
#                             option; the work is done (the #860 case)
#         verdict=absent      nothing matches         -> option stands as written
#         verdict=unavailable the check DID NOT RUN   -> caller must say so
#       plus issue=<N> / url=<url> on open|closed, reason=<text> on unavailable.
#
#   constraints --issue <N> [--platform github|gitlab]
#       Extract constraint statements from the issue's own body, so an option
#       cannot silently contradict one (the #550 case).
#         verdict=found|none|unavailable, plus one constraint=<text> line each.
#
# THREE VERDICTS FOR `exists`, NOT TWO. A closed hit and an open hit call for
# DIFFERENT actions — remove the option versus rewrite it — so collapsing them
# into a boolean "found" loses exactly the distinction #911 turns on. #860 is the
# closed case, and it is the one that would have suspended a lane behind work
# that had already merged.
#
# `unavailable` IS NOT `absent`. This is the whole of acceptance criterion 5 and
# the reason this script fails toward asking. When `gh` is missing or the query
# errors, a two-state result would report "nothing exists" — which reads as
# permission to file, on no evidence at all. The precedent is
# tracks-runbook.sh:490 ("staleness: NOT CHECKED (gh unavailable)"), whose own
# header (:39) states the rule this follows: say the check did not run rather
# than rendering as if fresh. A caller that cannot tell the two apart will
# eventually treat an outage as an all-clear.
#
# Runtime policy: bash-3.2 clean (no declare -A / mapfile / namerefs / ${v,,} /
# ;;&), BSD-clean regex ([[:space:]] and -E, never \s or grep -P), coreutils via
# the `command` builtin and the `_bin` fallback (#443), `set -uo pipefail` with
# errors handled per call (never `-e`). See CLAUDE.md § Key conventions.
#
# Runtime: bash-only, no Python port — the precedent for scripts/ helpers is
# threshold-check.sh, golem-inbox.sh and recover-journal-partials.sh. The
# python-primary rule scopes to the patterns.sh pre-scan family.
set -uo pipefail

# --- Portable tool resolution (#443) ----------------------------------------
# Mirrors golem-inbox.sh: honor PATH first (the `command -v` builtin needs no
# external binary), then scan standard bin dirs so this still resolves under a
# stripped PATH, then yield the bare name. Candidates are bare DIRECTORIES, not
# /usr/bin/<tool> literals, so the #443 lint does not flag them.
_BIN_CANDIDATE_DIRS="/usr/bin /bin /usr/local/bin /opt/homebrew/bin /sbin /usr/sbin"
_bin() {
    _br="$(command -v "$1" 2>/dev/null || true)"
    if [ -z "$_br" ]; then
        for _bd in $_BIN_CANDIDATE_DIRS; do
            [ -x "$_bd/$1" ] && {
                _br="$_bd/$1"
                break
            }
        done
    fi
    printf '%s' "${_br:-$1}"
}
GREP="$(_bin grep)"
SED="$(_bin sed)"
TR="$(_bin tr)"
HEAD="$(_bin head)"

usage() {
    command cat >&2 <<'EOF'
usage: premise-check.sh <subcommand> [args]

  exists      --title "<text>" [--platform github|gitlab]
      Is work matching <title> already tracked?
      -> verdict=open|closed|absent|unavailable [issue= url= reason=]

  constraints --issue <N> [--platform github|gitlab]
      Extract constraint statements from the issue body.
      -> verdict=found|none|unavailable, constraint=<text> per match

Exit codes: 0 success (any verdict, INCLUDING unavailable — it is a result,
not an error), 2 usage error.
EOF
    return 0
}

# die <message> — fail loud: actionable message + usage on stderr, exit 2.
die() {
    command printf '%s\n' "$1" >&2
    usage
    exit 2
}

# --- platform detection -----------------------------------------------------

# detect_platform — echo github|gitlab from the origin remote, defaulting to
# github when the remote is unreadable. Same table as next-issue/SKILL.md
# § Platform Detection; kept in sync by reading the remote rather than a config.
detect_platform() {
    _dp_remote="$(command git remote get-url origin 2>/dev/null || true)"
    case "$_dp_remote" in
        *github.com* | *ghe.*) command echo "github" ;;
        *gitlab.com* | *gitlab.*) command echo "gitlab" ;;
        *) command echo "github" ;;
    esac
}

# platform_cli <platform> — echo the CLI binary name for a platform.
platform_cli() {
    case "$1" in
        gitlab) command echo "glab" ;;
        *) command echo "gh" ;;
    esac
}

# emit_unavailable <reason> — the fail-toward-asking result. Printed whenever the
# check could not actually run, so a caller can never mistake an outage for an
# all-clear. Exits 0: "the check did not run" is a legitimate answer to report to
# the operator, not a script failure, and a non-zero here would tempt a caller
# into `|| true`, which collapses it back into silence.
emit_unavailable() {
    command printf 'verdict=unavailable\n'
    command printf 'reason=%s\n' "$1"
    exit 0
}

# --- search-term extraction -------------------------------------------------

# search_terms <title> — reduce a title to conservative search keywords.
#
# CONSERVATIVE BY DESIGN, per issue-filer.md's own rule ("use conservative
# matching (title keywords) to avoid false negatives"). The asymmetry is
# deliberate: a false NEGATIVE here re-creates the #860 defect (a duplicate
# reaches the operator as offered), while a false POSITIVE only makes the option
# text mention a related issue the operator can dismiss at a glance. So err
# toward matching.
#
# Punctuation becomes spaces, then single-character tokens are dropped — they
# carry no signal and, as `gh --search` terms, would match nearly everything.
#
# ONE character, not "short": the cut is deliberately the least aggressive one
# that still removes noise, because dropping a token is the direction that
# creates FALSE NEGATIVES, and a false negative here is the #860 defect. Real
# titles carry meaning in two-letter tokens (an issue number's `gh`, a `CI`, a
# `PR`), so a longer minimum would start discarding signal to save nothing.
#
# Tokenized in a `for` loop rather than by a `sed` substitution: a single global
# pass CANNOT do this correctly, because adjacent single-character tokens share
# the space the pattern consumes, so `a b c split` would keep `b`. A per-token
# test has no such adjacency to get wrong.
search_terms() {
    _st_out=""
    for _st_tok in $(command printf '%s' "$1" | "$TR" -c '[:alnum:]' ' '); do
        # Drop one-character tokens; keep everything else in order.
        case "$_st_tok" in
            ?) continue ;;
        esac
        if [ -z "$_st_out" ]; then
            _st_out="$_st_tok"
        else
            _st_out="$_st_out $_st_tok"
        fi
    done
    command printf '%s' "$_st_out"
}

# --- exists -----------------------------------------------------------------

cmd_exists() {
    _ex_title=""
    _ex_platform=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --title)
                shift
                _ex_title="${1:-}"
                ;;
            --platform)
                shift
                _ex_platform="${1:-}"
                ;;
            *) die "premise-check exists: unknown argument '$1'" ;;
        esac
        shift
    done

    [ -z "$_ex_title" ] && die "premise-check exists: --title is required"

    if [ -z "$_ex_platform" ]; then
        _ex_platform="$(detect_platform)"
    fi
    case "$_ex_platform" in
        github | gitlab) ;;
        *) die "premise-check exists: --platform must be github or gitlab, got '$_ex_platform'" ;;
    esac

    _ex_cli="$(platform_cli "$_ex_platform")"
    command -v "$_ex_cli" >/dev/null 2>&1 ||
        emit_unavailable "$_ex_cli not found on PATH — existence check did not run"

    _ex_terms="$(search_terms "$_ex_title")"
    [ -z "$_ex_terms" ] &&
        emit_unavailable "title yielded no searchable keywords — existence check did not run"

    # Query BOTH states in one call. Ordering matters to the caller, so the
    # verdict below prefers an open match: an open issue is actionable
    # (reference it), while a closed one only removes the option.
    if [ "$_ex_platform" = "github" ]; then
        _ex_raw="$(command gh issue list --state all --search "$_ex_terms" \
            --limit 20 --json number,title,state,url 2>/dev/null)"
        _ex_rc=$?
    else
        _ex_raw="$(command glab issue list --all --search "$_ex_terms" \
            --output json 2>/dev/null)"
        _ex_rc=$?
    fi

    # A failed query is NOT "nothing found". Both a non-zero status and empty
    # output mean the check did not produce an answer we can stand behind.
    [ "$_ex_rc" -ne 0 ] &&
        emit_unavailable "$_ex_cli query failed (exit $_ex_rc) — existence check did not run"
    [ -z "$_ex_raw" ] &&
        emit_unavailable "$_ex_cli returned no output — existence check did not run"

    parse_and_emit_match "$_ex_raw"
}

# parse_and_emit_match <json> — print the verdict for a search result payload.
#
# Parsed WITHOUT jq. jq is optional in this repo (golem-inbox.sh carries a no-jq
# fallback and its suite tests that path), and an existence check that silently
# degraded on a jq-less host would be the very silence this script exists to
# remove. The records are flat and machine-generated, so a line-oriented parse is
# sufficient and has no dependency to lose.
parse_and_emit_match() {
    _pm_json="$1"

    # One record per line, then pick the first open match, else the first closed
    # one. Both CLIs emit lowercase-ish state strings ("OPEN"/"opened"/"closed"),
    # so normalize before comparing.
    #
    # ANCHORED ON THE RECORD-START KEY, not a bare `},{`. A textual split has no
    # idea what is inside a JSON string, and an issue TITLE may legitimately
    # contain `}, {` — `config: {a}, {b} refactor` is enough. A bare split fires
    # mid-title, cutting one record into two fragments, and the per-line field
    # extraction then reads a number from one fragment and a state from another.
    # Measured on exactly that title: an OPEN record reported `verdict=closed`
    # from the NEXT record's fields, which inverts the caller's action (remove
    # the option instead of referencing the open issue) — the open/closed
    # distinction #911 turns on, lost in the parser.
    #
    # Every record from either CLI begins with "number" (gh) or "iid" (glab), so
    # requiring one of those immediately after the brace makes the split match
    # structure rather than punctuation. A title would have to contain the full
    # `}, {"number":` to collide, which is no longer a plausible accident.
    _pm_records="$(command printf '%s' "$_pm_json" |
        "$SED" -E -e 's/\},[[:space:]]*\{"(number|iid)"/}\
{"\1"/g')"

    _pm_open_num=""
    _pm_open_url=""
    _pm_closed_num=""
    _pm_closed_url=""

    while IFS= read -r _pm_line; do
        [ -z "$_pm_line" ] && continue

        _pm_num="$(command printf '%s' "$_pm_line" |
            "$SED" -n -E -e 's/.*"(number|iid)"[[:space:]]*:[[:space:]]*([0-9]+).*/\2/p' |
            "$HEAD" -1)"
        [ -z "$_pm_num" ] && continue

        _pm_state="$(command printf '%s' "$_pm_line" |
            "$SED" -n -e 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
            "$HEAD" -1 | "$TR" '[:upper:]' '[:lower:]')"

        _pm_url="$(command printf '%s' "$_pm_line" |
            "$SED" -n -E -e 's/.*"(url|web_url)"[[:space:]]*:[[:space:]]*"([^"]*)".*/\2/p' |
            "$HEAD" -1)"

        case "$_pm_state" in
            open | opened)
                if [ -z "$_pm_open_num" ]; then
                    _pm_open_num="$_pm_num"
                    _pm_open_url="$_pm_url"
                fi
                ;;
            closed | merged)
                if [ -z "$_pm_closed_num" ]; then
                    _pm_closed_num="$_pm_num"
                    _pm_closed_url="$_pm_url"
                fi
                ;;
        esac
    done <<EOF
$_pm_records
EOF

    if [ -n "$_pm_open_num" ]; then
        command printf 'verdict=open\n'
        command printf 'issue=%s\n' "$_pm_open_num"
        [ -n "$_pm_open_url" ] && command printf 'url=%s\n' "$_pm_open_url"
        return 0
    fi
    if [ -n "$_pm_closed_num" ]; then
        command printf 'verdict=closed\n'
        command printf 'issue=%s\n' "$_pm_closed_num"
        [ -n "$_pm_closed_url" ] && command printf 'url=%s\n' "$_pm_closed_url"
        return 0
    fi

    command printf 'verdict=absent\n'
    return 0
}

# --- constraints ------------------------------------------------------------

# Markers that introduce a constraint in an issue body. Deliberately a small,
# explicit list rather than a general NLP attempt: a marker that fires only
# sometimes is worse than one that fires narrowly, because the caller would learn
# to trust a sweep that silently misses things.
#
# This is the MECHANIZED half of acceptance criterion 4 — a constraint stated in
# the ISSUE BODY. The other half (an option contradicted by a REPO FILE, the #551
# prose-budget.baseline case) is deliberately NOT mechanized here: this plugin
# installs into arbitrary repos and cannot know which files in one encode
# decisions. That half is a stated, required step in escalation-protocol.md
# § Escalation payload format item 5b. Claiming it here would be worse than the
# gap — the caller would believe the sweep covered ground it never walked.
CONSTRAINT_MARKERS='consider keeping|must not|should not|do not|don.t|never|keep .* inline|avoid |required to|has to stay|leave .* as'

cmd_constraints() {
    _co_issue=""
    _co_platform=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --issue)
                shift
                _co_issue="${1:-}"
                ;;
            --platform)
                shift
                _co_platform="${1:-}"
                ;;
            *) die "premise-check constraints: unknown argument '$1'" ;;
        esac
        shift
    done

    [ -z "$_co_issue" ] && die "premise-check constraints: --issue is required"
    case "$_co_issue" in
        '' | *[!0-9]*) die "premise-check constraints: --issue must be a number, got '$_co_issue'" ;;
    esac

    if [ -z "$_co_platform" ]; then
        _co_platform="$(detect_platform)"
    fi
    case "$_co_platform" in
        github | gitlab) ;;
        *) die "premise-check constraints: --platform must be github or gitlab, got '$_co_platform'" ;;
    esac

    _co_cli="$(platform_cli "$_co_platform")"
    command -v "$_co_cli" >/dev/null 2>&1 ||
        emit_unavailable "$_co_cli not found on PATH — constraint sweep did not run"

    if [ "$_co_platform" = "github" ]; then
        _co_body="$(command gh issue view "$_co_issue" --json body 2>/dev/null)"
        _co_rc=$?
    else
        _co_body="$(command glab issue view "$_co_issue" --output json 2>/dev/null)"
        _co_rc=$?
    fi

    [ "$_co_rc" -ne 0 ] &&
        emit_unavailable "$_co_cli query failed (exit $_co_rc) — constraint sweep did not run"
    [ -z "$_co_body" ] &&
        emit_unavailable "$_co_cli returned no body for #$_co_issue — constraint sweep did not run"

    emit_constraints "$_co_body"
}

# emit_constraints <json-body> — print one constraint= line per matching line.
#
# LINE-ORIENTED, and the consequence is visible in the output: markdown prose
# wraps, so a marker landing mid-sentence emits that PHYSICAL line rather than
# the whole sentence, and a wrapped constraint can arrive as a fragment. Measured
# against #911's own body: 6 rows, the #550 constraint captured intact, two rows
# fragments of wrapped paragraphs.
#
# Left as-is deliberately. Un-wrapping would mean joining paragraphs, which
# destroys the list structure that makes most real constraints one line each —
# and the output is read by a human or agent checking options against it, where a
# recognizable fragment costs a glance and a dropped constraint costs a #550. The
# asymmetry points the same way as the conservative matching in search_terms.
emit_constraints() {
    # Unwrap the JSON string field into lines: \n escapes become real newlines,
    # then escaped quotes and backslashes are restored.
    #
    # THE ESCAPED BACKSLASH IS CONSUMED FIRST, via a placeholder, and the order
    # is the whole point. JSON writes a literal backslash as `\\`, so a body
    # containing `C:\next` arrives as `C:\\next` — three characters `\`, `\`,
    # `n`. A pass that interprets `\n` before resolving `\\` reads the SECOND
    # backslash plus the `n` as a newline escape: it breaks the line mid-token,
    # eats the literal `n`, and strands the first backslash for a later pass that
    # no longer matches. Measured on exactly that body: the emitted constraint
    # was a fragment still carrying its raw JSON prefix.
    #
    # So `\\` becomes a placeholder no JSON escape can produce, the remaining
    # escapes are resolved against text that now holds no ambiguous backslash,
    # and the placeholder becomes a single literal backslash last.
    #
    # The placeholder is spelled LITERALLY in each sed program rather than
    # interpolated from a variable: a sed program computed at runtime is refused
    # outright by the Bash tool in a worktree-isolated session (the #815 class),
    # so a variable here would make this line unrunnable in exactly the context
    # golem uses. `@@PCBS@@` is not producible by any JSON escape sequence.
    _ec_text="$(command printf '%s' "$1" |
        "$SED" -e 's/\\\\/@@PCBS@@/g' -e 's/\\r//g' -e 's/\\n/\
/g' -e 's/\\"/"/g' -e 's/@@PCBS@@/\\/g')"

    # NOTE the redirect rather than `grep -q` in a pipeline: under `pipefail`,
    # -q exits on the first match, the upstream writer takes SIGPIPE, and the
    # pipeline reports 141 — so a PRESENT constraint would read as absent. That
    # is CLAUDE.md portability item 5, and it is precisely the silent-inversion
    # class this script exists to remove.
    _ec_found=0
    while IFS= read -r _ec_line; do
        # Strip list markers and surrounding whitespace so the emitted text is
        # the constraint itself, not its bullet.
        _ec_clean="$(command printf '%s' "$_ec_line" |
            "$SED" -e 's/^[[:space:]]*[-*+][[:space:]]*//' \
                -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "$_ec_clean" ] && continue

        if command printf '%s' "$_ec_clean" |
            "$GREP" -Ei "$CONSTRAINT_MARKERS" >/dev/null 2>&1; then
            command printf 'constraint=%s\n' "$_ec_clean"
            _ec_found=1
        fi
    done <<EOF
$_ec_text
EOF

    if [ "$_ec_found" -eq 1 ]; then
        command printf 'verdict=found\n'
    else
        command printf 'verdict=none\n'
    fi
    return 0
}

# --- dispatch ---------------------------------------------------------------

[ "$#" -eq 0 ] && die "premise-check.sh: missing subcommand"

SUBCOMMAND="$1"
shift
case "$SUBCOMMAND" in
    exists) cmd_exists "$@" ;;
    constraints) cmd_constraints "$@" ;;
    *) die "premise-check.sh: unknown subcommand '$SUBCOMMAND'" ;;
esac
