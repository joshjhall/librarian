
// The complete `args` contract (#597). Every key below is read by one of the
// `args.<key>` accesses that follow; this list is the machine-readable twin of
// the header comment block above (lines ~14-35) and MUST stay in sync with it —
// a key documented there but missing here is rejected at dispatch, and a key
// here but undocumented there is an input no caller knows to pass. The test
// suite pins that sync (tests/workflow-helpers/ship-issue.mjs).
//
// Order matches the header block so a reader can diff the two by eye.
const KNOWN_ARG_KEYS = [
  'phase',
  'cycle',
  'maxCycles',
  'files',
  'diff',
  'prComments',
  'issue',
  'tokenCeiling',
  'preScan',
  'conventionsDigest',
  'reviewRoute',
  'deltaDiff',
  'deltaFiles',
  'priorBlockingDimensions',
]

// Why this exists: every `args.<key>` read below is guarded by a type check that
// falls back to an empty default, so an input passed under a WRONG key is
// silently dropped and the cycle reviews less than the caller believes — or,
// when the dropped key is `diff`, nothing at all. That produces `clean: true`
// from a review that never happened, byte-identical in the output to a genuine
// pass. Measured instance (#567): a cycle dispatched with `argsFile` instead of
// the inline inputs dropped `diff`, `preScan` AND `conventionsDigest`; five
// reviewers ran against an empty diff and returned zero findings. Since `clean`
// is half the merge invariant, at L4 that auto-merges.
//
// A typo'd key is always a caller bug, never intent, so the caller wiring this
// up gets a loud throw (repo runtime policy: fail loud, never emit a wrong-but-
// plausible result). Returns the offending keys as a LIST so the message can
// name all of them — a caller that mistyped two keys should not have to
// re-dispatch twice to learn that.
//
// Total by construction: a null/undefined/non-object `args` is the legitimate
// no-input case every read above already tolerates, so it yields [] rather than
// throwing.
const unknownArgKeys = (a) =>
  a && typeof a === 'object' && !Array.isArray(a)
    ? Object.keys(a).filter((k) => !KNOWN_ARG_KEYS.includes(k))
    : []

// Whether this cycle has nothing of its own to review (#597, AC#3). A pure
// predicate rather than an inline condition in the orchestration body so it can
// be unit-tested directly: the `log()` call it guards sits past ORCH_BOUNDARY
// and cannot be reached by the extractor, and a structural source-grep alone
// would not catch the boolean logic being inverted (`||` for `&&`).
//
// Guards BOTH inputs deliberately: a narrowed re-review cycle legitimately
// carries only `deltaDiff`, so testing `scopeDiff` alone would warn on a cycle
// that has plenty to read.
const noDiffSupplied = (fullDiff, delta) => !fullDiff && !delta

const PHASE = args && args.phase === 'pr-cycle' ? 'pr-cycle' : 'pre-pr'
const CYCLE = args && Number.isInteger(args.cycle) ? args.cycle : 1
// Mirrors REVIEW_MAX_CYCLES' default (#596 raised it 3 -> 5). Informational
// here — the harness runs exactly one cycle and the SKILL owns the loop — but a
// stale default would misreport "cycle 2 of 3" in this cycle's own log line.
const MAX_CYCLES = args && Number.isInteger(args.maxCycles) ? args.maxCycles : 5
const scopeFiles = args && Array.isArray(args.files) ? args.files.filter(Boolean) : []
const scopeDiff = args && typeof args.diff === 'string' ? args.diff : ''
const prComments = args && Array.isArray(args.prComments) ? args.prComments.filter(Boolean) : []
const issue = args && args.issue && typeof args.issue === 'object' ? args.issue : null

// Re-review narrowing inputs (#492), all optional — absent ⇒ full review. The
// skill computes these each re-review cycle (it owns git; this sandbox does not):
// the fix-commit delta since the last reviewed SHA, and which dimensions blocked
// last cycle. `narrowingActive` below decides whether they take effect.
const deltaDiff = args && typeof args.deltaDiff === 'string' ? args.deltaDiff : ''
const deltaFiles = args && Array.isArray(args.deltaFiles) ? args.deltaFiles.filter(Boolean) : []

// Deterministic pre-scan candidates from pre-review-gates.sh (#556), optional.
// That scanner already runs at Step 3.5 item 5 and its TSV was discarded before
// item 6, so five reviewers re-derived the same ground by shelling out (measured:
// the `tests` dimension spends 9-42 turns per cycle rediscovering roughly what
// scan_missing_tests / scan_untested_public_api already computed; reviewers make
// no Grep calls at all, exploring via Bash at ~50-80k cache_read each).
//
// These are CANDIDATES, never findings. The scanner is a regex matcher: it
// cannot see cross-directory tests, project conventions, or intent. #555 is the
// standing proof — run against PR #554's own diff it emitted two HIGH-certainty
// missing-test-file / untested-public-api hits for a file covered by 28 test
// references. So they enter the prompt as things to confirm or dismiss, and a
// reviewer that dismisses one is doing its job.
//
// Cap the count so a pathological scan (thousands of hits on a large diff)
// cannot displace the diff itself from the prompt. Truncation is logged, never
// silent — a silently trimmed candidate list would read as "the scanner found
// nothing else", which is exactly the false-completeness this repo guards
// against elsewhere.
const PRESCAN_MAX = 100
const preScanAll =
  args && Array.isArray(args.preScan)
    ? args.preScan.filter(
        (c) => c && typeof c === 'object' && typeof c.file === 'string' && c.file && typeof c.category === 'string' && c.category
      )
    : []
