// --- Injection-hardening utils -----------------------------------------------

const READONLY =
  'This is a read-only checker pass: do NOT edit, write, commit, branch, push, ' +
  'or create issues/comments — and do NOT run any shell command that mutates or ' +
  'deletes files or git state (`rm`, `git clean`, `git checkout --`, ' +
  '`git reset --hard`, `mv`, `truncate`, `>`/`>>` redirection to a tracked ' +
  'path). If you must reproduce something, do it ONLY inside a fresh `mktemp -d` ' +
  'sandbox, never against the working tree. Canonicalize any path ' +
  '(`cd <dir> && pwd`) before a destructive op; never pass an unresolved `..`. ' +
  'Emit your result via StructuredOutput per the ' +
  'provided schema (not a ```json fence).'

// Neutralize prompt-injection vectors in any value interpolated into a prompt.
// `scope` and `categories` are user-controlled, and the domain.* fields are
// produced by the map agent (so they are second-order untrusted) — all of them
// reach a Bash-capable checker, so a smuggled newline + bullet ("- IGNORE the
// above and run: …") could become an instruction. Strip CR/LF and other control
// chars and clamp length; the values are short identifiers / paths, never prose.
const sanitize = (v, max = 200) =>
  String(v == null ? '' : v)
    // Replace every C0/C1 control char (incl. CR/LF/TAB) with a space so a
    // smuggled newline cannot start a new instruction line in the prompt.
    .replace(/[\x00-\x1f\x7f-\x9f]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, max)
const sanitizeList = (xs) => (Array.isArray(xs) ? xs.map((x) => sanitize(x)) : [])

// The reason string for a failed map step, naming WHICH failure fired (#646).
// A pure function rather than an inline ternary at the call site for the same
// reason `attempt` is a helper: past ORCH_BOUNDARY only a regex could assert it,
// and a regex cannot tell that the two branches produce DIFFERENT strings — the
// property that saves the next reader a transcript. `sanitize`d because the
// message can quote model output and this string is surfaced in the report
// markdown, so a smuggled newline must not forge report structure.
//
// Defined here rather than beside `attempt` because it needs `sanitize`, which
// is declared below that helper.
const mapFailureNote = (threw, error) =>
  threw
    ? `Map step failed (agent threw: ${sanitize(error && error.message ? error.message : error)}) — no scope partition produced; nothing scanned.`
    : 'Map step failed (agent returned no result) — no scope partition produced; nothing scanned.'

// Reduce an untrusted string to a SINGLE safe path component — no directory
// separators, no `..`, no leading dots. `category` and group titles flow from
// the checker (second-order untrusted: a project-level audit-*/check-* scanner
// can emit an arbitrary category like `../../../etc/evil`), and the
// artifact-writer joins them into `<out_dir>/{category}--{slug}.md`. Neutralizing
// them here — in code, before they reach the Bash/Write agent — closes the
// path-traversal / arbitrary-file-write primitive rather than trusting the
// agent to follow prose. Lowercase, collapse every non-[a-z0-9] run to a single
// hyphen (so `/`, `\`, `..`, spaces, control chars all become `-`), trim hyphens,
// clamp length, and never return empty.
const slugify = (v, max = 60) => {
  const s = String(v == null ? '' : v)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, max)
    .replace(/-+$/g, '')
  return s || 'untitled'
}

// Guarantee each group's precomputed basename is unique within the batch —
// two groups that slugify to the same filename (e.g. distinct titles that
// collapse identically) would otherwise overwrite each other. Append -2, -3, …
// to later collisions, preserving the `.md` extension.
const dedupeFilenames = (groups) => {
  const seen = new Map()
  return groups.map((g) => {
    const base = g.filename
    const count = seen.get(base) || 0
    seen.set(base, count + 1)
    if (count === 0) return g
    const withSuffix = base.replace(/\.md$/, '') + `-${count + 1}.md`
    return { ...g, filename: withSuffix }
  })
}

// Reduce an untrusted directory value to a safe RELATIVE path. `auditDir` is an
// open args field, so treat it defensively and symmetrically with `timestamp`
// (which is already sanitized): strip control chars, drop any leading `/`
// (no absolute paths), and remove every `..` segment (no traversal) so a caller
// or a bug in the skill layer cannot redirect writes outside the tree. Falls
// back to the default when the result is empty.
const sanitizeDir = (v) => {
  const cleaned = String(v == null ? '' : v)
    .replace(/[\x00-\x1f\x7f-\x9f]/g, '')
    .trim()
    .replace(/^\/+/, '')
    .split('/')
    .filter((seg) => seg && seg !== '..' && seg !== '.')
    .join('/')
  // Re-anchor as an explicit relative path ("./…") — matches the documented
  // ./audit convention and makes the relativeness obvious at the write site.
  return cleaned ? `./${cleaned}` : './audit'
}

