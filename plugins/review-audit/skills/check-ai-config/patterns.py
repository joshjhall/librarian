#!/usr/bin/env python3
"""check-ai-config — Deterministic Pre-Scan (Python primary implementation).

Validates Claude Code configuration files: agent/skill frontmatter, file bloat
thresholds, config consistency, MCP settings, and hook safety.

Python 3.11+ primary implementation behind the language-agnostic TSV contract;
the sibling patterns.sh is the portable bash fallback (it exec's this file when a
python3>=3.11 is present). Both emit byte-identical findings — the parity is
pinned by tests/validate-python-ports.sh. See CLAUDE.md § Key conventions.

Input:  argv[1] = file containing paths to scan (one per line)
Output: TSV to stdout: file<TAB>line<TAB>category<TAB>evidence<TAB>certainty

Exit codes:
  0 = success (zero or more findings)
  1 = usage error (missing argument) or file list not found

Thresholds are env-overridable (CLAUDE_MD_WARN/HIGH, SKILL_*, AGENT_*, DOC_*),
matching the bash impl.
"""

from __future__ import annotations

import fnmatch as _fnmatch
import os
import re
import sys

EVIDENCE_CAP = 80  # printf '%.80s' for the grep-derived evidence rows


def _int_env(name: str, default: int) -> int:
    val = os.environ.get(name, "")
    try:
        return int(val)
    except ValueError:
        return default


def emit(path: str, line_no: str, category: str, message: str, certainty: str) -> None:
    sys.stdout.write("\t".join((path, line_no, category, message, certainty)) + "\n")


def _glob(path: str, pattern: str) -> bool:
    """`case "$path" in <pattern>)` — an unanchored shell glob over the full path.
    Shell globs are whole-string matches, so `*/agents/*/*.md` etc. work as in
    bash; fnmatch treats `*` as not crossing... it DOES cross '/', matching shell
    `case` semantics here (bash `case` globs are not path-aware)."""
    return _fnmatch.fnmatchcase(path, pattern)


def get_frontmatter(lines: list[str], key: str) -> str:
    """Extract a YAML frontmatter value, mirroring get_frontmatter() in
    patterns.sh: within the first `---`..`---` block, the first `^<key>:` line,
    value trimmed and stripped of one layer of surrounding single/double quotes."""
    # sed -n '/^---$/,/^---$/p' — the inclusive span from the first '---' line to
    # the next '---' line (bash sed prints the block including both fences; if no
    # closing fence, to EOF).
    in_block = False
    block: list[str] = []
    seen_open = False
    for ln in lines:
        if ln == "---":
            if not seen_open:
                seen_open = True
                in_block = True
                block.append(ln)
                continue
            else:
                block.append(ln)
                in_block = False
                break
        if in_block:
            block.append(ln)
    # grep -E "^<key>:" | first; then strip "<key>:" prefix + surrounding quotes.
    key_re = re.compile("^" + re.escape(key) + ":")
    for ln in block:
        if key_re.search(ln):
            # sed "s/^<key>:[[:space:]]*//"
            val = re.sub("^" + re.escape(key) + r":[ \t]*", "", ln, count=1)
            # sed 's/^["\x27]//' then 's/["\x27]\s*$//'  (leading/trailing quote).
            # Here the bash uses a REAL quote class ["'] (written ["'\'']), so a
            # single or double leading/trailing quote is stripped.
            val = re.sub(r"""^["']""", "", val, count=1)
            val = re.sub(r"""["']\s*$""", "", val, count=1)
            return val
    return ""


