# dev-core

Part of the [librarian](../../README.md) Claude Code plugin marketplace.

General-purpose development and authoring skills + agents: write, review,
debug, refactor, and test code, and author the Claude Code artifacts (skills,
agents, `workflow.js` harnesses) themselves — on a host, on bare Linux, or
inside a devcontainer.

## Skills (20)

### Code & workflow guidance

- `code-quality` — code quality standards, naming, and the review checklist
- `development-workflow` — phased feature development + task decomposition
- `error-handling` — error patterns, retry strategies, graceful degradation
- `git-workflow` — commit conventions, branch naming, PR workflow
- `shell-scripting` — shell conventions, naming patterns, testing
- `testing-patterns` — test-first patterns and framework conventions
- `documentation-authoring` — docs/docstring/README standards
- `memory-conventions` — two-tier `.claude/memory/` conventions

### Authoring guides (for building Claude Code artifacts)

- `skill-authoring` / `agent-authoring` / `workflow-authoring` — guidelines for
  writing skills, agents, and `workflow.js` harnesses
- `adversarial-review` — adversarial review method for skills/agents/harnesses

### Activate-by-context (auto-activated when the work matches)

- `context-data-storage` — databases, SQL, ORM, migrations, query tuning
- `context-security` — authn/authz, secrets, input validation, OWASP

### Implementation-loop passes (driven by the pipeline; not invoked directly)

- `loop-make-it-work` / `loop-make-it-right` / `loop-make-it-tested` /
  `loop-make-it-documented` / `loop-make-it-secure`
- `drift-detect` — catch scope drift between an issue plan and the actual diff

## Agents (6)

| Agent | Role |
| --- | --- |
| `code-reviewer` | Bugs, security, performance, style — run after writing/modifying code |
| `debugger` | Systematic investigation of errors, test failures, unexpected behavior |
| `refactorer` | Structural improvement without changing behavior |
| `test-writer` | Comprehensive tests for existing code |
| `skill-author` | Write/review/upgrade skills |
| `agent-author` | Write/review/upgrade agents |

`code-reviewer` ships a deterministic `workflow.js` harness alongside its flat
`agents/code-reviewer.md` (see the repo's
[CLAUDE.md](../../CLAUDE.md) for the flat-agent + harness-sibling layout).
