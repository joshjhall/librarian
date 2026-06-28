#!/usr/bin/env node
// Validate the librarian marketplace + plugin manifests.
//
// Checks, with zero external dependencies (portable to host + container):
//   1. .claude-plugin/marketplace.json parses and has name + plugins[].
//   2. Each marketplace plugin entry has name / source / version (semver).
//   3. Each entry's `source` points at a real ./plugins/<name> directory
//      containing .claude-plugin/plugin.json.
//   4. Each plugin.json parses and its name + version agree with the
//      marketplace entry (the `claude plugin tag` release flow requires
//      plugin.json and the enclosing marketplace entry to agree).
//
// Exit non-zero on the first batch of failures, printing every problem.

import { readFileSync, existsSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const errors = [];
const SEMVER = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/;

function readJson(absPath, label) {
  let raw;
  try {
    raw = readFileSync(absPath, "utf8");
  } catch {
    errors.push(`${label}: file not found (${absPath})`);
    return null;
  }
  try {
    return JSON.parse(raw);
  } catch (e) {
    errors.push(`${label}: invalid JSON — ${e.message}`);
    return null;
  }
}

const marketplacePath = join(repoRoot, ".claude-plugin", "marketplace.json");
const marketplace = readJson(marketplacePath, "marketplace.json");

if (marketplace) {
  if (!marketplace.name) errors.push("marketplace.json: missing `name`");
  if (!Array.isArray(marketplace.plugins) || marketplace.plugins.length === 0) {
    errors.push("marketplace.json: `plugins` must be a non-empty array");
  } else {
    const seen = new Set();
    for (const entry of marketplace.plugins) {
      const label = `marketplace plugin "${entry.name ?? "<unnamed>"}"`;
      if (!entry.name) {
        errors.push(`${label}: missing \`name\``);
        continue;
      }
      if (seen.has(entry.name)) errors.push(`${label}: duplicate name`);
      seen.add(entry.name);

      if (!entry.version || !SEMVER.test(entry.version)) {
        errors.push(`${label}: \`version\` must be semver (got ${entry.version ?? "none"})`);
      }
      if (typeof entry.source !== "string") {
        errors.push(`${label}: local plugins must use a string \`source\` (e.g. ./plugins/${entry.name})`);
        continue;
      }

      const pluginDir = resolve(repoRoot, entry.source);
      if (!existsSync(pluginDir) || !statSync(pluginDir).isDirectory()) {
        errors.push(`${label}: source dir does not exist (${entry.source})`);
        continue;
      }

      const pjPath = join(pluginDir, ".claude-plugin", "plugin.json");
      const pj = readJson(pjPath, `${label} plugin.json`);
      if (!pj) continue;
      if (pj.name !== entry.name) {
        errors.push(`${label}: plugin.json name "${pj.name}" != marketplace name "${entry.name}"`);
      }
      if (pj.version !== entry.version) {
        errors.push(`${label}: plugin.json version "${pj.version}" != marketplace version "${entry.version}"`);
      }
      if (pj.version && !SEMVER.test(pj.version)) {
        errors.push(`${label}: plugin.json version "${pj.version}" is not semver`);
      }
    }
  }
}

if (errors.length > 0) {
  console.error(`✗ ${errors.length} manifest problem(s):`);
  for (const e of errors) console.error(`  - ${e}`);
  process.exit(1);
}

const count = marketplace?.plugins?.length ?? 0;
console.log(`✓ marketplace.json + ${count} plugin manifest(s) valid`);