def check_agent_frontmatter(path: str, lines: list[str]) -> None:
    if not _glob(path, "*/agents/*/*.md"):
        return
    basename = path.rsplit("/", 1)[-1]
    dirname = path.rsplit("/", 1)[0] if "/" in path else ""
    dirbase = dirname.rsplit("/", 1)[-1] if dirname else ""

    expected = dirbase + ".md"
    if basename != expected:
        emit(
            path,
            "1",
            "agent-frontmatter",
            f"Agent file should be named {expected}, found {basename}",
            "HIGH",
        )

    if not lines or lines[0] != "---":
        emit(
            path,
            "1",
            "agent-frontmatter",
            "Missing YAML frontmatter (no opening ---)",
            "HIGH",
        )
        return

    name = get_frontmatter(lines, "name")
    desc = get_frontmatter(lines, "description")
    tools = get_frontmatter(lines, "tools")
    model = get_frontmatter(lines, "model")

    if not name:
        emit(
            path,
            "1",
            "agent-frontmatter",
            "Missing required frontmatter field: name",
            "HIGH",
        )
    if not desc:
        emit(
            path,
            "1",
            "agent-frontmatter",
            "Missing required frontmatter field: description",
            "HIGH",
        )
    if not tools:
        emit(
            path,
            "1",
            "agent-frontmatter",
            "Missing required frontmatter field: tools",
            "HIGH",
        )
    if not model:
        emit(
            path,
            "1",
            "agent-frontmatter",
            "Missing required frontmatter field: model",
            "HIGH",
        )
    elif model not in ("fable", "opus", "sonnet", "haiku", "inherit"):
        emit(
            path,
            "1",
            "agent-frontmatter",
            f"Invalid model value: {model} "
            "(expected fable, opus, sonnet, haiku, or inherit)",
            "HIGH",
        )

    if tools == "*":
        emit(
            path,
            "1",
            "agent-frontmatter",
            "Agent uses wildcard tools (*) — scope to specific tools",
            "MEDIUM",
        )


def check_skill_frontmatter(path: str, lines: list[str]) -> None:
    if not _glob(path, "*/skills/*/SKILL.md"):
        return
    dirname = path.rsplit("/", 1)[0] if "/" in path else ""

    if not lines or lines[0] != "---":
        emit(
            path,
            "1",
            "skill-frontmatter",
            "Missing YAML frontmatter (no opening ---)",
            "HIGH",
        )
        return

    desc = get_frontmatter(lines, "description")
    if not desc:
        emit(
            path,
            "1",
            "skill-frontmatter",
            "Missing required frontmatter field: description",
            "HIGH",
        )

    if not any(
        re.search(
            r"^## (Workflow|Step|Phase|Categories|Conventions|Rules|Patterns|When to)",
            ln,
        )
        for ln in lines
    ):
        emit(
            path,
            "1",
            "skill-frontmatter",
            "No structural section found "
            "(expected ## Workflow, ## Categories, or similar)",
            "MEDIUM",
        )

    if not os.path.isfile(os.path.join(dirname, "metadata.yml")):
        emit(
            path,
            "1",
            "skill-frontmatter",
            "Missing metadata.yml in skill directory",
            "MEDIUM",
        )


def check_ai_file_bloat(path: str, lines: list[str]) -> None:
    n = len(lines)
    # `category` splits documentation bloat (docs/*.md) into its own
    # `doc-file-bloat` slug — the canonical name in finding-schema.md — while the
    # AI-instruction files (CLAUDE.md / SKILL.md / agent md) stay `ai-file-bloat`.
    category = "ai-file-bloat"
    if _glob(path, "*/CLAUDE.md") or _glob(path, "*/AGENTS.md"):
        warn, high, ftype = (
            _int_env("CLAUDE_MD_WARN", 400),
            _int_env("CLAUDE_MD_HIGH", 600),
            "CLAUDE.md",
        )
    elif _glob(path, "*/skills/*/SKILL.md"):
        warn, high, ftype = (
            _int_env("SKILL_WARN", 300),
            _int_env("SKILL_HIGH", 500),
            "skill definition",
        )
    elif _glob(path, "*/agents/*/*.md"):
        warn, high, ftype = (
            _int_env("AGENT_WARN", 250),
            _int_env("AGENT_HIGH", 400),
            "agent definition",
        )
    elif _glob(path, "*/docs/*.md"):
        warn, high, ftype, category = (
            _int_env("DOC_WARN", 500),
            _int_env("DOC_HIGH", 800),
            "documentation",
            "doc-file-bloat",
        )
    else:
        return

    if n > high:
        emit(
            path,
            "1",
            category,
            f"{ftype} exceeds high threshold: {n} lines (>{high})",
            "HIGH",
        )
    elif n > warn:
        emit(
            path,
            "1",
            category,
            f"{ftype} exceeds warning threshold: {n} lines (>{warn})",
            "MEDIUM",
        )


