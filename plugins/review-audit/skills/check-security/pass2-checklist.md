# audit-security — Pass 2 categories and checklist

On-demand companion for `plugins/review-audit/agents/audit-security.md`. It
carries the agent's full category list: what each one looks for, how severity
splits, and what evidence a finding must record.

**It lives here, in `check-security/`, rather than beside the agent** because it
is one half of a pair. `owasp-coverage.yml` in this same directory maps every
category to the pass that owns it, and `tests/validate-owasp-coverage.sh` reads
BOTH files to check the two agree — every `owner: llm-pass2` id must have
backing text here, and every category here must have a row there. Keeping them
in one directory makes that coupling visible to whoever edits either.

**Two consumers read this file, so it has two ways to break silently.** The gate
above resolves it as `PASS2_DOC`; if that path stops resolving, every
`llm-pass2` claim reports unbacked — loud, which is the intended failure. The
agent's batch sub-agent prompt template also splices this content into each
worker's prompt; an unresolved include there yields an EMPTY checklist and a
context-free scan that still returns valid JSON. That one is silent. If you move
or rename this file, update both call sites and assert the prompt actually
contains checklist text.

Every category below is `heuristic`, never `deterministic` — see the agent's
Certainty Assignment table for why that is the point of this pass rather than an
admission about it.

## hardcoded-secret

- Search for API keys, tokens, passwords, connection strings in source code
- Patterns: password assignment literals, `api_key`, `secret`, `token`,
  `Bearer`, `Authorization`, AWS access keys (`AKIA`), private key headers
- Ignore: test fixtures with obviously fake values, environment variable reads,
  placeholder strings like `xxx`, `changeme`, `TODO`
- Severity: critical (real credentials), high (ambiguous)
- Evidence: the line, what type of secret it appears to be

## injection

- SQL: string concatenation or f-strings in SQL queries instead of
  parameterized queries
- Command: unsanitized user input passed to shell execution functions
  (any function that spawns a shell process with string interpolation)
- Template: unescaped interpolation in HTML templates
- Severity: critical (user-reachable), high (indirect input)
- Evidence: the vulnerable pattern, input source

Path traversal used to live here as a one-line sub-bullet. It is now its own
category below — it is an A01 access-control failure, not an A03 injection, and
burying it here meant it inherited injection's severity split and its evidence
rules, both of which are wrong for it.

## path-traversal

- User-controlled input reaching a filesystem path without normalization or a
  containment check
- **Positive signal**: the path is built from a request value (route param,
  query string, upload filename, header) and the code either never resolves it
  to an absolute path, or resolves it but never asserts the result stays under
  an intended root
- Archive extraction that writes entry names straight to disk (zip-slip): the
  entry name is attacker-supplied and may contain `..` or an absolute path
- **Not a finding**: a path built only from literals, config, or an id already
  validated against an allowlist; a `..` that cannot survive the normalization
  the code demonstrably performs
- Severity: critical (write, or read of a path the caller names outright), high
  (read constrained by an extension or prefix an attacker may still escape)
- Evidence: the request value, the path expression it flows into, and the
  containment check that is missing — name the check, do not just say "unsafe"

## xss

- User-controlled data rendered in HTML without escaping
- Look for framework-specific patterns that bypass auto-escaping: raw HTML
  setters in React, Vue, Blade, Jinja, Django, and similar frameworks
- Severity: high (user-reachable), medium (admin-only)
- Evidence: the rendering pattern, data source

## auth-bypass

Two distinct failures live here, and the second is the one checklists usually
miss.

**Route-level (authentication) — is the caller anyone at all?**

- Missing authentication checks on route handlers or API endpoints
- Inconsistent auth middleware application across similar routes
- Default credentials or bypass flags in non-test code
- Severity: critical (public endpoints), high (internal)
- Evidence: the unprotected endpoint, nearby protected endpoints for comparison

**Object-level (authorization) — is the caller *this resource's* owner?**

This is the single most common real vulnerability in application code, and it is
invisible to route-level checks: the handler authenticates correctly, then loads
a record by an id taken straight from the request and never asks whether that
record belongs to the caller.

- **Positive signal**: a resource id arrives from the request (path param, body
  field, query string) and reaches a lookup whose filter names *only* that id —
  no owner/tenant/organization predicate, and no post-load ownership assertion
- Look for the asymmetry: a sibling handler in the same file that *does* scope
  its query by the session subject is strong evidence the unscoped one is a bug
  rather than a deliberate public read
- Mass-assignment's authorization half: a request body spread into an update
  where the writable fields are not restricted, letting a caller set a column
  (`role`, `owner_id`, `account_id`) that decides authorization
- **Not a finding**: a lookup whose id is not attacker-supplied; a genuinely
  public resource; a query already scoped by the session subject somewhere the
  handler can be shown to reach (a scoped repository, a row-level-security
  policy, a tenant-bound connection)
