
// ---------------------------------------------------------------------------
// `sanitize`, `stableStringify`, and `dataBlock` now come from the shared
// prelude (#586) — see 15-prelude.js, generated from plugins/lib/prelude.js.
// This file keeps only the notes SPECIFIC to this harness, which the prelude's
// own comments do not carry:
//
//   - `sanitize` is applied to the ISSUE TITLE, which is attacker-controlled on
//     a public repo and can carry newlines via the API. It is interpolated BARE
//     (not inside a data block), which is why the control-char strip matters
//     here rather than being belt-and-braces.
//
//   - The scope-drift dimension calls `sanitize` at MODULE LOAD (see
//     30-dimensions.js), so the prelude fragment MUST stay above that file in
//     manifest.txt. Reversed, it is a temporal-dead-zone throw on the
//     `issue`-truthy branch only — invisible to a test that extracts without an
//     issue. That is #260 exactly.
//
//   - `dataBlock` fences the diff, PR review comments, and finding text that
//     quotes attacker-controlled source. Array order is PRESERVED by
//     stableStringify (load-bearing wherever findings are ref-indexed); only key
//     order is normalized. The standing review instructions are anchored BEFORE
//     the block in every prompt builder, so the directive is read first.
// ---------------------------------------------------------------------------
