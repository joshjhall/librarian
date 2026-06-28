# Tests

| Check | Command |
|---|---|
| Manifest validation | `node tests/validate-manifests.mjs` |

`validate-manifests.mjs` parses `.claude-plugin/marketplace.json` and every
`plugins/*/.claude-plugin/plugin.json`, and asserts they agree on name +
semver version and that each `source` points at a real plugin directory. It
has no external dependencies so it runs identically on host and in CI.

Run on every PR by `.github/workflows/ci.yml`. The skill/agent quality gates
(structure lint, frontmatter, fixtures) are relocated from `containers` in a
follow-up — see [joshjhall/librarian#5](https://github.com/joshjhall/librarian/issues/5).
