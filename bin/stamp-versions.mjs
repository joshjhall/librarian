#!/usr/bin/env node
// Stamp a release version across every librarian manifest in lockstep.
//
// Librarian's analog of containers stamping the Dockerfile: a release bumps the
// repo-level VERSION file, and this script propagates that same version into
//   - .claude-plugin/marketplace.json   (each plugins[].version)
//   - plugins/<name>/.claude-plugin/plugin.json   (top-level version)
// so the marketplace entry and each plugin manifest keep agreeing — exactly
// what tests/validate-manifests.mjs enforces.
//
// Usage:   node bin/stamp-versions.mjs <X.Y.Z>
//
// Zero external dependencies (portable to host + container, same as the
// validator). Edits are surgical regex replacements on the `version` field so
// the rest of each file's formatting is untouched; the changed files still pass
// `dprint check` because only the value inside the quotes changes.

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const version = process.argv[2];
const SEMVER = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/;
if (!version || !SEMVER.test(version)) {
  console.error(`stamp-versions: expected a semver argument, got "${version ?? ""}"`);
  process.exit(1);
}

/** Replace the first top-level `"version": "..."` value in a JSON string. */
function stampTopLevelVersion(raw, label) {
  const re = /("version"\s*:\s*")[^"]*(")/;
  if (!re.test(raw)) {
    throw new Error(`${label}: no \`version\` field found`);
  }
  return raw.replace(re, `$1${version}$2`);
}

const changed = [];

// 1. plugin.json for each plugin listed in the marketplace.
const marketplacePath = join(repoRoot, ".claude-plugin", "marketplace.json");
const marketplaceRaw = readFileSync(marketplacePath, "utf8");
const marketplace = JSON.parse(marketplaceRaw);

if (!Array.isArray(marketplace.plugins) || marketplace.plugins.length === 0) {
  console.error("stamp-versions: marketplace.json has no plugins[]");
  process.exit(1);
}

for (const entry of marketplace.plugins) {
  if (typeof entry.source !== "string") continue;
  const pjPath = join(resolve(repoRoot, entry.source), ".claude-plugin", "plugin.json");
  const raw = readFileSync(pjPath, "utf8");
  const next = stampTopLevelVersion(raw, `plugin.json for "${entry.name}"`);
  if (next !== raw) {
    writeFileSync(pjPath, next);
    changed.push(`${entry.name}/plugin.json`);
  }
}

// 2. Each plugins[].version inside marketplace.json. Scope the replacement to
//    objects that carry a "source" so we never touch the top-level marketplace
//    metadata (which has no version field today, but stay defensive).
const nextMarketplace = marketplaceRaw.replace(
  /("source"\s*:\s*"[^"]*"\s*,\s*[\s\S]*?)("version"\s*:\s*")[^"]*(")/g,
  (_m, pre, vOpen, vClose) => `${pre}${vOpen}${version}${vClose}`,
);
if (nextMarketplace !== marketplaceRaw) {
  writeFileSync(marketplacePath, nextMarketplace);
  changed.push("marketplace.json");
}

if (changed.length === 0) {
  console.log(`stamp-versions: all manifests already at ${version}`);
} else {
  console.log(`stamp-versions: set version ${version} in ${changed.join(", ")}`);
}
