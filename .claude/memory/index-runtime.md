# Index: runtime, tooling & test-harness gotchas

<!-- Sub-index of MEMORY.md. Not a memory — no frontmatter, one line per entry. -->
<!-- rumdl-disable MD013 MD033 -->

The cross-cutting test-validity failure modes (tautological fixtures, unregistered
tests, comment-vs-code drift) live in the root [MEMORY.md](MEMORY.md) — they apply
to every task, not just this topic.

## workflow.js runtime

- [workflow.js no clock](workflow-js-no-clock.md) — no Date.now/timers; bound at the CALLER (background→poll→TaskStop) (#224)
- [workflow.js no module system](workflow-js-no-module-system.md) — no import/require/fs; use entry-point fns + header banner (#90)
- [Workflow agentType namespacing](workflow-agenttype-namespacing.md) — Workflow wants `<plugin>:<name>`, Agent wants bare — opposite (#126)
- [Test workflow.js pure helpers](test-workflow-js-pure-helpers.md) — slice before the first orchestration stmt + eval in new Function

## Shell & scripting traps

- [set -e aborts untestable in run_test](set-e-abort-untestable-in-run-test.md) — `if "$fn"` suspends set -e; SLICE the fn + run at top level (#498)
- [Octal month kills date arithmetic](octal-month-date-arithmetic.md) — `date +%m` in `$(( ))` = octal; aborts in Aug/Sep ONLY (#624)
- [grep -c exits 1 on zero count](grep-c-zero-count-exit-1.md) — prints 0 but EXITS 1; `|| echo 0` double-appends; use `grep -o | wc -l`
- [die inside $(...) is swallowed](die-inside-command-substitution-is-swallowed.md) — kills only the SUBSHELL; capture once + `|| die` (#596)
- [jq empty vs jq -e](jq-validate-empty-vs-e.md) — validity = `jq empty`; `jq -e .` calls valid false/null invalid (#253)
- [core.bare misconfig](core-bare-misconfig.md) — "must be run in a work tree" = stray core.bare=true; set false
- [Devcontainer bash_env PATH reset](devcontainer-bash-env-path-reset.md) — /etc/bash_env resets $PATH; unset BASH_ENV for PATH-stub tests
- [Scrub GIT_* in temp-repo tests](flaky-golem-gate-watch-test.md) — push exports GIT_DIR into hooks → tests hit the OUTER repo; reads as flake
- [send-keys rc proves nothing](send-keys-rc-proves-nothing.md) — tmux exits 0 on an unknown key name and types it literally; assert the ARGUMENT (#659)
- [local can't self-reference](local-declaration-cannot-self-reference.md) — `local a=$1 b=$a` aborts under set -u; shellcheck SC2318 catches it — lint before you debug
- [Apostrophe ends a quoted awk program](quoted-awk-program-apostrophe.md) — even in a COMMENT; plus awk has no block scope, so helper loop vars must be params (#663)

## Lint & format gates

- [typos gate blocks push](typos-gate-blocks-push.md) — fails the whole push on any misspelling in touched files, incl adjacent ones
- [rumdl nested sublist](rumdl-nested-sublist-under-numbered.md) — MD077 autofix dedents sublists out of numbered parents (#225)
- [rumdl: never start a line with #NNN](rumdl-issue-ref-line-start.md) — a leading issue ref = MD018 malformed heading; reword
- [rumdl scope depends on invocation](rumdl-scope-depends-on-invocation.md) — over-reports on an explicit .sh, under-reports on a walk
- [Splitting a file surfaces masked lint](splitting-a-file-surfaces-masked-lint.md) — per-file linters find real bugs the monolith hid; triage first

## Skills, agents & packaging

- [Skill required_tools vocabulary](skill-required-tools-vocabulary.md) — they are shell-command names; no SKILL.md has a frontmatter tools: field
- [Model tier: fable is valid](model-tier-fable-valid.md) — agent `model:` accepts fable; aliases track the latest generation
- [Namespace pkg fakes an import probe](namespace-package-fakes-import-probe.md) — `import X` passes on an empty ./X/ (PEP 420); probe an attribute
- [Third-party fix needs a durable lever](third-party-fix-needs-a-durable-lever.md) — a patch to installed plugin files is clobbered by `plugin update`; enumerate config levers first