# Backtick-quoted relative path with a source-file extension and at least one
# `/`. The char class [A-Za-z0-9_.-] excludes `$ { } * :`, so `${VAR}` templates,
# globs, and `scheme://` URLs cannot match — the skip is built into the pattern.
DRIFT_PATH_RE = re.compile(
    r"`([A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+\.(?:sh|py|js|mjs|ts|json|ya?ml|md|toml))`"
)
# Backtick-quoted `<plugin>:<name>` cross-reference (lowercase kebab both sides).
CROSSREF_RE = re.compile(r"`([a-z0-9][a-z0-9-]*):([a-z0-9][a-z0-9-]*)`")


def check_claude_md_drift(path: str, lines: list[str]) -> None:
    """CLAUDE.md / AGENTS.md referencing a relative file path that does not exist
    (resolved against the document's own directory, like check-docs-deadlinks).
    MEDIUM — the LLM pass separates literal drift from illustrative paths and
    verifies referenced *commands* (which this deterministic pass does not check).
    """
    if not (_glob(path, "*/CLAUDE.md") or _glob(path, "*/AGENTS.md")):
        return
    file_dir = path.rsplit("/", 1)[0] if "/" in path else "."
    for idx, content in enumerate(lines, start=1):
        for m in DRIFT_PATH_RE.finditer(content):
            target = m.group(1)
            if not os.path.exists(file_dir + "/" + target):
                emit(
                    path,
                    str(idx),
                    "claude-md-drift",
                    "Referenced path not found: " + target[:EVIDENCE_CAP],
                    "MEDIUM",
                )


def _plugins_dir_for(path: str) -> str | None:
    """The `<root>/plugins` directory for a file living under it, or None."""
    if "/plugins/" in path:
        return path.split("/plugins/")[0] + "/plugins"
    if path.startswith("plugins/"):
        return "plugins"
    return None


def check_config_inconsistency(path: str, lines: list[str]) -> None:
    """Skill/agent markdown citing a `<plugin>:<name>` agent or skill that does
    not exist. Only fires when `<plugins>/<plugin>/` is a real plugin dir but
    neither `agents/<name>.md` nor `skills/<name>/SKILL.md` resolves under it —
    so non-plugin `foo:bar` tokens (e.g. `go:generate`) are ignored. MEDIUM.
    """
    if not (_glob(path, "*/skills/*.md") or _glob(path, "*/agents/*.md")):
        return
    plugins_dir = _plugins_dir_for(path)
    if plugins_dir is None:
        return
    for idx, content in enumerate(lines, start=1):
        for m in CROSSREF_RE.finditer(content):
            plugin, name = m.group(1), m.group(2)
            if not os.path.isdir(plugins_dir + "/" + plugin):
                continue  # not a plugin reference — leave it alone
            agent_md = plugins_dir + "/" + plugin + "/agents/" + name + ".md"
            skill_md = plugins_dir + "/" + plugin + "/skills/" + name + "/SKILL.md"
            if not os.path.isfile(agent_md) and not os.path.isfile(skill_md):
                emit(
                    path,
                    str(idx),
                    "config-inconsistency",
                    "Referenced agent/skill not found: "
                    + (plugin + ":" + name)[:EVIDENCE_CAP],
                    "MEDIUM",
                )


def check_mcp_config(path: str, lines: list[str]) -> None:
    if not _glob(path, "*.json"):
        return
    for idx, line in enumerate(lines, start=1):
        if not re.search(r'"http://', line):
            continue
        if re.search(r"(localhost|127\.0\.0\.1|host\.docker\.internal)", line):
            continue
        emit(
            path,
            str(idx),
            "mcp-misconfiguration",
            "Insecure HTTP URL in config (use HTTPS): " + line[:EVIDENCE_CAP],
            "HIGH",
        )


