---
description: Resolve lock file merge conflicts by regenerating from the manifest. Use when merge conflicts occur in package-lock.json, Cargo.lock, go.sum, or similar lock files.
---

# Rebase Lock File

Resolves lock file merge conflicts by accepting one side and regenerating.
Line-by-line merging of lock files is unreliable — always regenerate.

## Supported Lock Files

Use the **lockfile-only / no-install** form of each command. These resolve the
lock file against the already-merged manifest **without running install
lifecycle scripts** (which would execute arbitrary code from the incoming
branch during an autonomous rebase) and **without drifting unrelated transitive
dependencies** beyond the conflict.

| Lock File           | Manifest         | Regenerate Command (lockfile-only)   |
| ------------------- | ---------------- | ------------------------------------ |
| `package-lock.json` | `package.json`   | `npm install --package-lock-only --ignore-scripts` |
| `yarn.lock`         | `package.json`   | `yarn install --mode update-lockfile` |
| `pnpm-lock.yaml`    | `package.json`   | `pnpm install --lockfile-only --ignore-scripts` |
| `Cargo.lock`        | `Cargo.toml`     | `cargo generate-lockfile`            |
| `Gemfile.lock`      | `Gemfile`        | `bundle lock`                        |
| `poetry.lock`       | `pyproject.toml` | `poetry lock --no-update`            |
| `go.sum`            | `go.mod`         | `go mod tidy`                        |
| `composer.lock`     | `composer.json`  | `composer update --lock --no-scripts --no-plugins` |

> **Supply-chain note**: the plain install forms (`npm install`,
> `pnpm install`, `composer update`) run pre/post-install scripts and may bump
> dependencies unrelated to the conflict. Because this runs unattended while
> integrating another branch's manifest, always prefer the lockfile-only forms
> above. If only a full-install form is available for a tool, **escalate**
> rather than running it autonomously.

## Resolution Steps

1. **Accept ours** (the branch being merged into):

   ```bash
   git checkout --ours <lockfile>
   git add <lockfile>
   ```

1. **Regenerate** using the appropriate command from the table above

1. **Stage the regenerated file**:

   ```bash
   git add <lockfile>
   ```

1. **Verify** the regenerated lock file is valid by checking the package
   manager doesn't report errors

## When to Use

- Any merge conflict in a lock file listed above
- After resolving manifest conflicts (e.g., both sides added dependencies
  to `package.json`)

## When NOT to Use

- Conflicts in the manifest itself (`package.json`, `Cargo.toml`) —
  those require understanding which dependencies to keep
