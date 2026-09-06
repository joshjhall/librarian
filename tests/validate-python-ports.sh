#!/usr/bin/env bash
# Python-port contract + parity gate (issue #17).
#
# Skill pre-scan tools are migrating to a Python 3.11+ primary implementation
# (patterns.py) behind the same TSV contract as the bash fallback (patterns.sh),
# selected at dispatch by a shim in patterns.sh. This gate pins, for every
# patterns.py in the tree:
#
#   1. Edge-case contract under python3 — no arg -> exit 1 + `Usage` on stderr;
#      empty file list -> exit 0 with no output (the same contract
#      validate-prescans.sh pins for the bash entry points).
#   2. bash<->python PARITY — the bash fallback (forced via PATTERNS_FORCE_BASH=1)
#      and the python impl must emit byte-identical findings over a fixture tree.
#      This is what makes the port a safe drop-in: the language boundary is the
#      output, not the implementation.
#
# The whole suite SKIPS (does not fail) when a python3>=3.11 is unavailable,
# mirroring run-all.sh's node-absent skip — a host without the primary runtime
# still exercises the bash path via validate-prescans.sh; parity can only be
# asserted where both runtimes exist.
#
# WHAT PARITY DOES **NOT** PROVE (#684). The contract is same-OUTPUT-on-this-HOST,
# not same-INTENT. Two consequences, both load-bearing when reading a green run:
#
#   1. A defect present in BOTH impls passes. Parity compares them to each other,
#      never to what the pattern was meant to match, so an identical bug is
#      invisible by construction. This is not hypothetical: the Go no-assertions
#      pattern in loop-make-it-work carried a trailing `\b` in patterns.sh AND
#      patterns.py that rejected `t.Errorf`/`t.Fatalf`/`t.Logf` — Go's dominant
#      assertion idioms — so ordinary Go tests were reported as having NO
#      assertions at HIGH. This gate stayed green through the entire lifetime of
#      that bug and through #679. Only a fixture asserting the INTENDED match
#      catches that class; those live in the per-detector suites
#      (validate-loop-detectors.sh et al.), which is where such a case belongs.
#
#   2. Divergence that appears only under BSD semantics is out of reach here.
#      Python `re` implements `\s`/`\w`/`\b` natively, while the bash fallback
#      inherits the host's grep/sed dialect — so the two can agree perfectly on a
#      GNU host and disagree on macOS, and this gate cannot tell. Closing that
#      needs a BSD userland, which is what the `bsd-probe` job on macos-latest
#      (ci.yml) and tests/probe-bsd-regex.sh provide; this suite runs there too,
#      so a BSD-only parity break surfaces in that job rather than here.
#
#      THIS HAS NOW HAPPENED, and it is worth reading as the worked example of
#      both limits at once (#932). On the first run of this suite that ever
#      really executed on macOS, loop-make-it-right's `long-function` arm emitted
#      114 rows under bash and 0 under python on $FIXDIR/Upper.PY. The cause was
#      not a regex dialect but a UTILITY one: BSD `wc` pads its count to width 7,
#      so the bash fallback's `indent` came back as `"      0"` and the
#      interpolated `^.\{0,      0\}[^ ]` interval was malformed — it matched
#      nothing, `end_line` stayed empty, and every `def` fell through to the
#      run-to-EOF fallback. Note what this gate could and could not see: on Linux
#      BOTH impls emitted zero `long-function` rows, so "they agree" held between
#      two EMPTY outputs and the arm had no assertion on it at all here. Note
#      also that root-causing it turned up a SECOND defect the BSD split had
#      masked — python's `indent` carried a `+ 1` modelling a trailing newline
#      GNU sed does not emit, so the impls were off by one column on any body
#      indented one space past its `def`. That one was live on Linux and this
#      gate was green through it, because no fixture here had that shape.
#      The correctness cases that now pin the extent live where limit 1 says they
#      belong: validate-loop-detectors.sh::test_right_long_function_extent_correctness.
#
# Pure bash + coreutils + python3; no network, no jq.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

PLUGINS_DIR="$REPO_ROOT/plugins"

test_suite "Python-port contract + bash parity (#17)"

# Gate the whole suite on a usable primary runtime (python3>=3.11).
if ! command -v python3 >/dev/null 2>&1 ||
    ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    skip_test "python3>=3.11 not available (bash path is covered by validate-prescans.sh)"
    generate_report
    return 0 2>/dev/null || exit 0
fi

# List every ported tool across all plugins (absolute paths, sorted).
#
# DISCOVERY IS BY PAIR NAME, NOT BY THE LITERAL `patterns.py` (#695). The
# original form globbed `-name 'patterns.py'`, which silently EXCLUDED any port
# whose pair is named anything else — and a tool this gate does not see is a tool
# whose bash and python halves can drift apart freely, which is the one thing
# this gate exists to prevent. ship-issue's sizing.{py,sh} is exactly that case:
# it lives beside a 1,572-line bash pre-review-gates.sh that is NOT ported, so
# naming its pair `patterns.*` would have been actively misleading.
#
# PORT_BASENAMES is the explicit list of pair stems. Add a stem here when a new
# <stem>.py / <stem>.sh port appears; the sibling-resolution below keys off the
# same list, so one edit covers discovery, the edge-case contract, and parity.
#
# SCOPE: this gate's contract is FILE-LIST shaped (argv[1] is a list of paths to
# scan; no args -> exit 1 + Usage; empty list -> exit 0 + no output). A port with
# a different CLI shape does not belong here and must be pinned by its own suite
# instead of being bent to fit. ship-issue's split-verify.{py,sh} is that case —
# its argv is `<original> <post-split-original> [results...]`, for which "empty
# file list exits 0" is meaningless — so its bash<->python parity is asserted
# per-case in tests/validate-split-verify.sh rather than over this corpus.
PORT_BASENAMES="patterns sizing plan-lens"

list_python_ports() {
    local stem
    for stem in $PORT_BASENAMES; do
        command find "$PLUGINS_DIR" -type f -name "${stem}.py" 2>/dev/null
    done | command sort
}

# sibling_sh PY — the bash fallback paired with PY, by stem substitution.
# Derived rather than hardcoded so a new stem in PORT_BASENAMES needs no edit here.
sibling_sh() {
    command printf '%s' "${1%.py}.sh"
}

# A shared fixture tree exercising the categories/dispatch a security-style
# scanner cares about. It is deliberately generic (secrets, SQL, XSS, crypto,
# debug markers) so the same tree meaningfully exercises any ported tool; a tool
# that finds nothing in it still asserts parity (both impls emit nothing).
WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT
FIXDIR="$WORKDIR/fix"
command mkdir -p "$FIXDIR"

# The fake secret tokens (GitHub PAT, AWS key, Stripe key) are assembled at
# runtime from fragments so this TEST FILE contains no contiguous secret for the
# gitleaks pre-commit hook to flag — while the fixture files written to disk hold
# the full contiguous token the scanner must match. (The tokens are obvious fakes:
# repeated/sequential filler, not real credentials.)
GH_TOK="ghp_""ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
AWS_TOK="AKIA""0123456789ABCDEF"
STRIPE_TOK="sk_""live_""ABCDEFGHIJKLMNOPQRSTUV"

# app.py also carries #183 regression lines: an x/2/7-bearing single-quoted
# secret (loop-make-it-secure's fixed \x27 class), a yaml.load with and without a
# Loader= (its fixed deserialization filter), and a def whose body is only `pass`
# (loop-make-it-work's fixed empty-body arm). A divergence between the bash and
# python impls on any of these fails the parity assertion below.
#
# The trailing print() lines carry the #604 case: two debug prints whose
# ARGUMENT contains regex-shaped text (an `re.search(r"..."` literal and a
# `grep -niE -- '...'` literal). Before #604 both impls suppressed them, and
# parity was green on the shared false negative — the exact relative-property
# failure mode #605 describes. Both now emit debug-statement rows, and parity
# holds on the corrected behavior. Keep them: they are the fixture's only
# coverage of that branch.
command cat >"$FIXDIR/app.py" <<'EOF'
import hashlib
query = f"SELECT * FROM users WHERE id={user_id}"
single_q = f'SELECT * FROM t WHERE id={i}'
digest = md5(payload)
secret = "abcdefghijkl"
xor_secret = "value_x2_7_here"
# md5(commented) is skipped — the crypto comment-skip is live (#168)
placeholder = "changeme_example_value"
concat = "SELECT a FROM t" + tail
api_key = 'sk2live7value_xx'
loaded = yaml.load(payload)
safe_loaded = yaml.load(payload, Loader=SafeLoader)
def empty_impl():
    pass
print(re.search(r"^\s*console\.(log|debug)\(", line))
print("command grep -niE -- 'it.s worth noting that'")
print("a genuine debug print")
print("grep -vE no end-of-options marker here")
EOF
command printf 'gh = "%s"\n' "$GH_TOK" >>"$FIXDIR/app.py"