def check_hook_safety(path: str, lines: list[str]) -> None:
    if not (_glob(path, "*.json") or _glob(path, "*.sh")):
        return
    destructive = re.compile(
        r"(rm\s+-rf\s|git\s+reset\s+--hard|git\s+clean\s+-fd|docker\s+system\s+prune)"
    )
    secret_leak = re.compile(
        r"(echo|printf).*\$(ANTHROPIC_|GITHUB_TOKEN|GITLAB_TOKEN|API_KEY|SECRET|PASSWORD|OP_.*_REF)"
    )
    for idx, line in enumerate(lines, start=1):
        if destructive.search(line):
            emit(
                path,
                str(idx),
                "hook-safety",
                "Destructive command in hook without confirmation: "
                + line[:EVIDENCE_CAP],
                "HIGH",
            )
        if secret_leak.search(line):
            emit(
                path,
                str(idx),
                "hook-safety",
                "Potential secret leak in hook output: " + line[:EVIDENCE_CAP],
                "HIGH",
            )


def check_harness_logic(path: str, lines: list[str]) -> None:
    if not _glob(path, "*workflow.js"):
        return
    # Non-unique finding ref: `${a}:${b}:${c}` template, no per-finding `#${...}`.
    ref_collide = re.compile(r"`\$\{[^}]+\}:\$\{[^}]+\}:\$\{[^}]+\}`")
    # Bare agentType — a quoted value with no `:` namespace.
    bare_agent = re.compile(r"""agentType:[ \t]*['"][^'":]+['"]""")
    unsafe_interp = re.compile(r"dangerously-skip-permissions.*\$\{")
    install = re.compile(r"(npm install|pnpm install|composer update|yarn install)")
    install_safe = re.compile(
        r"(package-lock-only|ignore-scripts|no-scripts|lockfile-only|update-lockfile)"
    )
    for idx, line in enumerate(lines, start=1):
        if ref_collide.search(line) and not re.search(r"#\$\{", line):
            emit(
                path,
                str(idx),
                "harness-logic",
                "Finding ref may collide (no per-finding index): "
                + line[:EVIDENCE_CAP],
                "MEDIUM",
            )
        if bare_agent.search(line):
            emit(
                path,
                str(idx),
                "harness-logic",
                "Bare agentType (needs <plugin>:<name> for the Workflow tool): "
                + line[:EVIDENCE_CAP],
                "MEDIUM",
            )
        if unsafe_interp.search(line):
            emit(
                path,
                str(idx),
                "harness-logic",
                "Interpolation into --dangerously-skip-permissions (validate first): "
                + line[:EVIDENCE_CAP],
                "HIGH",
            )
        if install.search(line) and not install_safe.search(line):
            emit(
                path,
                str(idx),
                "harness-logic",
                "Install/regen may run lifecycle scripts (use lockfile-only): "
                + line[:EVIDENCE_CAP],
                "MEDIUM",
            )


def scan_file(path: str, lines: list[str]) -> None:
    check_agent_frontmatter(path, lines)
    check_skill_frontmatter(path, lines)
    check_ai_file_bloat(path, lines)
    check_claude_md_drift(path, lines)
    check_config_inconsistency(path, lines)
    check_mcp_config(path, lines)
    check_hook_safety(path, lines)
    check_harness_logic(path, lines)


def main(argv: list[str]) -> int:
    if len(argv) < 2 or not argv[1]:
        sys.stderr.write("Usage: patterns.py <file-list>\n")
        return 1

    file_list = argv[1]
    try:
        with open(file_list, "r", encoding="utf-8", errors="replace") as fh:
            paths = [ln.rstrip("\n") for ln in fh]
    except OSError:
        sys.stderr.write("Error: file list not found: " + file_list + "\n")
        return 1

    for path in paths:
        if not path:
            continue
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        scan_file(path, lines)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
