---
name: issue-399-agnix-sarif-ci
description: "#399 SHIPPED PR #460 — agnix SARIF code-scanning CI gate (ADR-0001 spine item 5)"
metadata: 
  node_type: memory
  type: project
  originSessionId: 8f06375c-d241-424f-9c24-0aa4df7251ff
  modified: 2026-07-21T03:55:00.113Z
---

# 399 SHIPPED as PR #460 (2026-07-20, L3). New `.github/workflows/code-scanning.yml`

runs `agnix --format sarif` over the repo's own AI-config artifacts and uploads to
GitHub code scanning. Blockers #397 (normalizer, CLOSED) + `.agnix.toml` (present)
both resolved before start. Fifth of six ADR-0001 follow-ups; `Closes #399` correct
(the item is whole, umbrella is #238 — referenced not closed). See [[umbrella-issue-closes-vs-contributes]].

**Design (all per ADR-0001):** SEPARATE workflow, not a job in ci.yml — SARIF upload
needs `security-events: write` and ci.yml is deliberately least-privilege
`contents: read`; gate is informational (outside merge-gate, like coverage). Fork
PRs skip (security-events token withheld — same guard ci.yml uses). agnix pinned
`0.40.0` (no @latest, §5). `--config .agnix.toml` (operator-controlled). No `--fix*`
(§4). Scope `CLAUDE.md AGENTS.md plugins` — EXCLUDES pinned containers/ submodule +
.claude/memory scratch a bare `.` pulls in.

**Adversarial review catch (medium, real):** blanket `|| true` on the agnix run
masks a genuine CRASH the same as expected findings-nonzero. agnix exits non-zero
BOTH when it finds issues (SARIF valid, must upload) AND when it crashes (bad flag /
panic / unparsable config / incompatible pin bump → empty/invalid SARIF). A blanket
`|| true` there reads a crash as a clean "0 findings" scan forever, no signal. FIX =
validate output before upload: `[ -s agnix.sarif ] && jq -e '.runs'` → sarif=true
(upload) else `::warning::` + skip upload (signal, still not a hard fail). Mirrors the
empty-output RuntimeError guard in sibling agnix-normalize.py. Lesson: `|| true` on a
tool that is non-zero-on-findings must still distinguish crash-empty from
found-issues — validate the artifact, don't blanket-swallow.

**codeql-action pin:** `github/codeql-action/upload-sarif@b7351df727350dca84cb9d725d57dcf5bc82ba26 # v3.37.1`
— v3.37.1 is an ANNOTATED tag; resolve commit SHA by deref (git/refs/tags→git/tags),
NOT the codeql-bundle-vX.Y.Z tag (that has no `# vX.Y.Z` comment form for lint-action-pins.sh).

**Verified in real CI:** the `agnix → code scanning` workflow passed in 13s on PR #460
(acceptance met). agnix is only an npm pin, outside dependabot's github-actions
ecosystem — noted acceptable per ADR §5, not expanded here.
