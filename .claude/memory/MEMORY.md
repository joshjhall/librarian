# Memory index

<!-- One line per memory (title + one-line hook), intentionally long. -->
<!-- rumdl-disable MD013 -->

- [Verify squash-merge landed](verify-squash-merge-landed.md) — after merging a PR, confirm the diff actually landed on origin/main, not just the title
- [Release process](release-process.md) — how to cut a repo-level vX.Y.Z release; what containers#608's LIBRARIAN_REF pins to
- [Flaky golem-gate-watch test](flaky-golem-gate-watch-test.md) — root-caused to GIT_DIR leak from push hook; fixed in PR #62
- [Conform scope enum](conform-scope-enum.md) — fix(review): is rejected; use fix(workflow): etc. — the skill's generic scope ≠ this repo's enum
- [Skill required_tools vocabulary](skill-required-tools-vocabulary.md) — metadata.yml required_tools are shell-command names; no SKILL.md has a frontmatter tools: field
- [Devcontainer bash_env PATH reset](devcontainer-bash-env-path-reset.md) — /etc/bash_env resets $PATH on non-interactive bash; unset BASH_ENV for PATH-stub tests
- [Autonomy vs plan-gate flags](autonomy-vs-plangate-flags.md) — --autonomous (autonomy) vs --skip-plan/--force-auto (plan-gate) are orthogonal; 3 unrelated --auto spellings never to rename
- [Release from worktree (git-cliff)](release-from-worktree-gitcliff.md) — git-cliff scopes to cwd; release.sh needs --include-path or it silently wipes CHANGELOG from a worktree
- [Two-runtime model](two-runtime-model.md) — workflow.js engine is sandboxed (no shell/fs); only Bash-tool subagents reach host tools; Claude Code bundles no general-purpose runtime
- [core.bare misconfig](core-bare-misconfig.md) — "must be run in a work tree" error = stray core.bare=true in .git/config; set it false (also masks real git status)