command cat >"$FIXDIR/app.ts" <<'EOF'
const sql = `SELECT * FROM t WHERE x=${val}`;
node.innerHTML = raw;
const spaced = () => { }
EOF
command printf 'const awsKey = "%s";\n' "$AWS_TOK" >>"$FIXDIR/app.ts"

# app.go exercises loop-make-it-documented's fixed Go GoDoc arm and
# loop-make-it-work's fixed empty-brace whitespace class (#183).
command cat >"$FIXDIR/app.go" <<'EOF'
package main

func Undocumented() {}

func Spaced() { }
EOF

command cat >"$FIXDIR/view.html" <<'EOF'
<div v-html="userInput"></div>
{{ value|safe }}
{!! $unescaped !!}
EOF

command cat >"$FIXDIR/model.rb" <<'EOF'
sql = "SELECT * FROM t WHERE id=#{id}"
cipher = OpenSSL::Cipher.new('AES-128-ECB')
EOF

# Skip-glob coverage: an .env.example holding a secret must be ignored.
command printf 'key = "%s"\n' "$STRIPE_TOK" >"$FIXDIR/secrets.env.example"

# ESM/CJS extension coverage (#568). Both impls route .mjs/.cjs through their
# js/ts arms; without a fixture carrying these extensions the parity assertion
# passes VACUOUSLY with respect to that branch — it never runs. A top-level
# console.log is the cheapest input that reaches the arm in every ported tool.
command cat >"$FIXDIR/tool.mjs" <<'EOF'
console.log('left in by accident');
export function undocumented() {}
EOF

command cat >"$FIXDIR/tool.cjs" <<'EOF'
console.log('left in by accident');
module.exports.thing = function () {};
EOF

# TypeScript coverage (#726). `ts` became its OWN language key rather than a js
# alias, and app.ts above reaches the ts arm of every port only through content
# that is ALSO valid js — so the type-level forms this issue added were asserted
# vacuously, the same trap the .mjs/.cjs and .sh comments above record.
#
# Every new unit form appears here, and the ORDER-SENSITIVE ones earn their
# place: python re is leftmost-FIRST while POSIX awk ERE is leftmost-LONGEST, so
# `export const enum` captures the name `enum` under one dialect and `Mode`
# under the other unless the two-word alternatives are listed first. That
# divergence is invisible in any single-runtime test and shows up HERE, as a
# TSV parity diff, which is exactly what this gate is for.
command cat >"$FIXDIR/model.ts" <<'EOF'
export interface AlphaShape { a: string }
export interface BetaShape { b: number }
export type GammaUnion = AlphaShape | BetaShape
export enum DeltaKind { X, Y }
export const enum Mode { On, Off }
export namespace EpsUtil { export const z = 1 }
export declare function declaredFn(x: string): string
export abstract class AbstractBase { abstract run(): void }
export module LegacyModule { }
export const realFn = () => 1
EOF

# Swift coverage (#728). Before it, `lang_of()` returned "" for a .swift path in
# BOTH decomposition lenses, so the corpus carried no file that reached a swift
# arm — the same vacuity trap the .mjs/.cjs and .sh comments above record.
#
# Content is chosen to reach the arms that can DIVERGE between the two runtimes
# rather than merely to be Swift:
#
#   - Every unit keyword, including `extension` (one unit, matching Rust's
#     `impl`) and the newer `actor`.
#   - The MODIFIER group in several orders (`public final class`,
#     `@objc private static func`, `override public func`) — Swift fixes no
#     order, and the group is a repeated `(...)*` in both impls.
#   - `public class func` — `class` is in BOTH the modifier group and the
#     keyword alternation, so this is the spelling where leftmost-FIRST (python
#     re) and leftmost-LONGEST (awk ERE) could pick different parses and capture
#     different NAMES.
#   - `open class override Bogus` — malformed Swift that still parses, whose
#     captured name would be the keyword `override` without the reserved-name
#     filter. A phantom unit named for a keyword becomes a seam family and a
#     god-module "concern" in human-read evidence, so it is a wrong FINDING and
#     not a cosmetic mislabel.
#   - BOTH test conventions, including the one-line `@Test func` that the
#     attribute path must not swallow, plus a production unit immediately after
#     an attribute-marked one (the line that goes wrong if the attribute
#     consumes its own header).
#   - `///` doc comments, whose exclusion from production LOC is AC2.
command cat >"$FIXDIR/Model.swift" <<'EOF'
/// A doc comment.
/// A second doc line.
public struct SwiftUser {
    let id: String
}
public final class SwiftStore {
    let cache: Int
}
@objc private static func swiftHelper() {}
override public func swiftOverride() {}
public class func swiftTypeMethod() {}
extension SwiftUser: Codable {
    func encode() {}
}
public protocol SwiftLoading {}
public actor SwiftCache {}
indirect enum SwiftTree { case leaf }
typealias SwiftHandler = () -> Void
open class override Bogus {
    let x: Int
}
@Test
func swiftTestingTwoLine() {}
@Test func swiftTestingOneLine() {}
func productionAfterAttribute() {}
func testXCTestTopLevel() {}
final class SwiftProfileTests: XCTestCase {
    func testInner() {}
}
EOF

# Swift check-* scanner coverage (#839). Everything above this point was written
# for the DECOMPOSITION lenses (#728) and reaches none of the four governed
# scanners' arms — verified by running them against it: check-code-health emitted
# zero rows. So Phase 2's Swift arms would have been asserted VACUOUSLY on the
# scanner side even though a .swift file was present, which is a sharper form of
# the missing-extension trap the .mjs/.cjs (#568), .sh (#598) and .rs (#838)
# comments record: the file IS scanned, it just contains nothing any scanner arm
# matches. One line per new arm, so a divergence in a single arm surfaces as a
# diff rather than being masked by its siblings.
{
    command printf 'do { try risky() } catch { }\n'
    command printf 'do { try risky() } catch let e { }\n'
    command printf 'do { try risky() } catch{ }\n'
    command printf 'catchAllErrors { }\n'
    command printf 'public let swiftApiVersion = 1\n'
    command printf 'print("swift debug output")\n'
    command printf 'debugPrint(swiftValue)\n'
    command printf 'breakpoint()\n'
    command printf 'let swiftPassword = "Str0ng#Pass#Value"\n'
    command printf 'let swiftDigest = md5(swiftPayload)\n'
    command printf '// md5(commented) is skipped — // IS a Swift comment\n'
    command printf '/// md5(docComment) is skipped too — the /// case (#839 AC3)\n'
} >>"$FIXDIR/Model.swift"

# The declarations above reach the swift arms, but a 29-line file is UNDER both
# decomposition lenses' LOC thresholds — so patterns.{py,sh} and sizing.{py,sh}
# emit nothing for it, and "both impls agree" would hold trivially between two
# empty outputs. That is the vacuity this corpus exists to prevent, reached by a
# different route than the missing-extension trap the comments above record: the
# file IS scanned and the arms DO run, but no row survives the threshold, so no
# divergence can be observed.
#
# Padding pushes it over the audit lens's 300-LOC warning so real rows are
# emitted and compared. Two name families, so the seam path (not merely
# file-length) is exercised too. Verified non-vacuous by breaking ONE impl's
# swift arm and confirming this suite goes red.
{
    i=0
    while [ "$i" -lt 40 ]; do
        command printf 'public struct PadUser%s {\n    let a: Int\n    let b: Int\n    let c: Int\n}\n' "$i"
        i=$((i + 1))
    done
    i=0
    while [ "$i" -lt 40 ]; do
        command printf 'public struct PadOrder%s {\n    let a: Int\n    let b: Int\n    let c: Int\n}\n' "$i"
        i=$((i + 1))
    done
} >>"$FIXDIR/Model.swift"

# A .d.ts, whose decline reason and seam suppression are new in #726 and are
# decided per-PATH. Without a `.d.ts` in the corpus that branch never runs.
command cat >"$FIXDIR/api.d.ts" <<'EOF'
export declare interface ApiUser { id: string }
export declare interface ApiOrder { id: string }
export declare interface ApiCart { id: string }
export declare function apiFetch(u: string): Promise<string>
export declare function apiPost(u: string): Promise<string>
EOF

# Shell coverage (#598). The fixture tree carried NO .sh at all, so every
# shell-handling branch in every port was asserted vacuously — the same trap the
# .mjs/.cjs comment above records, and the reason #568's lesson was "a fixture
# lacking the extension asserts nothing". This is the language most of this
# repo's own tooling is written in.
#
# Content is chosen to reach several arms at once: a TODO marker, a swallowed
# error (`|| true`), and a function definition.
command cat >"$FIXDIR/tool.sh" <<'EOF'
#!/usr/bin/env bash
# TODO: implement
run_thing() {
    do_work || true
}
run_thing
EOF

