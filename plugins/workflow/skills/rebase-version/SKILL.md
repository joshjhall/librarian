---
description: Resolve version number merge conflicts by taking the higher version. Use when both sides of a merge bumped version numbers independently.
---

# Rebase Version

Resolves version number conflicts by taking the higher version. When two
branches independently bump version numbers, the correct resolution is
almost always to keep the higher one.

## Supported Version Files

| File             | Field / Format                    |
| ---------------- | --------------------------------- |
| `VERSION`        | Plain text semver (e.g., `1.2.3`) |
| `package.json`   | `"version": "1.2.3"`              |
| `Cargo.toml`     | `version = "1.2.3"`               |
| `pyproject.toml` | `version = "1.2.3"`               |
| `build.gradle`   | `version = '1.2.3'`               |
| `setup.py`       | `version='1.2.3'`                 |
| `*.gemspec`      | `s.version = '1.2.3'`             |

## Resolution Steps

1. **Extract versions** from both sides of the conflict:

   ```text
   <<<<<<< HEAD
   version = "2.1.0"
   =======
   version = "2.0.5"
   >>>>>>> agent01
   ```

1. **Parse semver** components: major.minor.patch (+ optional pre-release)

1. **Compare and take the higher version**:

   - Compare major first, then minor, then patch
   - `2.1.0` > `2.0.5` → keep `2.1.0`
   - Pre-release versions are lower than release (`2.0.0-rc.1` < `2.0.0`)

1. **Replace** the conflict block with the winning version

1. **Stage** the resolved file: `git add <file>`

## Edge Cases

- **Both bumped the same component**: Take the higher number
  (`1.3.0` vs `1.2.0` → `1.3.0`)
- **Different components bumped**: Take the overall higher version
  (`2.0.0` vs `1.5.0` → `2.0.0`)
- **Non-semver versions**: **Escalate** — do not guess. String comparison of
  versions is unreliable (`"1.10" sorts before "1.9"`; calver, epoch, and
  date-stamped schemes break entirely), and an auto-rebase that silently picks
  the wrong version ships a regression. Only resolve versions that are clean,
  comparable semver on both sides; anything else goes to the human.

## When NOT to Use

- Version conflicts in dependency manifests (e.g., dependency version ranges
  in `package.json`) — those require understanding which dependency version
  to pin
- Changelog conflicts — those need content merging, not version comparison