- Severity: critical (write or delete, or a read of another tenant's data), high
  (read of another user's data within one tenant)
- Evidence: the id's request origin, the lookup with its full filter, and the
  ownership predicate that is absent — plus the scoped sibling handler when one
  exists, because that comparison is what makes the finding concrete

## data-exposure

- Sensitive data in logs (passwords, tokens, PII, credit card numbers)
- Error responses leaking stack traces, internal paths, or database details
- Overly permissive CORS configuration (wildcard origins)
- Sensitive data in URL query parameters (logged by web servers)
- Severity: high (PII/credentials), medium (internal details)
- Evidence: the exposure pattern, what data is leaked

## insecure-crypto

- MD5 or SHA1 used for security purposes (password hashing, signatures)
- ECB mode encryption, static IVs, hardcoded encryption keys
- Weak random number generators used for security tokens (non-CSPRNG
  functions like language-default random instead of cryptographic random)
- Severity: high (password hashing), medium (other uses)
- Evidence: the algorithm/function, what it's used for

## ssrf

- A server-side request whose destination is influenced by user input
- **Positive signal**: a request value reaches the *host* portion of a URL passed
  to an outbound HTTP client. Influence over the path or query only is weaker and
  usually not a finding on its own — say which portion is attacker-controlled
- Highest-value shapes: webhook/callback URLs accepted from a request, "fetch
  this URL for me" features (link preview, avatar import, PDF render), and any
  redirect the client is configured to follow, which can turn a validated host
  into an unvalidated one on hop two
- Cloud metadata endpoints are the usual escalation target, so a fetcher with no
  allowlist is more serious wherever an instance role exists
- **Not a finding**: a hardcoded host with only an interpolated port or path; a
  destination chosen from a fixed allowlist; a client explicitly configured not
  to follow redirects and pointed at an internal-only service by design
- Severity: high (arbitrary host, or redirect-following), medium (path/query
  influence only, or an allowlist with a plausible bypass)
- Evidence: the request value, the URL construction, the HTTP client call, and
  the redirect policy if it is set

## insecure-deserialization

The pre-scan already flags the dangerous *sinks* deterministically
(`pickle.loads`, `yaml.load` without a safe loader, Java `readObject`, PHP
`unserialize`). Do not re-report what it found. This pass answers the question it
cannot: **is the input untrusted?**

- **Positive signal**: bytes that crossed a trust boundary — a request body,
  cookie, cache/queue entry an attacker can write, or an uploaded file — reach a
  deserializer that can construct arbitrary types or invoke code on load
- Session or token state deserialized from a client-supplied cookie is the
  classic instance: the value round-trips through the attacker
- **Not a finding**: deserializing a literal, a build artifact, or a file the
  application itself wrote earlier in the same trust domain; a safe loader
  (`yaml.safe_load`, a schema-bound parser) already in use
- Severity: critical (request-reachable, gadget-capable format), high (reachable
  only via a store an attacker must first compromise)
- Evidence: the untrusted source, the path it takes to the sink, and the format's
  capability — say *why* this deserializer can execute, not merely that it is one

## insecure-design

A04 is about a missing control rather than a broken one, which makes it the
easiest category to fill with noise. **Report a design flaw only when you can
name the concrete abuse it permits.** "No threat model" is not a finding;
"password reset issues a 6-digit code with no attempt limit, so it is brute
forceable in minutes" is.

- Worth reporting: a security-relevant flow with no rate limit or lockout
  (login, password reset, OTP, invite); a trust boundary crossed with no control
  at all (a client-supplied price, quantity, or role honored by the server); a
  recovery flow that bypasses the primary control's strength; an unbounded
  resource an unauthenticated caller can drive
- Architectural noise — do NOT report: preferring a different framework or
  architecture; "should use defense in depth"; a missing control that is
  demonstrably enforced one layer up; anything whose remediation you cannot
  state as a specific change to this codebase
- Severity: high (an abuse with direct security impact), medium (a weakness that
  needs another precondition)
- Evidence: the flow, the control that is absent, and the abuse sequence it
  permits — three concrete steps, not a principle

## logging-monitoring

A09 is an **absence**, which is why no pattern can match it and why it needs a
tighter rule than the rest of this checklist: report a missing audit trail only
for actions where the trail is the control. Otherwise this category becomes a
request to log everything.

- Worth reporting: authentication events (especially failures), authorization
  denials, privilege and role changes, credential or key rotation, and
  destructive or bulk data operations that leave no record of *who* did them
- Also a finding, and a more serious one: logging that actively destroys
  evidence — a swallowed security exception, or an audit write inside a `try`
  whose failure is ignored
- Inverse failure, report it here too: a log line that records the credential,
  token, or PII itself. That is `data-exposure` when it leaks and A09 when it
  makes the audit log a liability — pick one category, do not file both
- **Not a finding**: read paths, routine CRUD with no security significance, or
  any absence you cannot tie to an action whose accountability matters
- Severity: medium (missing trail on a privileged action), low (incomplete
  context on an action that is otherwise logged)
- Evidence: the action, where a log call would go, and what an incident
  responder cannot reconstruct without it

## missing-validation

- User input accepted without type checking, length limits, or format
  validation at API boundaries
- Missing bounds checks on array indices or numeric ranges
- Missing null/undefined checks on external data
- Severity: medium (may cause errors), high (may cause security issues)
- Evidence: the unvalidated input, what boundary it crosses

## dependency-cve

- Check for known-vulnerable dependency patterns (e.g., pinned to a version
  with known CVEs if version info is visible in lock files or config)
- Outdated security-sensitive dependencies (crypto libraries, auth frameworks)
- Severity: varies by CVE severity
- Evidence: the dependency, version, known issue if identifiable