# Classified-prose fixtures (#724). Both lenses now decide a markdown file's
# TYPE from its PATH, through the shared `bloat-spec` regions — so the corpus
# needs files that actually reach those arms, or the parity diff runs over a
# classification neither impl was asked to perform.
#
# Sized to STRADDLE the budgets rather than to be uniformly huge: the agent file
# (500 lines) is over the 250/400 agent budget and would be silent under the old
# generic md pair, which is the #724 miss itself; the SKILL.md and its companion
# are the SAME length on purpose, so any bash/python disagreement about arm
# ORDER shows up as different budgets on identical input rather than hiding
# behind a size difference.
command mkdir -p "$FIXDIR/prose/agents" "$FIXDIR/prose/skills/demo" "$FIXDIR/prose/docs" \
    "$FIXDIR/prose/.claude/memory"
make_prose_fixture() {
    local path="$1" nlines="$2" i=0
    : >"$path"
    while [ "$i" -lt "$nlines" ]; do
        command printf 'Prose line %d of the document.\n' "$i" >>"$path"
        i=$((i + 1))
    done
}
make_prose_fixture "$FIXDIR/prose/agents/reviewer.md" 500
make_prose_fixture "$FIXDIR/prose/skills/demo/SKILL.md" 520
make_prose_fixture "$FIXDIR/prose/skills/demo/reference.md" 520
make_prose_fixture "$FIXDIR/prose/docs/guide.md" 900
make_prose_fixture "$FIXDIR/prose/CLAUDE.md" 700
# Memory-bundle prose. `bundle_kind` is the arm most at risk of a parity split:
# the Python side matches the root with a LITERAL containment test while bash
# matches a QUOTED `case` pattern, deliberately, because fnmatch would read glob
# metacharacters in an operator-configured root as syntax. Both halves are new
# to sizing.{py,sh} in #724, so the corpus needs to actually reach them.
make_prose_fixture "$FIXDIR/prose/.claude/memory/MEMORY.md" 300
make_prose_fixture "$FIXDIR/prose/.claude/memory/lesson.md" 400
# Unclassified markdown — the fall-through arm. Without it the corpus could not
# tell "classification is shared" from "all markdown is classified".
make_prose_fixture "$FIXDIR/prose/notes.md" 900

# MIXED-CASE EXTENSION coverage (#754). Every fixture above is lower-case, so
# the case arm of every port's extension dispatch was asserted VACUOUSLY — the
# same trap the .mjs/.cjs, .sh and .swift comments above record, reached by a
# third route: the extension itself was never spelled a second way.
#
# What it was hiding: each python primary lowercases the extension before its
# EXT_LANG lookup while each bash fallback matched it LITERALLY in a `case`, so
# a mixed-case file segmented under python and as NO LANGUAGE at all under bash.
# Silent — no error, no empty output, exit 0.
#
# TWO extensions, per the issue's AC2: without a NON-python one, a fix that
# lowercased only the py arm would still pass.
#
# Sized and shaped to be non-vacuous in the same way Model.swift above is: a
# 3-line file is under every threshold, both impls emit nothing, and "they
# agree" holds trivially between two empty outputs. So Upper.PY carries TWO
# clusterable unit families and enough bulk to clear the decomposition lenses'
# LOC thresholds, which makes the divergence observable as real seam rows rather
# than as a missing metric.
#
# The PRELUDE below is a second, independent requirement, found by the mutation
# round rather than by inspection: reverting check-code-health's, check-security's,
# check-lifecycle's and loop-make-it-work/secure's py arms to a literal `case`
# left this suite GREEN, because a file of nothing but well-formed `def`s gives
# those detectors nothing to find. A mixed-case file they never had a reason to
# report on cannot demonstrate that they now reach it. So the prelude carries one
# trigger per detector family — a debug print, a breakpoint, an f-string SQL, an
# unreaped Popen, an empty body, a swallowed except — which is what turns each of
# those mutations red.
#
# The swallowed `except` earns its own mention: check-code-health has THREE
# separate `case "$file"` blocks, and the third (empty-handler) sits outside the
# two shared regions, so neither the sync gate nor the first two conversions
# touched it. It was missed on the first pass and found by the structural gate
# (tests/lint-scanner-case-dispatch.sh), not by this corpus.
#
# THE PADDING IS LOAD-BEARING TOO, for three detectors the prelude does not feed.
# They are exercised by properties of the alpha_*/beta_* bodies below rather than
# by a dedicated trigger, so the coverage is real but easy to delete by accident:
#
#   loop-make-it-right      — the single-letter `x`/`y`/`z` locals trip its
#                             single-char-name arm. Rename them and that arm stops
#                             running against a mixed-case path.
#   loop-make-it-documented — every padded def is docstring-less, which is what
#                             reaches its undocumented-public-function arm.
#   check-docs-missing-api  — likewise, via its own undocumented-public-api arm.
#
# So: do NOT add docstrings to the padding and do NOT rename its locals to
# multi-character names without checking those three still fire. Their mixed-case
# dispatch is additionally asserted for CORRECTNESS (not merely parity) in
# tests/validate-loop-detectors.sh::test_mixed_case_extension_dispatch, which is
# the gate that would actually go red — this corpus would only go quiet.
command cat >"$FIXDIR/Upper.PY" <<'EOF'
import subprocess


def prelude_debug():
    print("left in by accident")
    breakpoint()


def prelude_query(uid):
    cur.execute(f"SELECT * FROM users WHERE id={uid}")
    p = subprocess.Popen(["ls"])
    return p


def prelude_empty():
    pass


def prelude_swallow():
    try:
        do_thing()
    except ValueError:
        pass
EOF

{
    i=0
    while [ "$i" -lt 60 ]; do
        command printf 'def alpha_%s(a, b):\n    x = a + b\n    y = x * 2\n    z = y - a\n    return z\n' "$i"
        i=$((i + 1))
    done
    i=0
    while [ "$i" -lt 60 ]; do
        command printf 'def beta_%s(a, b):\n    x = a - b\n    y = x * 3\n    z = y + a\n    return z\n' "$i"
        i=$((i + 1))
    done
} >>"$FIXDIR/Upper.PY"

# The non-python half. `.TS` rather than another python spelling so the fix has
# to be general: it reaches the ts arm, and it is ALSO the extension whose
# lower-case sibling (model.ts) is already in the corpus, so a divergence shows
# up as two files of the same language disagreeing rather than as one orphan.
#
# Same two requirements as Upper.PY, for the same two reasons: a prelude that
# gives the ts-arm detectors something to FIND (a console.log, an SQL template
# literal, an empty body, an undocumented export), and padding that carries it
# over the decomposition lenses' LOC thresholds. Without the padding the ts arm
# of sizing.sh and split-verify.sh could revert to a literal `case` and this
# suite stayed green — measured, not assumed.
command cat >"$FIXDIR/Widget.TS" <<'EOF'
export interface WidgetShape { id: string }
export type WidgetUnion = WidgetShape | null
export const widgetFn = () => 1
console.log('left in by accident');
export function widgetQuery(id) {
  return db.query(`SELECT * FROM widgets WHERE id=${id}`)
}
export function widgetEmpty() { }
EOF

# Two name families so the seam path (not merely file-length) is exercised, the
# same shape the Model.swift padding above uses.
#
# Sized past the REVIEW lens's threshold, not merely the audit lens's. This is
# the one sizing decision here that inspection would get wrong: the two lenses
# have DIFFERENT defaults — the audit lens warns at 300 production LOC, the
# review lens at 500 — so Model.swift's ~330 lines clear the audit lens and
# leave the review lens silent. At 400 lines this fixture left BOTH
# `sizing.sh`'s and `split-verify.sh`'s ts arms mutation-SURVIVING while every
# py arm was killed. 120 units puts it near 600 production LOC, over both.
{
    i=0
    while [ "$i" -lt 60 ]; do
        command printf 'export function alphaWidget%s(a, b) {\n  const x = a + b\n  const y = x * 2\n  const z = y - a\n  return z\n}\n' "$i"
        i=$((i + 1))
    done
    i=0
    while [ "$i" -lt 60 ]; do
        command printf 'export function betaWidget%s(a, b) {\n  const x = a - b\n  const y = x * 3\n  const z = y + a\n  return z\n}\n' "$i"
        i=$((i + 1))
    done
} >>"$FIXDIR/Widget.TS"

# Rust coverage (#838). Phase 1 of #622 added Rust arms to check-security
# (injection-risk), check-code-health (debug-print, debugger, empty-handler) and
# check-lifecycle (all four categories) — and this corpus carried NO .rs file at
# all, so every one of those branches would have been asserted VACUOUSLY: the
# parity diff passes trivially when neither impl ever reaches the arm. Same
# failure the .mjs/.cjs (#568), .sh (#598) and Model.swift comments above record,
# reached by a new route. One line per Rust arm, so a divergence in any single
# arm shows up as a diff rather than being masked by the others.
command cat >"$FIXDIR/app.rs" <<'EOF'
pub fn undocumented_rust() {}
/// documented
pub fn documented_rust() {}
let q = format!("SELECT * FROM t WHERE id={}", id);
write!(f, "SELECT * FROM t WHERE id={}", id);
q.push_str("INSERT INTO t VALUES (");
let concat = "SELECT a FROM t" + tail;
println!("debug output");
eprintln!("debug error");
dbg!(value);
let _ = fallible_call();
let _kept = deliberate_silencer();
match r { Err(_) => {}, Ok(v) => use_it(v) }
let mut child = Command::new("ls");
child.kill();
let f = File::open("path")?;
bus.on("event", handler);
let digest = md5(payload);
let cipher = new_cipher("AES-128-ECB");
password = "Str0ng#Pass#Value"
// md5(commented) is skipped — // IS a Rust comment
EOF