const preScan = preScanAll.slice(0, PRESCAN_MAX)
const preScanTruncated = preScanAll.length - preScan.length

// Distilled project-conventions digest (#557), optional. The caller reads
// CLAUDE.md / AGENTS.md / directory-level CLAUDE.md / .claude/memory/*.md ONCE
// and passes a short rule summary, instead of every reviewer in the fan-out
// re-reading those files (measured: 19 doc-read Bash calls across three cycles,
// on top of the 164 hand-measurement calls the lint clause above targets).
//
// Capped: a digest is a summary, and an oversized one would displace the diff
// it is meant to contextualize. Truncation is disclosed in-prompt for the same
// reason as preScan's — a silently trimmed rule list reads as a complete one,
// which would invite a reviewer to conclude a real convention does not exist.
const DIGEST_MAX_CHARS = 4000
const conventionsDigestRaw =
  args && typeof args.conventionsDigest === 'string' ? args.conventionsDigest.trim() : ''
const conventionsDigest = conventionsDigestRaw.slice(0, DIGEST_MAX_CHARS)
const conventionsDigestTruncated = conventionsDigestRaw.length > conventionsDigest.length

// Routing verdict from scripts/review-route.sh (#550), optional. `cheap` means
// the caller's classifier proved this diff is doc/config-only, so the
// source-reading dimensions (security, correctness, tests, decomposition) have
// nothing to review and only `scope-drift` runs.
//
// PARSED AS AN ALLOWLIST OF ONE, and that direction is the entire safety
// property. Anything that is not the exact string 'cheap' — a typo, a null, a
// number, an object, an absent key — yields 'full'. A malformed value must
// widen the review, never narrow it: the failure mode of guessing wrong in the
// other direction is a diff that merges having never been read by the security
// or correctness dimensions.
//
// WHY THIS DOES NOT FORGE `clean`. A routed cycle is COMPLETE-BY-DESIGN, not
// truncated — the same status as a dimension narrowing already grants (#492) —
// so it deliberately does NOT set budgetExhausted or dimensions_skipped, and
// `computeClean` is untouched. That is only sound because safety rests on the
// CLASSIFIER, never on the reviewers: review-route.sh routes `cheap` solely
// when every file classified doc or config, and resolves every ambiguity
// (unknown extension, empty list, bad input) to `full`. Read that script's
// header before loosening anything here.
const reviewRoute = args && args.reviewRoute === 'cheap' ? 'cheap' : 'full'
// Caller-supplied output-token ceiling for THIS cycle (#553), optional.
// Without it the harness is unbounded in practice: every budget gate below is
// guarded on `budget.total`, which the Workflow runtime populates ONLY from a
// user "+500k"-style turn directive. In a golem run no such directive exists, so
// `budget.total` is null, `budget.remaining()` is Infinity, and BUDGET_FLOOR /
// TAIL_FLOOR never fire — the graceful-degradation path is dead code exactly
// when it is needed most. Measured consequence (#471/#472, 3 cycles, deduped by
// message.id): 32.2M cache_read / 660k output, with one `security` agent alone
// spending 128 turns and 115 Bash calls ranging over the whole repo.
//
// `budget.spent()` DOES work when `total` is null (it returns output tokens
// spent this turn regardless), so we derive our own remaining-budget view from a
// baseline captured at script start. That makes the ceiling caller-controlled
// per invocation rather than turn-global, which is what a per-cycle bound wants.
const CYCLE_TOKEN_CEILING =
  args && Number.isInteger(args.tokenCeiling) && args.tokenCeiling > 0 ? args.tokenCeiling : 0
const SPENT_AT_START = budget.spent()

// The budget view every gate below consults. Prefers the runtime's own budget
// when a turn directive armed one (`total` non-null) — that is a real hard
// ceiling the runtime enforces by throwing, and we must not paper over it.
// Otherwise falls back to the caller-supplied per-cycle ceiling. When neither is
// armed this degrades to the pre-#553 unbounded behavior (total null / remaining
// Infinity), so omitting `tokenCeiling` changes nothing.
const reviewBudget = {
  get total() {
    return budget.total || (CYCLE_TOKEN_CEILING || null)
  },
  spent: () => budget.spent() - SPENT_AT_START,
  remaining: () => {
    if (budget.total) return budget.remaining()
    if (!CYCLE_TOKEN_CEILING) return Infinity
    return Math.max(0, CYCLE_TOKEN_CEILING - (budget.spent() - SPENT_AT_START))
  },
}

const priorBlockingDimensions =
  args && Array.isArray(args.priorBlockingDimensions)
    ? args.priorBlockingDimensions.filter((d) => typeof d === 'string' && d)
    : []
