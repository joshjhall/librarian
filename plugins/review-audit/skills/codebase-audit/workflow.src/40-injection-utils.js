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

// `sanitize` comes from the shared prelude (#586) — see 15-prelude.js. Why it
// matters HERE specifically: `scope` and `categories` are user-controlled, and
// the domain.* fields are produced by the map agent (so they are second-order
// untrusted) — all of them reach a Bash-capable checker, so a smuggled newline
// + bullet ("- IGNORE the above and run: …") could become an instruction. The
// values are short identifiers / paths, never prose, so the 200-char clamp is
// generous rather than lossy.
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


// --- Memory-bundle redaction (issue #698) ------------------------------------

// The memory domain's audit categories. Conformance (`okf-*`) and whole-bundle
// health (`memory-*`) come from check-okf-conformance; the semantic five come
// from the audit-memory agent. Used as a SECONDARY key below — the domain
// prefix on `ref` is the primary one.
const MEMORY_CATEGORY_RE = /^(okf|memory)-/

// A memory-domain finding's `ref` is stamped `<domain>:<file>:<line>:<category>#<i>`
// by stampRefs, so the domain name is the leading segment. That is the reliable
// signal: it comes from the harness's own map step, not from the scanner's
// self-reported `category`, which a project-level scanner could spell anything.
const MEMORY_DOMAIN = 'memory'

const isMemoryFinding = (f) => {
  if (!f || typeof f !== 'object') return false
  const ref = typeof f.ref === 'string' ? f.ref : ''
  if (ref.slice(0, ref.indexOf(':')) === MEMORY_DOMAIN) return true
  return MEMORY_CATEGORY_RE.test(String(f.category || ''))
}

// The redaction cap from audit-memory.md § Redaction: a fragment of a
// frontmatter value or a heading, capped at 80 characters.
const MEMORY_FRAGMENT_CAP = 80

// `title` gets the schema's own 120-char ceiling rather than the 80-char
// fragment cap. It is a one-line summary and is legitimately the agent's own
// prose (which § Redaction permits), so clamping it to 80 would truncate honest
// titles — but leaving it untouched would be a hole: 120 characters of a body
// pasted into a title still reaches the tracker, and the title is the most
// visible field there is. Flattening is what closes it; the cap merely matches
// what the schema already enforces.
const MEMORY_TITLE_CAP = 120

// Collapse a value to a single line and clamp it to the cap. A memory body is
// multi-line prose, so flattening newlines is itself part of the defense: it
// prevents a body from surviving as a run of "short" lines, and it keeps a
// smuggled markdown structure from forging sections in a rendered issue body.
const clampFragment = (v, cap = MEMORY_FRAGMENT_CAP) => {
  const flat = String(v == null ? '' : v)
    .replace(/[\x00-\x1f\x7f-\x9f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
  return flat.length <= cap ? flat : `${flat.slice(0, cap - 1).trimEnd()}…`
}

// Strip memory-bundle CONTENT from the findings that reach the issue path.
//
// WHY THIS IS CODE AND NOT PROSE (#698). audit-memory.md already states the
// rule ("a finding must never carry a memory's body"), and prose is exactly
// what issue #698 rejects as insufficient: `issue-writer` posts to a REMOTE, so
// one agent that forgets publishes a developer's private notes to a public repo,
// irreversibly. A guarantee that depends on an agent remembering is not a
// guarantee. This runs in the harness, on every memory finding, unconditionally.
//
// WHY IT REWRITES RATHER THAN OMITS. `description`, `evidence` and `suggestion`
// are REQUIRED by finding-schema.schema.json — deleting them would emit a
// schema-invalid finding, so each is replaced by a bounded value rather than
// dropped. What survives is what makes a finding actionable without quoting the
// bundle: the path, the line, the category, the certainty, and an 80-char
// fragment. A reader who needs the body runs the artifact objective, which is
// the path issue #698 names as safe and which this function deliberately does
// not touch.
const redactMemoryFindings = (findings) =>
  (Array.isArray(findings) ? findings : []).map((f) => {
    if (!isMemoryFinding(f)) return f
    const where = `${f.file || '(unknown file)'}:${f.line_start == null ? '?' : f.line_start}`
    return {
      ...f,
      description:
        `Memory-bundle finding in ${where} (category: ${clampFragment(f.category)}). ` +
        `Body withheld — run the audit with the files objective to read the full ` +
        `finding under ./audit/{timestamp}/.`,
      title: clampFragment(f.title, MEMORY_TITLE_CAP),
      evidence: clampFragment(f.evidence),
      suggestion: clampFragment(f.suggestion),
      // The three fields below are not rendered by today's ISSUE_TEMPLATE, but
      // the issue-writer receives the whole object and composes the body itself
      // — so each is a leak path that merely happens not to be taken right now.
      // Clamp them rather than trust the renderer: the guarantee must not depend
      // on a template that a future edit may change.
      //
      // All three are populated by the same scan agent that just READ the
      // bundle, so they are exactly as untrusted as `evidence` — and a memory
      // body redirected into one of them would walk straight past a redactor
      // that only covered the obvious fields. `category` and `related_files`
      // are schema-typed as an unconstrained string and string[] respectively
      // (finding-schema.schema.json), so neither has a length bound of its own.
      // The invariant this restores is simple and checkable: on a memory
      // finding, NO string reaches issueWriterPrompt without passing through
      // clampFragment.
      category: clampFragment(f.category, 40),
      tags: Array.isArray(f.tags) ? f.tags.map((t) => clampFragment(t, 40)).filter(Boolean) : [],
      related_files: Array.isArray(f.related_files)
        ? f.related_files.map((r) => clampFragment(r, MEMORY_FRAGMENT_CAP)).filter(Boolean)
        : [],
    }
  })