# Extensionless shebang scripts (#858). check-security's language resolver gained
# a FIFTH path shape — an extensionless, untabled name resolved by reading the
# file's `#!` line. This corpus carried no extensionless file at all, so that arm
# would be asserted VACUOUSLY: the parity diff passes trivially when neither impl
# ever reaches it. Same trap the .mjs/.cjs (#568), .sh (#598), Model.swift (#728)
# and app.rs (#838) comments above record, reached by a new route.
#
# Both runtimes must agree on which interpreters resolve AND on which do not, so
# the set covers a resolving script, the `env -S` + version-suffix spellings, and
# the two NON-resolving shapes (no shebang, unknown interpreter) whose correct
# answer is silence. A divergence in the strip-or-unwrap logic — where the two
# impls use genuinely different mechanisms (python rsplit/regex vs bash parameter
# expansion) — shows up here as a TSV diff.
command cat >"$FIXDIR/deploy" <<'EOF'
#!/usr/bin/env bash
password = "realsecret123"
digest = md5(payload)
# password = "commented_out_value"
EOF

command cat >"$FIXDIR/provision" <<'EOF'
#!/usr/bin/env -S perl5 -w
password = "realsecret123"
EOF

command cat >"$FIXDIR/migrate" <<'EOF'
#!/usr/bin/env python3.11
password = "realsecret123"
query = f"SELECT * FROM users WHERE id={user_id}"
EOF

# NON-resolving, deliberately: no shebang at all, and an unrecognized
# interpreter. Both stay the `—` state in both impls (the lexical-INDEPENDENT
# literal patterns still run, which the AKIA line pins).
command cat >"$FIXDIR/legacyrun" <<'EOF'
password = "realsecret123"
digest = md5(payload)
EOF
command printf 'aws = "%s"\n' "$AWS_TOK" >>"$FIXDIR/legacyrun"

command cat >"$FIXDIR/oddball" <<'EOF'
#!/usr/bin/env cobol
password = "realsecret123"
EOF

# CRLF-terminated shebang. The two runtimes reach the interpreter token by
# genuinely different mechanisms (python text-mode readline + str.split, bash
# `read` + IFS word-splitting), and a lone CR is whitespace to neither's
# splitter — so bash saw `bash<CR>`, matched no arm, and stayed SILENT while
# python resolved and fired. Found by the pre-PR review; fixed by the CR strip
# in shebang_lang, and pinned for INTENT in validate-source-detectors.sh.
#
# THE SHEBANG LINE IS CRLF, THE CONTENT LINE IS NOT, and that asymmetry is
# deliberate. A CRLF *content* line exposes a SEPARATE, PRE-EXISTING divergence
# that has nothing to do with this issue: the evidence field is captured from
# the matched line, and python's text-mode read strips the trailing CR while
# bash's `grep` keeps it, so the TSV differs by one byte. Verified against
# origin/main with a plain `.py` file containing a CRLF credential line — it
# reproduces there identically, with no shebang involved. It is latent only
# because no fixture in this corpus had ever carried a CR — the #836 shape,
# where a whole-corpus diff is bounded by the input shapes the corpus holds.
# Filed as #902 rather than fixed here (it spans every detector's evidence field
# in every scanner); this fixture keeps the shebang half testable meanwhile, and
# #902's first AC is the CRLF CONTENT fixture this line had to give up.
command printf '#!/usr/bin/env bash\r\npassword = "realsecret123"\n' >"$FIXDIR/crlfbang"

# ...and the same line ending on the DIRECT-PATH branch, which reaches the token
# by a different route (argv[0] rather than the second token).
command printf '#!/bin/sh\r\npassword = "realsecret123"\n' >"$FIXDIR/crlfdirect" # lint-allow-path: shebang fixture data written to a scratch file, never executed

# An interpreter past the 512-byte read cap. Both runtimes cap the shebang read;
# uncapped, bash would resolve `bash` here and fire while python stayed silent.
# Pins the cap as a PARITY property rather than only as a local bash detail.
#
# ASCII on purpose. The two caps count differently -- python's
# `readline(_SHEBANG_MAX)` is a CHARACTER limit under text-mode decoding, bash's
# `head -c 512` a BYTE limit -- so a multi-byte character straddling the
# boundary is the theoretical divergence. Probed with a UTF-8 `é` placed across
# byte 512: both runtimes stay silent, because either way the interpreter lands
# past the cap and the truncated token matches no arm. The distinction is
# unobservable through the TSV, so it is recorded here rather than pinned with a
# fixture that cannot fail. Shebang lines are ASCII by convention anyway.
{
    command printf '#!/usr/bin/env -S'
    _capi=0
    while [ "$_capi" -lt 180 ]; do
        command printf ' -i'
        _capi=$((_capi + 1))
    done
    command printf ' bash\npassword = "realsecret123"\n'
} >"$FIXDIR/pastcap"
unset _capi

FILE_LIST="$WORKDIR/list.txt"
: >"$FILE_LIST"
for f in "$FIXDIR/app.py" "$FIXDIR/app.ts" "$FIXDIR/app.go" "$FIXDIR/view.html" \
    "$FIXDIR/model.rb" "$FIXDIR/secrets.env.example" \
    "$FIXDIR/tool.mjs" "$FIXDIR/tool.cjs" "$FIXDIR/tool.sh" \
    "$FIXDIR/app.rs" \
    "$FIXDIR/deploy" "$FIXDIR/provision" "$FIXDIR/migrate" \
    "$FIXDIR/legacyrun" "$FIXDIR/oddball" \
    "$FIXDIR/crlfbang" "$FIXDIR/crlfdirect" "$FIXDIR/pastcap" \
    "$FIXDIR/model.ts" "$FIXDIR/api.d.ts" "$FIXDIR/Model.swift" \
    "$FIXDIR/Upper.PY" "$FIXDIR/Widget.TS" \
    "$FIXDIR/prose/agents/reviewer.md" "$FIXDIR/prose/skills/demo/SKILL.md" \
    "$FIXDIR/prose/skills/demo/reference.md" "$FIXDIR/prose/docs/guide.md" \
    "$FIXDIR/prose/CLAUDE.md" "$FIXDIR/prose/notes.md" \
    "$FIXDIR/prose/.claude/memory/MEMORY.md" "$FIXDIR/prose/.claude/memory/lesson.md"; do
    command printf '%s\n' "$f" >>"$FILE_LIST"
done

EMPTY="$WORKDIR/empty.txt"
: >"$EMPTY"

# drift-detect is the two-arg outlier (actual-files + planned-files). It reads no
# file CONTENT — only compares the two path lists — so its parity fixture is a
# pair of path lists rather than the shared source tree. A planned file absent
# from "actual" and an unplanned actual file exercise both categories.
DRIFT_ACTUAL="$WORKDIR/drift-actual.txt"
DRIFT_PLANNED="$WORKDIR/drift-planned.txt"
command printf '%s\n' "src/foo.py" "src/unplanned.py" "package-lock.json" >"$DRIFT_ACTUAL"
command printf '%s\n' "src/foo.py" "src/never_touched.py" >"$DRIFT_PLANNED"

# port_is_two_arg PY — 0 (true) if this port takes two file-list args. Mirrors
# the same special-case in tests/validate-prescans.sh (keyed on the skill dir).
port_is_two_arg() {
    case "$1" in
        */drift-detect/patterns.py) return 0 ;;
        *) return 1 ;;
    esac
}

# --- Edge-case contract (python entry point) --------------------------------

CUR_PY=""
test_python_edgecases() {
    local py="$CUR_PY" rc out err

    # No argument -> exit 1 with a Usage message on stderr.
    rc=0
    err="$(python3 "$py" </dev/null 2>&1 >/dev/null)" || rc=$?
    assert_exit 1 "$rc" "patterns.py: missing argument should exit 1"
    assert_contains "$err" "Usage" "patterns.py: missing argument should print a usage error"

    # Empty file list -> exit 0, no output. drift-detect needs the right arity
    # (two empty lists) so it does not exit 1 on a legitimately empty diff.
    rc=0
    if port_is_two_arg "$py"; then
        out="$(python3 "$py" "$EMPTY" "$EMPTY" 2>/dev/null)" || rc=$?
    else
        out="$(python3 "$py" "$EMPTY" 2>/dev/null)" || rc=$?
    fi
    assert_exit 0 "$rc" "patterns.py: empty file list should exit 0"
    assert_output_empty "$out" "patterns.py: empty file list should emit no findings"
}

