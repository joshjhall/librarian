
// The four `nature` observations the judge may report, and the rule names
// `dispositionOf` may return. Both are named once here because THREE consumers
// must agree on them: the judge schema's enum, the disposition rule list, and
// the per-cycle `by_nature` / `by_rule` tallies (#613). A tally whose keys drift
// from the policy silently under-counts the very thing it exists to measure.
//
// The tallies treat these as the *known* keys to pre-seed at zero, not as an
// allow-list: a value outside them is still counted (under its own key) rather
// than dropped. So adding a fifth nature or a ninth rule without updating this
// list degrades to "the new key is missing its zero row", never to "the new key
// is invisible" — the failure mode that would make a desync unnoticeable.
const NATURE_VALUES = [
  'defect-in-new-code',
  'defect-in-preexisting-code',
  'incomplete-work',
  'improvement',
]

const DISPOSITION_RULES = [
  'R1-critical',
  'R2-low-certainty',
  'R3-security-high',
  'R4-improvement',
  'R5-preexisting',
  'R6-incomplete',
  'R7-large-effort',
  'R8-defect-in-new-code',
]

// Count `values` into an object pre-seeded with `keys` at zero. Pre-seeding is
// the point: a rule that fired zero times this cycle must report `0`, not be
// absent, or a reader cannot distinguish "never fired" from "not measured" —
// and a rule that never fires in production is exactly the signal #613 wants
// (it is either dead or mis-ordered). Unknown values are counted under their own
// key rather than dropped (see the NATURE_VALUES note above).
// `Object.create(null)`, not `{}`, because `values` carries LLM-supplied strings
// (`nature` comes straight off the judge's verdict). On a plain object literal
// `out['__proto__'] = n` hits the inherited setter, which ignores a numeric
// assignment — so that value is silently SWALLOWED: no own key, no count, no
// error. That is the one outcome a counting function must not have, and it would
// break the "unknown values are counted, never dropped" property directly above.
// A null-prototype object has no such setter, so every key is an ordinary own
// property and the count is honest whatever the judge emits.
const tallyBy = (values, keys) => {
  const out = Object.create(null)
  for (const k of keys) out[k] = 0
  for (const v of values) {
    if (v === undefined || v === null) continue
    out[v] = (out[v] || 0) + 1
  }
  return out
}

// The two #613 distributions for one cycle. Extracted here — before the
// orchestration body, like `computeClean` and `applyJudgeVerdicts` — so the
// composition is unit-testable: that `rawFindings` really do carry `.nature` /
// `.disposition_rule` by the time they are counted is the part that can silently
// regress, and inline in the return object it could only be tested by running
// the whole harness.
//
// Reads the WHOLE finding set, blocking and deferrable alike: the question this
// measurement exists to answer is whether the deferrable bucket is holding real
// new-code defects, which a blocking-only count cannot see.
const summarizeJudgeObservations = (rawFindings) => ({
  by_nature: tallyBy(rawFindings.map((f) => f.nature), NATURE_VALUES),
  by_rule: tallyBy(rawFindings.map((f) => f.disposition_rule), DISPOSITION_RULES),
})