# --- bash<->python parity ----------------------------------------------------

# --- Input-shape guard: EXIT-CODE parity (#816) ------------------------------
#
# test_python_bash_parity above compares STDOUT, which is the right contract for
# findings but is structurally blind to this one: handed a diff, both impls
# correctly emit NOTHING, so a mutation making one of them exit 0 while the
# other exits 1 compares equal and passes. The divergence lives entirely in the
# exit code. A mutation round found exactly that -- the python diff arm could be
# changed to `return 0` with this whole suite green -- so the two runtimes are
# compared here on rc, not on output.
test_python_bash_guard_exit_parity() {
    local py="$CUR_PY" sh
    sh="$(sibling_sh "$py")"

    if [ ! -f "$sh" ]; then
        skip_test "no sibling .sh for $(command basename "$py") — exit parity needs both impls"
        return 0
    fi

    local diff_list="$WORKDIR/guard-parity.diff"
    {
        command printf -- 'diff --git a/src/app.js b/src/app.js\n'
        command printf -- 'index 111..222 100644\n'
        command printf -- '--- a/src/app.js\n'
        command printf -- '+++ b/src/app.js\n'
        command printf -- '@@ -1 +1 @@\n'
        command printf -- '-const a = 1;\n'
        command printf -- '+const a = 2;\n'
    } >"$diff_list"

    local py_rc=0 sh_rc=0
    if port_is_two_arg "$py"; then
        python3 "$py" "$diff_list" "$DRIFT_PLANNED" >/dev/null 2>&1 || py_rc=$?
        PATTERNS_FORCE_BASH=1 SIZING_FORCE_BASH=1 PLAN_LENS_FORCE_BASH=1 \
            bash "$sh" "$diff_list" "$DRIFT_PLANNED" >/dev/null 2>&1 || sh_rc=$?
    else
        python3 "$py" "$diff_list" >/dev/null 2>&1 || py_rc=$?
        PATTERNS_FORCE_BASH=1 SIZING_FORCE_BASH=1 PLAN_LENS_FORCE_BASH=1 \
            bash "$sh" "$diff_list" >/dev/null 2>&1 || sh_rc=$?
    fi

    local rel
    rel="$(command basename "$(command dirname "$py")")"
    assert_exit 1 "$py_rc" "$rel: python refuses a diff with exit 1"
    assert_exit 1 "$sh_rc" "$rel: bash refuses a diff with exit 1"
    assert_equals "$sh_rc" "$py_rc" "$rel: both runtimes agree on the refusal exit code"
}

test_python_bash_parity() {
    local py="$CUR_PY" sh
    sh="$(sibling_sh "$py")"

    if [ ! -f "$sh" ]; then
        skip_test "no sibling .sh for $(command basename "$py") — parity needs both impls"
        return 0
    fi

    # EVERY force-bash variable is exported, not just PATTERNS_FORCE_BASH. Each
    # shim reads its OWN var (sizing.sh reads SIZING_FORCE_BASH), so setting only
    # the patterns one would let a non-patterns shim exec its python primary —
    # and the "parity" assertion would compare python against python and pass
    # unconditionally. Setting all of them is safe: a shim ignores the vars it
    # does not read. The self-check below proves the bash body actually ran.
    local py_out sh_out
    if port_is_two_arg "$py"; then
        py_out="$(python3 "$py" "$DRIFT_ACTUAL" "$DRIFT_PLANNED" 2>/dev/null | command sort)"
        sh_out="$(PATTERNS_FORCE_BASH=1 SIZING_FORCE_BASH=1 PLAN_LENS_FORCE_BASH=1 bash "$sh" "$DRIFT_ACTUAL" "$DRIFT_PLANNED" 2>/dev/null | command sort)"
    else
        py_out="$(python3 "$py" "$FILE_LIST" 2>/dev/null | command sort)"
        sh_out="$(PATTERNS_FORCE_BASH=1 SIZING_FORCE_BASH=1 PLAN_LENS_FORCE_BASH=1 bash "$sh" "$FILE_LIST" 2>/dev/null | command sort)"
    fi

    assert_equals "$sh_out" "$py_out" \
        "$(command basename "$(command dirname "$py")"): python and bash impls emit identical findings"
}

# --- Corpus guard + drive ----------------------------------------------------

# --- Direct unit coverage of a port's predicates (#605) ----------------------
#
# Parity is a strong property but a RELATIVE one: it asserts the two impls
# agree, not that either is correct. If both share a misconception parity stays
# green and both are wrong — which is exactly how #599 shipped a suppression
# that suppressed nothing (fixed in #604).
#
# So this calls check-code-health/patterns.py's is_test_file DIRECTLY, in
# Python, with both branches. The sibling cases in
# tests/validate-pre-review-gates.sh cover the same predicate through the BASH
# gate; neither substitutes for the other — they are different functions in
# different languages that happen to agree.
#
# Zero new dependency, consistent with the repo's testing posture: the module
# is stdlib-only and main-guarded, so importlib loads it without executing
# main(). No pytest, no test framework.
HEALTH_PY="$PLUGINS_DIR/review-audit/skills/check-code-health/patterns.py"

test_py_is_test_file_direct() {
    local out rc=0
    if [ ! -f "$HEALTH_PY" ]; then
        skip_test "check-code-health/patterns.py not present"
        return 0
    fi
    # Each line: "<expected> <path>". Printed as "FAIL ..." on mismatch so the
    # assertion below names the specific arm that broke, not just a count.
    command cat >"$WORKDIR/is_test_file.py" <<'PY'
import importlib.util, sys

spec = importlib.util.spec_from_file_location("health_patterns", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

cases = [
    # TRUE branch — directory-segment arms, then basename arms.
    (True, "tests/helper.py"),
    (True, "src/tests/helper.py"),
    (True, "spec/a.js"),
    (True, "__tests__/b.js"),
    (True, "pkg/test/c.js"),
    (True, "__pycache__/d.py"),
    (True, "test_util.py"),
    (True, "thing_test.js"),
    (True, "thing_spec.rb"),
    (True, "thing.test.ts"),
    (True, "thing.spec.js"),
    # FALSE branch — the near-misses a loose *test* glob wrongly swallows
    # (#568), plus a test_-prefixed DIRECTORY holding real source.
    (False, "contest.py"),
    (False, "latest.js"),
    (False, "attestation.go"),
    (False, "src/protest/manifest.js"),
    (False, "src/test_helpers/production.py"),
    (False, "app.py"),
]

bad = 0
for expected, path in cases:
    got = mod.is_test_file(path)
    if got is not expected:
        bad += 1
        print("FAIL is_test_file(%r) -> %r, expected %r" % (path, got, expected))
if bad == 0:
    print("OK")
PY
    out="$(python3 "$WORKDIR/is_test_file.py" "$HEALTH_PY" 2>&1)" || rc=$?
    assert_equals "0" "$rc" "the direct is_test_file probe ran without error"
    assert_equals "OK" "$out" "patterns.py is_test_file: every arm matches its expected branch (#605)"
}

# --- the debug-family split, called DIRECTLY (#687) --------------------------
#
# #680 split patterns.py's inline debug logic into _scan_debug_print and
# _scan_debugger. Until now they were exercised only INDIRECTLY, through this
# file's bash<->python parity fixture, which has two blind spots:
#
#   1. Parity proves the two impls AGREE, not that either is CORRECT. A
#      symmetrical mistake passes green — not hypothetical: a wrong trailing
#      `\b` sat in both copies of the Go assertion pattern through the whole of
#      #679, and this gate never noticed (#684).
#   2. The parity suite skip_tests itself when no python3>=3.11 exists. On such
#      a host the split had NO coverage — the #543 self-skipping shape, where
#      the arm that does not run is the risky one.
#
# So this calls both functions directly, in Python, the same importlib shape as
# test_py_is_test_file_direct above. Zero new dependencies; the module is
# stdlib-only and main-guarded, so importing it does not run main().
#
# The ORDER assertion is the point of the adjacent-lines fixture. scan_file's
# comment promises print-then-debugger emission, and the shared-region contract
# is an ORDERED multiset — validate-shared-scanner-sync.sh treats a reordered
# line as drift — but nothing pinned the order the two functions actually emit
# in. Swapping the two calls in scan_file would have been invisible.
test_py_debug_family_direct() {
    local out rc=0
    if [ ! -f "$HEALTH_PY" ]; then
        skip_test "check-code-health/patterns.py not present"
        return 0
    fi
    command cat >"$WORKDIR/debug_family.py" <<'PY'
import importlib.util, io, sys
from contextlib import redirect_stdout

spec = importlib.util.spec_from_file_location("health_patterns", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

problems = []


def rows(fn, path, idx, line, ext):
    """The TSV rows one family function emits for a single line."""
    buf = io.StringIO()
    with redirect_stdout(buf):
        fn(path, idx, line, ext)
    return [r for r in buf.getvalue().splitlines() if r]


# --- each family fires on its OWN input ---
pr = rows(mod._scan_debug_print, "a.py", 1, 'print("x")', "py")
if len(pr) != 1 or "Debug print statement" not in pr[0]:
    problems.append("_scan_debug_print on print() -> %r" % (pr,))

db = rows(mod._scan_debugger, "a.py", 1, "breakpoint()", "py")
if len(db) != 1 or "Debugger statement" not in db[0]:
    problems.append("_scan_debugger on breakpoint() -> %r" % (db,))

# --- and NOT on the other's input: the families must not overlap ---
# This is what makes the split meaningful. If either function widened to cover
# both, the exemption in scan_file (#686) would silently reach the debugger.
cross = rows(mod._scan_debug_print, "a.py", 1, "breakpoint()", "py")
if cross:
    problems.append("_scan_debug_print wrongly fired on breakpoint(): %r" % (cross,))

cross = rows(mod._scan_debugger, "a.py", 1, 'print("x")', "py")
if cross:
    problems.append("_scan_debugger wrongly fired on print(): %r" % (cross,))

# --- ADJACENT LINES, whole-file: both rows emit ---
buf = io.StringIO()
with redirect_stdout(buf):
    mod.scan_file("cli.py", ['print("out")', "breakpoint()"])
emitted = [r for r in buf.getvalue().splitlines() if "debug-statement" in r]

if len(emitted) != 2:
    problems.append("adjacent print+breakpoint emitted %d rows, want 2: %r" % (len(emitted), emitted))
else:
    if "Debug print statement" not in emitted[0]:
        problems.append("row 1 is not the print row: %r" % (emitted[0],))
    if "Debugger statement" not in emitted[1]:
        problems.append("row 2 is not the debugger row: %r" % (emitted[1],))

# --- ORDER: pinned at the SOURCE, because output cannot show it ---
#
# Worth stating plainly, because the obvious test does not work. The adjacent-
# lines case above cannot observe call order: the two families sit on different
# LINES, so scan_file's per-line loop emits them in line order whichever way it
# calls them — that case passes with the calls swapped (verified by mutation).
#
# Nor can a single line carry both: every pattern in both families is
# `^\s*`-anchored, so `print("x"); breakpoint()` matches the print family only.
# There is NO input for which the call order changes the emitted bytes.
#
# That is not a gap in the test, it is a fact about the code — and it is exactly
# why #687 asked for the order to be pinned: scan_file's comment promises
# print-then-debugger, and the shared-region contract is an ORDERED multiset, so
# the promise should not rest on a comment alone. Since behaviour cannot witness
# it, assert on the SOURCE: the two calls appear in the documented order.
import inspect

src = inspect.getsource(mod.scan_file)
i_print = src.find("_scan_debug_print(")
i_dbg = src.find("_scan_debugger(")
if i_print < 0 or i_dbg < 0:
    problems.append("scan_file no longer calls both family functions by name")
elif i_print > i_dbg:
    problems.append(
        "scan_file calls _scan_debugger BEFORE _scan_debug_print; "
        "the documented emission order is print-then-debugger"
    )

for p in problems:
    print("FAIL " + p)
if not problems:
    print("OK")
PY
    out="$(python3 "$WORKDIR/debug_family.py" "$HEALTH_PY" 2>&1)" || rc=$?
    assert_equals "0" "$rc" "the direct debug-family probe ran without error"
    assert_equals "OK" "$out" \
        "patterns.py debug split: each family fires only on its own input, and scan_file emits print-then-debugger (#687)"
}

# --- _read_yaml_list, called directly (#686) ---------------------------------
#
# The bash twin has direct unit tests in validate-pre-review-gates.sh
# (test_read_yaml_list_*). The Python one had none: it is reached only through
# the end-to-end flow in validate-source-detectors.sh, whose values become
# GITIGNORE PATTERNS — and git strips trailing whitespace from those itself, so
# the #684 rule (strip unconditionally, preserve INSIDE quotes) is invisible
# through that path. A regression in the quote/whitespace handling would not
# show up anywhere.
#
# The last case is the ASCII section terminator. Python's str.isalpha() is
# Unicode-aware and the bash glob `[a-zA-Z_]*` is not, so an accented key in
# column 0 would end the section in one impl and not the other — the two
# runtimes reading one config differently. Caught in review before merge; this
# pins it, since no parity fixture uses a non-ASCII first character.
test_py_read_yaml_list_direct() {
    local out rc=0
    if [ ! -f "$HEALTH_PY" ]; then
        skip_test "check-code-health/patterns.py not present"
        return 0
    fi
    command cat >"$WORKDIR/read_yaml_list.py" <<'PY'
import importlib.util, os, sys, tempfile

spec = importlib.util.spec_from_file_location("health_patterns", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

problems = []


def parse(key, text):
    d = tempfile.mkdtemp()
    p = os.path.join(d, "cfg.yml")
    with open(p, "w", encoding="utf-8") as fh:
        fh.write(text)
    try:
        return mod._read_yaml_list(key, p)
    finally:
        os.remove(p)
        os.rmdir(d)


def check(label, got, want):
    if got != want:
        problems.append("%s -> %r, want %r" % (label, got, want))


# Trailing whitespace comes off with OR without a closing quote (#684).
check(
    "unquoted trailing ws",
    parse("k", 'k:\n  - a.py   \n  - "b.py"   \n'),
    ["a.py", "b.py"],
)

# ...but whitespace INSIDE the quotes is deliberate and survives.
check("quoted inner ws", parse("k", 'k:\n  - "a.py  "\n'), ["a.py  "])

# Both quote styles, and a bare value.
check(
    "quote styles",
    parse("k", "k:\n  - \"a.py\"\n  - 'b.py'\n  - c.py\n"),
    ["a.py", "b.py", "c.py"],
)

# A later top-level key ends the section; a different key is reachable.
two = "k:\n  - a.py\nother:\n  - b.py\n"
check("section ends at next key", parse("k", two), ["a.py"])
check("later key reachable", parse("other", two), ["b.py"])

# Absent key and blank entries.
check("absent key", parse("nope", "k:\n  - a.py\n"), [])
check("blank lines dropped", parse("k", "k:\n  - a.py\n\n  - b.py\n"), ["a.py", "b.py"])

# ASCII-ONLY terminator. A non-ASCII letter in column 0 does NOT end the
# section, matching the bash glob `[a-zA-Z_]*` — and since it is neither a
# terminator nor indented, bash then keeps it as an ITEM. Expected values here
# were taken from running the bash twin, not from intuition: it is the reference
# impl, so whatever it does IS the contract.
#
# With the original str.isalpha() this returned ["a.py"] — the section ended
# early and b.py was lost. That is the divergence this case pins.
check(
    "non-ASCII column-0 line does not terminate the section",
    parse("k", "k:\n  - a.py\n\u00e9key\n  - b.py\n"),
    ["a.py", "\u00e9key", "b.py"],
)

for p in problems:
    print("FAIL " + p)
if not problems:
    print("OK")
PY
    out="$(python3 "$WORKDIR/read_yaml_list.py" "$HEALTH_PY" 2>&1)" || rc=$?
    assert_equals "0" "$rc" "the direct _read_yaml_list probe ran without error"
    assert_equals "OK" "$out" \
        "patterns.py _read_yaml_list: quotes, #684 whitespace rule, and ASCII-only section terminator (#686)"
}

ports_list="$(list_python_ports)"

test_corpus_non_empty() {
    assert_not_empty "$ports_list" "At least one ported tool must be present to validate"
}

# Every discovered port's force-bash variable is actually SET by the parity test.
#
# WHY THIS EXISTS. The parity assertion runs the `.sh` half expecting the bash
# BODY; each shim decides that by reading its own `*_FORCE_BASH` variable. If a
# port's variable is not in the parity call, its shim exec's the PYTHON primary
# and the assertion compares python against python — passing unconditionally,
# forever, while the bash fallback rots untested. That failure is invisible: the
# gate stays green and reports the port as covered.
#
# So this greps each shim for the variable it reads and asserts that EVERY line
# of the parity test which invokes the `.sh` sets that exact name. A future port
# that introduces a third variable fails HERE with an actionable message, instead
# of silently opting out of parity.
#
# PER-INVOCATION, NOT PER-BODY. Checking that the variable appears ANYWHERE in
# the test body is too weak: the parity test has TWO invocation arms (one-arg and
# two-arg), and a variable present in only one of them leaves the other arm
# comparing python to python. Verified by mutation — dropping SIZING_FORCE_BASH
# from just the one-arg arm passed a body-scoped check and fails this one.
test_every_force_bash_var_is_set() {
    local py sh var parity_body invocations line n_inv=0
    parity_body="$(command sed -n '/^test_python_bash_parity()/,/^}/p' "$SCRIPT_DIR/validate-python-ports.sh")"
    assert_not_empty "$parity_body" "the parity test body was located (self-inspection works)"

    # Every line that actually runs the bash sibling.
    invocations="$(command printf '%s\n' "$parity_body" | command grep -F 'bash "$sh"' || true)"
    assert_not_empty "$invocations" "the parity test's bash invocations were located"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        n_inv=$((n_inv + 1))
    done <<EOF
$invocations
EOF
    # Both arms must be present, or the loop below could vacuously pass by
    # finding a single compliant invocation.
    assert_equals "2" "$n_inv" "the parity test has both invocation arms (one-arg and two-arg)"

    while IFS= read -r py; do
        [ -n "$py" ] || continue
        sh="$(sibling_sh "$py")"
        [ -f "$sh" ] || continue
        # The shim line looks like: [ "${SOMETHING_FORCE_BASH:-0}" != "1" ]
        var="$(command grep -oE '[A-Z_]+_FORCE_BASH' "$sh" | command head -1 || true)"
        assert_not_empty "$var" "$(command basename "$sh"): declares a *_FORCE_BASH shim variable"
        [ -n "$var" ] || continue
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            assert_contains "$line" "$var" \
                "$(command basename "$sh"): every parity invocation sets ${var} (else that arm compares python to python)"
        done <<EOF
$invocations
EOF
    done <<<"$ports_list"
}

# md_slug, called directly in BOTH runtimes and compared (#730).
#
# WHY THIS IS NOT COVERED BY THE CORPUS PARITY ABOVE. sizing.py used to hardcode
# a markdown unit's name to "section" while its own awk twin — and the audit lens
# — slugged the heading text. That fork produced NO output difference, so corpus
# parity was green and correct to be: this lens never surfaces a unit NAME, only
# a COUNT. #730 unified the code; per [[surviving-mutation-may-be-a-real-no-op]]
# the unreachable half is recorded as unreachable in sizing.py rather than given
# a test that cannot fail, and THIS test covers the half that IS reachable —
# md_slug's own slugging rules, exercised by calling it.
#
# Both runtimes are driven from one case table so a rule can never be asserted
# of one and not the other. The awk side is invoked through the same
# `function md_slug` living in the shared:loc-helpers-awk region, so this is a
# genuine cross-language check rather than python-vs-python.
#
# The two Python paths point at loc_engine.py, NOT at the entry scanners (#772).
# `md_slug` and `find_units` are shared-region code, and since the split that
# region lives in the sibling module — the entry only re-exports what it calls.
# Probing the module that DEFINES the shared code keeps this a test of the
# shared halves rather than of the import wiring; the entry's re-export is
# covered by the corpus parity runs, which execute the entry end-to-end.
DECOMP_PY="$PLUGINS_DIR/review-audit/skills/check-decomposition/loc_engine.py"
SIZING_PY_PORT="$PLUGINS_DIR/workflow/skills/ship-issue/loc_engine.py"
SIZING_SH_PORT="$PLUGINS_DIR/workflow/skills/ship-issue/sizing.sh"
# The audit lens's bash half. `family_prefix` lives OUTSIDE the shared region
# there (it is audit-lens-only on the bash side), so its awk twin is extracted
# from this file rather than from sizing.sh.
DECOMP_SH_PORT="$PLUGINS_DIR/review-audit/skills/check-decomposition/patterns.sh"

test_py_md_slug_direct() {
    local out rc=0 awk_out
    if [ ! -f "$DECOMP_PY" ] || [ ! -f "$SIZING_PY_PORT" ]; then
        skip_test "check-decomposition/patterns.py or ship-issue/sizing.py not present"
        return 0
    fi

    # --- both Python copies, driven from one table --------------------------
    command cat >"$WORKDIR/md_slug.py" <<'PY'
import importlib.util, sys

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

audit = load("decomp_patterns", sys.argv[1])
review = load("sizing_py", sys.argv[2])

cases = [
    ("Install on Linux", "install_on_linux"),
    ("  Leading space", "leading_space"),
    ("Trailing space   ", "trailing_space"),
    ("MiXeD CaSe", "mixed_case"),
    ("punctuation!!! here", "punctuation_here"),
    ("digits 123 kept", "digits_123_kept"),
    ("---", ""),
    ("", ""),
]

bad = 0

# The CALL SITE, not just the function. md_slug agreeing in isolation does not
# prove find_units actually uses it: a wrong variable passed at the call site
# would leave every case above green while markdown units came out misnamed.
# This drives find_units(lines, "md") in BOTH lenses and reads Unit.name back.
#
# It is NOT a test-that-cannot-fail: reverting sizing.py's md arm to the old
# hardcoded "section" fails this immediately. What IS unreachable is the
# EMITTED output (this lens reports unit counts, never names) — recorded as
# such in sizing.py rather than asserted here.
md_lines = [
    "# Install on Linux",
    "body",
    "# Configure the Daemon",
    "body",
]
for label, mod in (("audit", audit), ("review", review)):
    got = [u.name for u in mod.find_units(md_lines, "md")]
    want = ["install_on_linux", "configure_the_daemon"]
    if got != want:
        bad += 1
        print("FAIL %s find_units(md) names -> %r, expected %r" % (label, got, want))

# A heading that slugs to empty must still yield the "section" fallback rather
# than an empty name — the `or "section"` half of the expression.
for label, mod in (("audit", audit), ("review", review)):
    got = [u.name for u in mod.find_units(["# ---", "body"], "md")]
    if got != ["section"]:
        bad += 1
        print("FAIL %s find_units(md) empty-slug fallback -> %r" % (label, got))

for text, expected in cases:
    a = audit.md_slug(text)
    r = review.md_slug(text)
    if a != expected:
        bad += 1
        print("FAIL audit md_slug(%r) -> %r, expected %r" % (text, a, expected))
    if r != expected:
        bad += 1
        print("FAIL review md_slug(%r) -> %r, expected %r" % (text, r, expected))
    if a != r:
        bad += 1
        print("FAIL md_slug(%r): audit %r != review %r" % (text, a, r))
if bad == 0:
    print("OK")
PY
    out="$(python3 "$WORKDIR/md_slug.py" "$DECOMP_PY" "$SIZING_PY_PORT" 2>&1)" || rc=$?
    assert_equals "0" "$rc" "the direct md_slug probe ran without error"
    assert_equals "OK" "$out" \
        "md_slug: both Python lenses agree with the expected slug for every rule (#730)"

    # --- the awk twin, same table -------------------------------------------
    # Extracts the shared awk md_slug from sizing.sh and drives it directly, so a
    # Python-only unification cannot pass while the bash fallback still differs.
    if [ ! -f "$SIZING_SH_PORT" ]; then
        skip_test "ship-issue/sizing.sh not present"
        return 0
    fi
    # Extract just the md_slug function from the shared region. The region also
    # holds the NESTED unit-segmenters-awk block; taking only md_slug keeps the
    # driver minimal and independent of that nesting.
    #
    # The terminator is the closing brace at the FUNCTION's own indent (4
    # spaces), not any `}` — md_slug contains a `for` loop whose brace closes at
    # a deeper indent, and stopping there would emit an unbalanced fragment.
    command awk '
        /^    function md_slug\(/ { in_f = 1 }
        in_f { print }
        in_f && /^    }[[:space:]]*$/ { exit }
    ' "$SIZING_SH_PORT" >"$WORKDIR/md_slug.awk"

    # Cases are TAB-separated `input<TAB>expected` rows fed on stdin, so the
    # driver needs no ternary and no -v quoting games (POSIX awk, BSD-safe).
    {
        command cat "$WORKDIR/md_slug.awk"
        command printf '%s\n' 'BEGIN { FS = "\t"; bad = 0 }'
        command printf '%s\n' '{ got = md_slug($1); if (got != $2) { bad++; printf "FAIL awk md_slug(<%s>) -> <%s>, expected <%s>\n", $1, got, $2 } }'
        command printf '%s\n' 'END { if (bad == 0) print "OK" }'
    } >"$WORKDIR/md_slug_drive.awk"

    awk_out="$(command printf '%s\n' \
        "Install on Linux	install_on_linux" \
        "  Leading space	leading_space" \
        "Trailing space   	trailing_space" \
        "MiXeD CaSe	mixed_case" \
        "punctuation!!! here	punctuation_here" \
        "digits 123 kept	digits_123_kept" \
        "---	" |
        LC_ALL=C command awk -f "$WORKDIR/md_slug_drive.awk")"
    assert_equals "OK" "$awk_out" \
        "md_slug: the shared awk twin produces the same slug for every rule (#730)"
}

# family_prefix, called directly in BOTH Python copies and the shared awk twin.
#
# THE SIBLING OF md_slug ABOVE, and untested until #772 for the same reason it
# is easy to miss: `family_prefix` decides which units CLUSTER, and a cluster is
# only ever surfaced as an aggregate — a seam span, a unit count, a split shape.
# So a wrong family produces a differently-grouped but still perfectly
# well-formed finding. The end-to-end fixtures in validate-decomposition-detectors.sh
# assert those aggregates and would keep passing through a rule change here, as
# long as the fixture's units happened to still group the same way.
#
# The rules, all four exercised below: snake_case splits at the first
# underscore; camelCase/PascalCase at the first INTERNAL uppercase (index 1, so
# a leading capital is not itself the split); a leading RUN of uppercase is an
# ACRONYM and stays whole (#778); the result is lowercased, which is what puts
# `ParseEntry` and `parse_entry` in one family.
#
# Driven from ONE case table across all three runtimes, so a rule can never be
# asserted of one impl and not the others — the same discipline as md_slug.
test_py_family_prefix_direct() {
    local out rc=0 awk_out
    if [ ! -f "$DECOMP_PY" ] || [ ! -f "$SIZING_PY_PORT" ]; then
        skip_test "check-decomposition or ship-issue loc_engine.py not present"
        return 0
    fi

    command cat >"$WORKDIR/family_prefix.py" <<'PY'
import importlib.util, sys

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

audit = load("decomp_loc_engine", sys.argv[1])
review = load("sizing_loc_engine", sys.argv[2])

cases = [
    # snake_case: split at the FIRST underscore.
    ("parse_entry", "parse"),
    ("parse_header_body", "parse"),
    # camelCase: split at the first internal uppercase.
    ("parseEntry", "parse"),
    # PascalCase: the LEADING capital is not the split point (i starts at 1),
    # and the result lowercases — so this lands in the same family as the two
    # above, which is the whole point of the rule.
    #
    # ALSO the row that bounds #778's acronym branch from below: a leading run
    # of length ONE is not an acronym, so this must fall through to the
    # camelCase scan untouched. Drop the run-length guard and it regresses to
    # `p` — which is why this row is load-bearing in both directions.
    ("ParseEntry", "parse"),
    # No separator at all: the whole name, lowercased.
    ("parse", "parse"),
    # ACRONYM PREFIX (#778). A leading RUN of uppercase is one word, so the run
    # survives whole instead of collapsing to its first letter. These rows were
    # the DEFECT until #778: `HTTPServer` -> `h` made the seam row propose
    # `api/h.ts` at HIGH certainty — a confident wrong filename, which is worse
    # than no finding at all. Idiomatic in ts/go/rs/swift, all of which have
    # segmenters here, so this is ordinary code and not an exotic shape.
    ("HTTPServer", "http"),
    ("XMLParser", "xml"),
    ("IOError", "io"),
    # Two acronyms back to back: the FIRST run wins and the back-off gives the
    # `H` to `Http`, so this joins the `XMLParser` family rather than making its
    # own. Pins the back-off boundary, not just that a run is consumed.
    ("XMLHttpRequest", "xml"),
    # All-caps with NO lowercase after the run: nothing to back off to, so the
    # run is the whole name. Was `p` before #778 and pinned as such; these two
    # rows are the same defect as the acronym rows above, and flipping them is
    # part of the fix rather than collateral.
    ("PARSE", "parse"),
    ("MAX", "max"),
    # The MINIMAL no-back-off case: a run of exactly 2 with nothing after it,
    # where the run-length guard and the end-of-name guard are both at their
    # boundary simultaneously. The rows above are all 3+, so without this one
    # the length-2 corner is only reached by extrapolation.
    ("IO", "io"),
    # SCREAMING_CASE with an underscore still takes the underscore branch, which
    # runs FIRST and is untouched by #778.
    ("MAX_RETRIES", "max"),
    # A LEADING underscore is not a split (find returns 0, and the rule
    # requires > 0) — so a private helper keeps its full stem rather than
    # collapsing every `_foo`/`_bar` into one empty family.
    ("_private", "_private"),
]

bad = 0
for name, expected in cases:
    a = audit.family_prefix(name)
    r = review.family_prefix(name)
    if a != expected:
        bad += 1
        print("FAIL audit family_prefix(%r) -> %r, expected %r" % (name, a, expected))
    if r != expected:
        bad += 1
        print("FAIL review family_prefix(%r) -> %r, expected %r" % (name, r, expected))
    if a != r:
        bad += 1
        print("FAIL family_prefix(%r): audit %r != review %r" % (name, a, r))

if bad == 0:
    print("OK")
PY
    out="$(python3 "$WORKDIR/family_prefix.py" "$DECOMP_PY" "$SIZING_PY_PORT" 2>&1)" || rc=$?

    assert_equals "0" "$rc" "the direct family_prefix probe ran without error"
    assert_equals "OK" "$out" \
        "family_prefix: both Python lenses agree with the expected family for every rule (#772)"

    # --- the awk twin, same table -------------------------------------------
    # patterns.sh carries family_prefix OUTSIDE the shared region (it is
    # audit-lens-only on the bash side), so it is extracted from there.
    if [ ! -f "$DECOMP_SH_PORT" ]; then
        skip_test "check-decomposition/patterns.sh not present"
        return 0
    fi
    # BRACE-DEPTH tracked, not "stop at the first 4-space-indented `}`".
    #
    # The indent-matching form works only while the body has no nested block
    # closing at the function's own indent. Wrap the underscore check in an `if`
    # and the extract TRUNCATES mid-function — awk then fails on a syntactically
    # incomplete program with a parse error pointing at the generated driver,
    # not at the extraction that broke. Counting braces finds the real close
    # regardless of body shape, and the balance assertion below turns any
    # remaining surprise into a clear failure rather than a cryptic one.
    command awk '
        /^[[:space:]]*function family_prefix\(/ { in_f = 1 }
        in_f {
            print
            n = gsub(/\{/, "{")
            m = gsub(/\}/, "}")
            depth += n - m
            if (depth <= 0) exit
        }
    ' "$DECOMP_SH_PORT" >"$WORKDIR/family_prefix.awk"

    # The extract is non-empty and brace-balanced. Without this a truncated or
    # missing extract surfaces as an awk syntax error inside the driver, which
    # reads as "the test is broken" rather than "the extraction needs updating".
    local fp_opens fp_closes fp_lines
    fp_lines="$(command wc -l <"$WORKDIR/family_prefix.awk" | command tr -d ' ')"
    fp_opens="$(command tr -cd '{' <"$WORKDIR/family_prefix.awk" | command wc -c | command tr -d ' ')"
    fp_closes="$(command tr -cd '}' <"$WORKDIR/family_prefix.awk" | command wc -c | command tr -d ' ')"
    local fp_ok="no"
    [ "$fp_lines" -gt 1 ] && [ "$fp_opens" = "$fp_closes" ] && fp_ok="yes"
    assert_equals "yes" "$fp_ok" \
        "the extracted awk family_prefix is non-empty and brace-balanced (${fp_lines} lines, ${fp_opens} open / ${fp_closes} close)"

    {
        command cat "$WORKDIR/family_prefix.awk"
        command printf '%s\n' 'BEGIN { FS = "\t"; bad = 0 }'
        command printf '%s\n' '{ got = family_prefix($1); if (got != $2) { bad++; printf "FAIL awk family_prefix(<%s>) -> <%s>, expected <%s>\n", $1, got, $2 } }'
        command printf '%s\n' 'END { if (bad == 0) print "OK" }'
    } >"$WORKDIR/family_prefix_drive.awk"

    # Same rows as the Python table above, in the same order — the two tables
    # are one case list expressed twice, so a row added to one belongs in both.
    awk_out="$(command printf '%s\n' \
        "parse_entry	parse" \
        "parse_header_body	parse" \
        "parseEntry	parse" \
        "ParseEntry	parse" \
        "parse	parse" \
        "HTTPServer	http" \
        "XMLParser	xml" \
        "IOError	io" \
        "XMLHttpRequest	xml" \
        "PARSE	parse" \
        "MAX	max" \
        "IO	io" \
        "MAX_RETRIES	max" \
        "_private	_private" |
        LC_ALL=C command awk -f "$WORKDIR/family_prefix_drive.awk")"
    assert_equals "OK" "$awk_out" \
        "family_prefix: the awk twin produces the same family for every rule (#772)"
}

run_test test_corpus_non_empty "Python-port corpus is non-empty (gate is not a no-op)"
run_test test_every_force_bash_var_is_set "Every port's *_FORCE_BASH var is set by the parity test (#695)"
run_test test_py_is_test_file_direct "check-code-health/patterns.py: is_test_file called directly, both branches (#605)"
run_test test_py_debug_family_direct "check-code-health/patterns.py: debug families called directly + emission order (#687)"
run_test test_py_read_yaml_list_direct "check-code-health/patterns.py: _read_yaml_list quote/whitespace/section rules match the bash twin (#686)"
run_test test_py_md_slug_direct "md_slug: both Python lenses and the shared awk twin agree (#730)"
run_test test_py_family_prefix_direct "family_prefix: both Python lenses and the awk twin agree (#772)"

while IFS= read -r py; do
    [ -n "$py" ] || continue
    CUR_PY="$py"
    rel="${py#"$PLUGINS_DIR"/}"
    run_test test_python_edgecases "$rel: edge-case contract (no-arg exit 1, empty-list exit 0)"
    run_test test_python_bash_parity "$rel: bash<->python TSV parity"
    run_test test_python_bash_guard_exit_parity "$rel: input-guard exit-code parity (#816)"
done <<<"$ports_list"

generate_report
