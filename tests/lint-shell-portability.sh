#!/usr/bin/env bash
# Bash portability guardrail (issues #17, #443).
#
# The skill code tools and helper scripts must run on base macOS, whose stock
# /bin/bash is 3.2 (2007) and whose core utilities live in /bin, not /usr/bin. A
# script silently relying on a bash-4-only feature — or on a hardcoded tool path
# that is wrong on this host — malfunctions there rather than failing loudly. This
# gate greps librarian-proper `*.sh` for both traps and fails with `file:line` so
# a regression is caught before it ships.
#
# Check 1 — forbidden bash-4+ constructs (#17), all unavailable in 3.2:
#   - `declare -A` / `local -A`      associative arrays
#   - `mapfile` / `readarray`        read-into-array builtins
#   - `declare -n` / `local -n`      namerefs
#   - `${v,,}` `${v^^}` `${v,}` `${v^}`  case-conversion expansions
#   - `;;&`                          case fallthrough
#
# Portable replacements: space-delimited string sets + `case` membership, and
# flat "<key>\ttab<value>" maps (see plugins/workflow/scripts/golem-gate-watch.sh
# for a worked example), `while IFS= read` loops instead of mapfile, and
# `tr '[:upper:]' '[:lower:]'` for case folding.
#
# Check 2 — hardcoded core-utility paths (#443): a `/usr/bin/<tool>` or `/bin/<tool>`
# invocation is banned (it exits 127 where the tool lives elsewhere — macOS /bin,
# Homebrew git). Use the `command <tool>` builtin, which honors PATH while still
# bypassing shell functions/aliases. Allowed: the `#!/usr/bin/env bash` shebang
# and `/usr/bin/env` itself (env is the one tool with a stable path).
#
# Check 3 — GNU-only regex constructs (#679). BSD `grep`/`sed` (the macOS
# default) do not implement the GNU regex extensions, and the failure mode is
# what makes this worth a gate: they do NOT error, they silently MISMATCH.
#   - `\s` / `\S`   whitespace class  -> BSD reads a literal `s` / `S`
#   - `\w` / `\W`   word class        -> BSD reads a literal `w` / `W`
#   - `\|` in a BRE alternation       -> BSD reads a literal `|`
# A scanner pattern that silently stops matching emits zero findings and still
# exits 0, so the scan looks clean on macOS while seeing nothing — which is
# exactly how #679 went unnoticed (an indented `print(` was invisible, and a
# project's .claude/pre-review.yml parsed to empty).
# Portable replacements: `[[:space:]]`, `[[:alnum:]_]`, and `grep -E`/`sed -E`
# where alternation is native. See dev-core's shell-scripting skill.
#
# Check 4 — parse errors (#906). A script that does not PARSE under the running
# bash never executes a single line, so its harness never reaches
# `generate_report` and the shell exits 0. A suite that died at parse time is
# therefore indistinguishable from a suite that passed — the #538/#571 shape
# (a gate sitting inert while reading green), but reached through a grammar
# error rather than a missing tool, and with no 77 sentinel to protect it
# because the script never gets far enough to emit one.
#
# That is not hypothetical: five heredoc-in-command-substitution sites in
# tests/validate-python-ports.sh meant the repo's ONLY BSD/bash-3.2 coverage
# (ci.yml's `bsd-probe` job) had never once run, and reported pass every time.
#
# KEYED ON STDERR, NOT ON EXIT CODE. This is load-bearing and must not be
# "simplified" to `if ! bash -n "$file"`. Measured on bash 5.2: the construct
# above makes `bash -n` print
#   `warning: command substitution: 1 unterminated here-document`
# to stderr and still **exit 0**. An exit-code-keyed check is a tautology — it
# passes on the very file that motivated this gate. Non-empty stderr covers both
# outcomes: hard `syntax error` (non-zero) and warning-only (zero).
#
# KNOWN LIMITATION, recorded rather than overstated (same posture as the `\b`
# gap below). This runs under whatever bash the host provides. On bash 5 it
# catches this class because bash 5 warns about it; it is NOT a general bash-3.2
# grammar checker, and no pattern-based linter can be one — a construct that
# bash 5 accepts silently and 3.2 rejects would still slip through. Closing that
# fully needs a real 3.2 interpreter in CI.

# Check 5 — `… | grep -q` under `set -o pipefail` (#928). `grep -q` exits the
# INSTANT it matches, closing the read end while the upstream is still writing.
# The writer takes SIGPIPE and dies 141, and `pipefail` promotes that to a
# pipeline FAILURE — so a membership test reports "not found" precisely BECAUSE
# the item was found. The verdict is inverted, not merely lost.
#
# WHY IT NEEDS A GATE RATHER THAN A ONE-TIME SWEEP: it is SIZE-dependent, not
# logic-dependent. While the upstream write fits the ~64KB pipe buffer the writer
# finishes before grep exits, nothing is signalled, and the site passes forever.
# It arms only once the data grows past the buffer — a data-growth event nobody
# associates with a test change. Measured on this repo's CI host (match on line
# 1, 20 runs): 0/20 false FAILs at ~24KB upstream, 20/20 at ~1.3MB, and 0/20 for
# the here-string rewrite at the same size.
#
# The tell is a SELF-CONTRADICTING message: #709 printed `no scanner emits
# 'command-injection'` directly above an evidence line listing command-injection
# as emitted. Because it is rare, the usual disposition is worse than a miss — a
# one-off red gets re-run, comes back green, and is filed as flake.
#
# A NEGATED site (`! printf … | grep -q`) fails in the UNSAFE direction: the real
# match reports failure, `!` flips it to success, and the assertion PASSES while
# the forbidden thing is present. 28 of the sites #928 swept were this shape.
#
# Portable replacement: a here-string — `command grep -qx "$needle" <<<"$hay"` —
# which has no writer process and no pipe status at all.
#
# NOT A BLANKET BAN, because some pipelines have a genuine upstream whose failure
# SHOULD propagate (`git worktree list | grep -q`, `find -print -quit | grep -q`).
# Those carry `# lint-allow-pipe-grep-q: <reason>` stating why the exit status is
# wanted. The reason is REQUIRED and enforced — a bare marker does not exempt.
#
# CONTINUATION-AWARE, unlike checks 1-3. Six of #928's sites put the upstream and
# the `grep -q` on separate lines (upstream ending in `|`). A per-line scanner
# would silently miss exactly those, and under-covering without saying so is the
# failure mode this file exists to prevent — so the scan carries the pending-pipe
# state across lines and reports the violation at the `grep -q` line.

# Scope: `plugins/ tests/ bin/` only. The `containers/` submodule is a separate
# repo that deliberately requires bash 5 — out of scope here.
#
# Detection strips comments before matching (a `# ... declare -A ...` or
# `# ... /usr/bin/rm ...` mention in prose is not usage) and skips the fixture
# heredocs in this file itself. Pure bash + coreutils + grep; no network.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "Shell portability (bash 3.2 clean) (#17)"

# Extended-regex alternation of the forbidden constructs. Written as fragments to
# keep each construct legible; note `local -A`/`declare -A` cover both scopes, and
# the parameter-expansion arm matches `${name,,}` / `${name^^}` / single-char too.
FORBIDDEN_RE='(declare|local)[[:space:]]+(-[A-Za-z]*A[A-Za-z]*)[[:space:]]'
FORBIDDEN_RE+='|(declare|local)[[:space:]]+(-[A-Za-z]*n[A-Za-z]*)[[:space:]]'
FORBIDDEN_RE+='|(^|[[:space:];|&])(mapfile|readarray)([[:space:]]|$)'
FORBIDDEN_RE+='|[$][{][A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,,|\^\^|,|\^)[}]'
FORBIDDEN_RE+='|;;&'

# List librarian-proper shell scripts (absolute paths, sorted). Excludes the
# containers/ submodule and this lint file itself (it carries the patterns as
# fixture/regex text, which are stripped/handled but need not self-scan).
list_shell_scripts() {
    command find "$REPO_ROOT/plugins" "$REPO_ROOT/tests" "$REPO_ROOT/bin" \
        -type f -name '*.sh' 2>/dev/null |
        command grep -vF "$SCRIPT_DIR/lint-shell-portability.sh" |
        command sort
}

# scan_file <path> — populate CUR_VIOLATIONS with `line N: <code>` per forbidden
# construct found (empty when clean). Comments are stripped first: everything
# from the first unquoted `#` is crude-removed by dropping ` #...` and `^#...`,
# which is sufficient because the forbidden tokens never legitimately share a
# line with a trailing comment that reintroduces them.
CUR_VIOLATIONS=""
scan_file() {
    local file="$1"
    CUR_VIOLATIONS=""
    local lineno=0 line code
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        # Strip a whole-line comment and any trailing ` # ...` comment. This is
        # deliberately conservative: it removes the common comment shapes so a
        # documentation mention of `declare -A` does not register as usage.
        code="$line"
        case "$code" in
            \#*) continue ;;
        esac
        code="${code%%[[:space:]]#*}"
        # Cheap builtin prefilter before any subprocess (#932). Without it this
        # arm forked a grep for EVERY line of ~108k lines of shell; measured on
        # 40 files it was 26s vs <1s, and this stage was 42% of the whole CI
        # job. Every construct FORBIDDEN_RE can match contains one of these
        # words, so the filter cannot hide a violation — `case` is a builtin, so
        # the grep now runs only on candidate lines.
        # NOTE FORBIDDEN_RE is built from THREE alternatives (see above): the
        # declare/local arm, the `${v,,}`/`${v^^}` parameter-expansion arm, and
        # `;;&`. The prefilter must cover all three or it silently stops
        # detecting the ones it misses — an earlier draft covered only the first
        # and the suite's own negative fixture caught it (`lower_hit` went
        # unflagged). `${` and `;;` are cheap, exact supersets of arms 2 and 3.
        case "$code" in
            *declare* | *local* | *mapfile* | *readarray* | *'${'* | *';;'*) ;;
            *) continue ;;
        esac
        command grep -qE "$FORBIDDEN_RE" <<<"$code" || continue
        CUR_VIOLATIONS+="line ${lineno}: ${code#"${code%%[![:space:]]*}"}"$'\n'
    done <"$file"
}

# --- Hardcoded core-utility-path ban (#443) -------------------------------------
# A tool invoked by an absolute path (`/usr/bin/mv`, `/bin/cat`) is NOT portable:
# on macOS core utils live in /bin, /usr/bin/realpath is absent, and Homebrew git
# is at /opt/homebrew/bin/git — so under `set -euo pipefail` a wrong assumed path
# hard-crashes a script whose tool is present on PATH. The portable idiom is the
# `command` builtin (`command mv`), which honors PATH while still bypassing shell
# functions/aliases. This check bans a hardcoded `/usr/bin/<tool>` or `/bin/<tool>`
# invocation, allowing the two legitimate uses of those prefixes:
#   - the `#!/usr/bin/env bash` shebang (env is the ONE tool with a stable path),
#   - `/usr/bin/env` itself anywhere (used to run a command with a scrubbed env).
# Match a leading `/usr/bin/` or `/bin/` followed by ANY lowercase tool name.
# Guards on BOTH sides so only a real tool invocation matches:
#   - leading `[^A-Za-z0-9_./]` (or start) so /usr/local/bin/x, /opt/... and an
#     already-`command`'d name don't match;
#   - trailing `[^/A-Za-z0-9_.-]` (or end) so a deeper PROJECT PATH like
#     `$ROOT/bin/lib/release/x.sh` or `$sb/bin/release.sh` is NOT flagged — a tool
#     invocation is followed by whitespace / `)` / `|` / etc., never `/` or `.`.
# The one allowed tool, `env` (the `#!/usr/bin/env` shebang and `/usr/bin/env -i`
# exec-wrapper), is excluded PROCEDURALLY in scan_file_paths, not carved out of
# the regex — an in-regex `[a-df-z]` first-letter exclusion would silently also
# skip every other `e*` tool (echo, expr, eval, egrep …), a false-negative gap.
PATHLIT_RE='(^|[^A-Za-z0-9_./])/(usr/bin|bin)/([a-z][a-z0-9_-]*)([^/A-Za-z0-9_.-]|$)'

# scan_file_paths <path> — populate CUR_PATH_VIOLATIONS with `line N: <code>` for
# each hardcoded core-utility-path invocation. Shebang (line 1) and comment lines are
# skipped, matching scan_file's comment handling, so a doc mention of `/usr/bin/x`
# does not register.
CUR_PATH_VIOLATIONS=""
scan_file_paths() {
    local file="$1"
    CUR_PATH_VIOLATIONS=""
    local lineno=0 line code
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        [ "$lineno" -eq 1 ] && continue # shebang
        code="$line"
        case "$code" in
            \#*) continue ;;
        esac
        # An explicit `# lint-allow-path: <reason>` marker exempts a line where an
        # absolute tool path is deliberate — e.g. a generated stub that must run
        # under a stripped PATH (where `command <tool>` cannot resolve). The
        # marker must carry a reason so the exemption is justified, not silent.
        case "$line" in
            *"lint-allow-path:"*) continue ;;
        esac
        code="${code%%[[:space:]]#*}"
        # `env` is the one allowed tool (the `#!/usr/bin/env` shebang handled by
        # the line-1 skip above, and the `/usr/bin/env -i` exec-wrapper). Blank out
        # every `/usr/bin/env` and `/bin/env` occurrence (with its following
        # separator so the boundary still matches) BEFORE the scan, so a line whose
        # only absolute-path token is `env` no longer matches — while a line that
        # ALSO invokes a real tool (`env … | /usr/bin/tr …`) still flags.
        scan_code="$(printf '%s\n' "$code" | command sed -E 's#(^|[^A-Za-z0-9_./])/(usr/bin|bin)/env([^/A-Za-z0-9_.-]|$)#\1 \3#g')"
        # Same builtin prefilter rationale as scan_file (#932): PATHLIT_RE can
        # only match a line containing a literal `/bin/`, so this is exact.
        case "$scan_code" in
            */bin/*) ;;
            *) continue ;;
        esac
        command grep -qE "$PATHLIT_RE" <<<"$scan_code" || continue
        CUR_PATH_VIOLATIONS+="line ${lineno}: ${code#"${code%%[![:space:]]*}"}"$'\n'
    done <"$file"
}

# --- GNU-only regex ban (#679) --------------------------------------------------
# `\s`/`\S`, `\w`/`\W`, and BRE `\|` are GNU regex extensions. BSD grep/sed read
# them as literals, so a pattern using them silently stops matching on macOS
# rather than erroring — a scanner then reports zero findings and exits 0.
#
# SCOPED TO REGEX-BEARING LINES, on purpose. A bare repo-wide grep for `\s` would
# also flag the two places where such a sequence is fixture DATA rather than a
# shell pattern — a Python `re.search(r"^\s*…")` inside a heredoc
# (validate-python-ports.sh) and a JS `console.log("…\\s…")` string
# (validate-pre-review-gates.sh). Those are payloads handed to another language,
# where `\s` is correct and must stay. They cannot carry a `lint-allow-` marker
# either: both sit inside quoted heredocs, where an added comment would corrupt
# the fixture the assertions depend on.
#
# So a line is only inspected when it actually invokes grep/sed/awk. That keeps
# the check aimed at shell regexes and lets the fixtures alone WITHOUT an
# exclusion list that would drift as tests move (and without carving the pattern
# itself, per the `PATHLIT_RE` precedent above).
# `\b` IS EXEMPT FROM THIS BAN — MEASURED, NOT ASSUMED (#679, settled in #684).
#
# It is a GNU extension like the others, and 38 sites depend on it. #679 left it
# out because modern BSD `grep -E` was *believed* to support it, and a 38-site
# rewrite is worth doing only against an observed failure. #684 stopped treating
# that belief as settled and measured it on a real BSD host.
#
# THE FINDING (macos-latest, Darwin 25.5.0, "BSD grep 2.6.0-FreeBSD" — the
# `bsd-probe` job in ci.yml running tests/probe-bsd-regex.sh):
#
#   \b under grep -E   (32 sites) ....... SUPPORTED
#   \b under grep (BRE) (6 sites) ....... SUPPORTED
#   \b under sed -E ..................... UNSUPPORTED   <-- the one real hazard
#   [[:<:]] / [[:>:]] under grep -E ..... SUPPORTED     (GNU: ERROR, exit 2)
#
# So every `\b` in the tree is safe: all 38 sites are `grep`, and BSD grep honors
# `\b` in BOTH dialects. **BSD `sed` does NOT** — but no site uses `\b` in a sed
# expression, so nothing needed porting. That asymmetry is the reason the
# exemption is scoped to grep rather than blanket: a future `sed -E 's/\bfoo\b/'`
# would silently stop substituting on macOS, the exact #679 failure mode, and
# this ban would not catch it. If you add one, port it or mark it.
#
# THERE IS NO SINGLE PORTABLE SPELLING — which is why the answer had to be
# measured rather than reasoned. GNU accepts `\b` and REJECTS `[[:<:]]` outright;
# BSD accepts both. Neither spelling is portable, so a blind tree-wide rewrite in
# either direction breaks a platform. Had the BRE rows come back UNSUPPORTED, the
# fix would have been the POSIX FLAG `grep -w` (verified working on both hosts by
# the same probe), not a respelling.
#
# Before changing anything here, read the probe's rows from a macOS run — not
# from a local one, where every `\b` row reads SUPPORTED and proves nothing about
# BSD.
GNURE_TOOL_RE='(^|[^A-Za-z0-9_-])(grep|egrep|fgrep|sed|awk)([^A-Za-z0-9_-]|$)'
GNURE_BAD_RE='\\[sSwW]|\\\|'
# `grep -P` (PCRE) is banned outright and needs no regex-bearing scoping: it is a
# GNU BUILD OPTION, absent from BSD grep entirely and from some Linux builds,
# where it exits 2 and the pipeline silently yields nothing. Matched separately
# because the flag is the violation — the pattern beside it may be perfectly
# portable. Written to catch `-P` both standalone and bundled (`-oP`).
GNUP_FLAG_RE='(^|[^A-Za-z0-9_-])(grep|egrep|zgrep)([[:space:]]+-[A-Za-z]*P([[:space:]]|$))'

# scan_file_gnu_regex <path> — populate CUR_GNURE_VIOLATIONS with `line N: <code>`
# for each GNU-only regex construct on a line that invokes grep/sed/awk.
CUR_GNURE_VIOLATIONS=""
scan_file_gnu_regex() {
    local file="$1"
    CUR_GNURE_VIOLATIONS=""
    local lineno=0 line code
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        code="$line"
        case "$code" in
            \#*) continue ;;
        esac
        # An explicit `# lint-allow-gnu-regex: <reason>` marker exempts a line
        # where a GNU construct is deliberate and the script is known GNU-only.
        # The reason is REQUIRED and enforced, not merely requested: a bare
        # `lint-allow-gnu-regex:` with nothing after the colon does NOT exempt,
        # so an exemption cannot be taken silently. `*[![:space:]]*` demands at
        # least one non-whitespace character in the tail.
        case "$line" in
            *"lint-allow-gnu-regex:"*[![:space:]]*) continue ;;
        esac
        code="${code%%[[:space:]]#*}"
        # Cheap bash prefilter before any subprocess. The overwhelming majority
        # of lines contain no backslash at all, and this scan runs over the whole
        # corpus on every pre-push — forking two greps per line made the gate
        # take minutes. `case` is a builtin, so the greps below now run only on
        # the handful of candidate lines.
        case "$code" in
            *'\'* | *-*P*) ;;
            *) continue ;;
        esac
        # `grep -P` is flagged on its own — the FLAG is the violation, so this
        # arm is deliberately not gated on the regex-bearing scoping below.
        if command grep -qE "$GNUP_FLAG_RE" <<<"$code"; then
            CUR_GNURE_VIOLATIONS+="line ${lineno}: ${code#"${code%%[![:space:]]*}"}"$'\n'
            continue
        fi
        # Only regex-bearing lines (see the scoping rationale above).
        command grep -qE "$GNURE_TOOL_RE" <<<"$code" || continue
        command grep -qE "$GNURE_BAD_RE" <<<"$code" || continue
        CUR_GNURE_VIOLATIONS+="line ${lineno}: ${code#"${code%%[![:space:]]*}"}"$'\n'
    done <"$file"
}

# --- GNU-only `env --unset=` ban (#932) -----------------------------------------
# `env --unset=VAR` is a GNU coreutils long option. BSD `env` (macOS) has no long
# options at all: it parses `--unset=VAR` as `-u` with the OPERAND `nset=VAR`, and
# dies with `env: unsetenv nset=VAR: Invalid argument`, exit 1.
#
# This is the #679 shape reached by a different route. The failure is loud in
# isolation but SILENT in situ, because the idiom appears in test sandbox helpers
# whose `env ... git init` is already `2>/dev/null`-suppressed and whose callers
# drop the status. The sandbox variable is then never assigned, and the suite dies
# far away with `sb: unbound variable` — a diagnostic that names neither `env` nor
# the platform. Found when 46 test files failed this way on a real macOS host.
#
# `-uVAR` (attached) is the portable spelling: MEASURED working on both BSD env
# (macOS 26.6) and GNU coreutils 9.7. It is preferred over separate `-u VAR`
# because it survives the array idiom these files use —
# `"${GIT_SCRUB[@]/#/-u}"` expands one token per name, where `/#/-u /` could not.
#
# Scoped to lines invoking `env`, matching the GNU-regex ban's scoping rationale:
# a bare `--unset=` may legitimately appear in prose about some other tool.
GNUENV_TOOL_RE='(^|[^A-Za-z0-9_-])env([^A-Za-z0-9_-]|$)'

# --- Other GNU-only flags found by the same sweep (#932) -------------------------
# Each was measured on macOS 26.6 and each fails in the silent direction, which is
# why they are banned by pattern rather than left to a reviewer's eye:
#
#   realpath -m   BSD: `illegal option -- m`. Callers wrap it in `|| echo "$1"`,
#                 so the path comes back UNRESOLVED. In seed-worktree-trust.sh
#                 that DEFEATED the symlink under-root guard (issue #21) on every
#                 Mac. Use the `cd -P`/`pwd -P` walk in that script.
#   mktemp --suffix=  BSD rejects it AND STILL EXITS 0, so the assigned variable is
#                 empty and the failure surfaces as a bare redirect error naming
#                 neither mktemp nor the platform. Create a temp DIR and name the
#                 file inside it.
#   touch -d      BSD wants `-t [[CC]YY]MMDDhhmm[.SS]`, prints usage to stderr and
#                 STILL EXITS 0 — the mtime is silently unchanged, so a staleness
#                 window never elapses and the test reads "not stale". BSD's `-A`
#                 adjust form is likewise rejected by GNU: neither spelling is
#                 portable, so probe `touch -d` on a scratch file and branch
#                 (backdate_mtime in tests/golem-scripts/90-transcript-liveness.sh).
#   date -d       GNU-only; BSD spells the epoch form `date -r <epoch>`.
GNUFLAG_BAD_RE='(^|[^A-Za-z0-9_-])(realpath[[:space:]]+(-[A-Za-z]*[[:space:]]+)*-m([[:space:]]|$)|mktemp[^|;&]*--suffix=|touch[[:space:]]+(-[A-Za-z]*[[:space:]]+)*-d([[:space:]]|$)|date[[:space:]]+(-[A-Za-z]*[[:space:]]+)*-d([[:space:]]|$))'

# scan_file_gnu_env <path> — populate CUR_GNUENV_VIOLATIONS with `line N: <code>`
# for each GNU-only `env --unset=` on a line that invokes env.
CUR_GNUENV_VIOLATIONS=""
scan_file_gnu_env() {
    local file="$1"
    CUR_GNUENV_VIOLATIONS=""
    local lineno=0 line code
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        code="$line"
        case "$code" in
            \#*) continue ;;
        esac
        # Same required-reason marker contract as the GNU-regex ban above.
        case "$line" in
            *"lint-allow-gnu-env:"*[![:space:]]*) continue ;;
        esac
        code="${code%%[[:space:]]#*}"
        # Cheap builtin prefilter before any subprocess.
        case "$code" in
            *--unset=*) ;;
            *) continue ;;
        esac
        printf '%s\n' "$code" | command grep -qE "$GNUENV_TOOL_RE" || continue
        CUR_GNUENV_VIOLATIONS+="line ${lineno}: ${code#"${code%%[![:space:]]*}"}"$'\n'
    done <"$file"
}

# scan_file_gnu_flags <path> — populate CUR_GNUFLAG_VIOLATIONS with `line N: <code>`
# for each GNU-only coreutils flag (realpath -m, mktemp --suffix=, touch -d,
# date -d). Same required-reason marker contract as the bans above.
CUR_GNUFLAG_VIOLATIONS=""
scan_file_gnu_flags() {
    local file="$1"
    CUR_GNUFLAG_VIOLATIONS=""
    local lineno=0 line code
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        code="$line"
        case "$code" in
            \#*) continue ;;
        esac
        case "$line" in
            *"lint-allow-gnu-flag:"*[![:space:]]*) continue ;;
        esac
        code="${code%%[[:space:]]#*}"
        # Cheap builtin prefilter: every banned form needs one of these words.
        case "$code" in
            *realpath* | *mktemp* | *touch* | *date*) ;;
            *) continue ;;
        esac
        printf '%s\n' "$code" | command grep -qE "$GNUFLAG_BAD_RE" || continue
        CUR_GNUFLAG_VIOLATIONS+="line ${lineno}: ${code#"${code%%[![:space:]]*}"}"$'\n'
    done <"$file"
}

# --- `… | grep -q` under pipefail ban (#928) -------------------------------------
# See "Check 5" in the header for the mechanism, the measured size-dependence,
# and why the exemption exists. Two regexes, because the shape spans lines:
#
#   PIPEQ_RE      the whole pipeline on ONE line — something, a pipe, a `grep -q`
#   PIPEQ_HEAD_RE a `grep -q` STARTING a line, for the continuation case where
#                 the upstream ended in a trailing `|`
#
# `-[A-Za-z]*q` matches the flag bundled anywhere (`-q`, `-qx`, `-qxF`, `-Eq`),
# which is how the sites in this tree are actually spelled.
PIPEQ_GREP='(command[[:space:]]+)?(grep|egrep|fgrep)[[:space:]]+(-[A-Za-z]*[[:space:]]+)*-[A-Za-z]*q'
PIPEQ_RE="\|[[:space:]]*${PIPEQ_GREP}"
PIPEQ_HEAD_RE="^[[:space:]]*${PIPEQ_GREP}"

# scan_file_pipe_grep_q <path> — populate CUR_PIPEQ_VIOLATIONS with
# `line N: <code>` for each `… | grep -q` pipeline (empty when clean).
#
# CONTINUATION STATE: `pending_pipe` is set when a line ends in a bare `|` and is
# consumed by the next non-blank line. That is what makes the multi-line spelling
# visible; without it the six sites #928 found spanning two lines would read as
# clean forever.
CUR_PIPEQ_VIOLATIONS=""
scan_file_pipe_grep_q() {
    local file="$1"
    CUR_PIPEQ_VIOLATIONS=""
    local lineno=0 line code pending_pipe=0 hit
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        code="$line"
        case "$code" in
            \#*)
                # A whole-line comment neither violates nor breaks a pending
                # pipe: `cmd |` followed by a comment line then `grep -q` is
                # still one pipeline, so the state deliberately survives.
                continue
                ;;
        esac
        code="${code%%[[:space:]]#*}"
        # An explicit `# lint-allow-pipe-grep-q: <reason>` marker exempts a line
        # whose upstream has a genuine failure that SHOULD propagate. The reason
        # is REQUIRED and enforced, not merely requested — a bare
        # `lint-allow-pipe-grep-q:` with nothing after the colon does NOT exempt,
        # so an exemption can never be taken silently. `*[![:space:]]*` demands
        # at least one non-whitespace character in the tail.
        case "$line" in
            *"lint-allow-pipe-grep-q:"*[![:space:]]*)
                pending_pipe=0
                continue
                ;;
        esac
        # Cheap bash prefilter before any subprocess. This scan runs over the
        # whole corpus on every pre-push, and the overwhelming majority of lines
        # contain neither a pipe nor a grep; `case` is a builtin, so the grep
        # below runs only on candidate lines. Same precedent as check 3.
        hit=0
        case "$code" in
            *'|'*grep*) hit=1 ;;
        esac
        if [ "$hit" -eq 1 ] && command grep -qE "$PIPEQ_RE" <<<"$code"; then
            CUR_PIPEQ_VIOLATIONS+="line ${lineno}: ${code#"${code%%[![:space:]]*}"}"$'\n'
        elif [ "$pending_pipe" -eq 1 ]; then
            case "$code" in
                *grep*)
                    if command grep -qE "$PIPEQ_HEAD_RE" <<<"$code"; then
                        CUR_PIPEQ_VIOLATIONS+="line ${lineno}: ${code#"${code%%[![:space:]]*}"}"$'\n'
                    fi
                    ;;
            esac
        fi
        # Recompute the continuation state from THIS line: does it end in a bare
        # `|`? A `||` is a control operator, not a pipe, so it must not arm the
        # continuation — hence the `[^|]` guard before the final pipe.
        pending_pipe=0
        case "$code" in
            *[![:space:]]*)
                if command grep -qE '(^|[^|])\|[[:space:]]*$' <<<"$code"; then
                    pending_pipe=1
                fi
                ;;
        esac
    done <"$file"
}

# scan_file_parses <path> — populate CUR_PARSE_VIOLATIONS with the parser
# diagnostic when `bash -n` writes ANYTHING to stderr (empty when clean).
#
# See "Check 4" in the header for why this keys on stderr rather than on the
# exit status; changing it to an exit-code test silently re-opens #906.
CUR_PARSE_VIOLATIONS=""
scan_file_parses() {
    local file="$1" diag
    CUR_PARSE_VIOLATIONS=""
    # `|| true` so a non-zero bash -n (a hard syntax error) does not abort the
    # suite under `set -e`; the diagnostic itself is the signal either way.
    diag="$(bash -n "$file" 2>&1 || true)"
    [ -n "$diag" ] || return 0
    CUR_PARSE_VIOLATIONS="$diag"
}

# Per-file test body (reads CUR_FILE).
CUR_FILE=""
test_file_portable() {
    scan_file "$CUR_FILE"
    assert_equals "" "$CUR_VIOLATIONS" \
        "$(command basename "$CUR_FILE") must be bash-3.2 clean (no declare -A/mapfile/nameref/case-conv/;;&)"
}

# Per-file test body for the hardcoded-path ban (reads CUR_FILE).
test_file_no_hardcoded_paths() {
    scan_file_paths "$CUR_FILE"
    assert_equals "" "$CUR_PATH_VIOLATIONS" \
        "$(command basename "$CUR_FILE") must invoke coreutils via \`command <tool>\`, not a hardcoded /usr/bin//bin path (#443)"
}

# Per-file test body for the GNU-only regex ban (reads CUR_FILE).
test_file_no_gnu_regex() {
    scan_file_gnu_regex "$CUR_FILE"
    assert_equals "" "$CUR_GNURE_VIOLATIONS" \
        "$(command basename "$CUR_FILE") must use POSIX classes ([[:space:]], [[:alnum:]_]) and -E alternation, not GNU \\s/\\w/\\| (#679)"
}

# Per-file test body for the GNU-only coreutils-flag ban (reads CUR_FILE).
test_file_no_gnu_flags() {
    scan_file_gnu_flags "$CUR_FILE"
    assert_equals "" "$CUR_GNUFLAG_VIOLATIONS" \
        "$(command basename "$CUR_FILE") must avoid GNU-only coreutils flags (realpath -m, mktemp --suffix=, touch -d, date -d) (#932)"
}

# Per-file test body for the GNU-only `env --unset=` ban (reads CUR_FILE).
test_file_no_gnu_env() {
    scan_file_gnu_env "$CUR_FILE"
    assert_equals "" "$CUR_GNUENV_VIOLATIONS" \
        "$(command basename "$CUR_FILE") must spell env unset as \`-uVAR\`, not GNU-only \`--unset=VAR\` (#932)"
}

# Per-file test body for the `| grep -q` ban (reads CUR_FILE).
test_file_no_pipe_grep_q() {
    scan_file_pipe_grep_q "$CUR_FILE"
    assert_equals "" "$CUR_PIPEQ_VIOLATIONS" \
        "$(command basename "$CUR_FILE") must not pipe into \`grep -q\` under pipefail — a SUCCESSFUL match SIGPIPEs the writer and inverts the verdict; use a here-string (#928)"
}

# Per-file test body for the parse check (reads CUR_FILE).
test_file_parses() {
    scan_file_parses "$CUR_FILE"
    assert_equals "" "$CUR_PARSE_VIOLATIONS" \
        "$(command basename "$CUR_FILE") must parse cleanly under \`bash -n\` — a parse error makes the whole suite exit 0 without running (#906)"
}

# Negative case: scan_file's violation branch must actually fire on each
# forbidden construct, and must NOT fire on portable equivalents or on a comment
# that merely mentions a construct. Mirrors the two-branch coverage of
# tests/lint-action-pins.sh.
test_negative_case_fires() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    # A quoted heredoc keeps every construct literal (no expansion). This lint
    # excludes itself from the corpus (see list_shell_scripts), so the forbidden
    # tokens appearing here in the fixture never self-flag. scan_file strips
    # trailing comments, so assertions match the CODE token (not a comment marker)
    # — a unique variable name per bad line makes each assertion unambiguous. The
    # trailing portable lines (prose comment, set-membership, tr-fold) must NOT
    # surface in the violations.
    command cat >"$tmp/bad.sh" <<'EOF'
#!/usr/bin/env bash
declare -A assoc_hit
local -A localassoc_hit
mapfile -t mapfile_hit <f
readarray -t readarray_hit <f
declare -n nameref_hit=x
lower_hit="${x,,}"
upper_hit="${x^^}"
case $x in a) : ;;& b) : ;; esac  # fallthru_hit_marker
# this comment mentions declare -A but is prose: commentprose_ok
okset=" "; case " $okset " in *" 1 "*) : ;; esac
okfold="$(printf %s "$x" | tr '[:upper:]' '[:lower:]')"
EOF

    scan_file "$tmp/bad.sh"

    assert_not_empty "$CUR_VIOLATIONS" "scan_file flags forbidden constructs (violation branch fires)"
    assert_contains "$CUR_VIOLATIONS" "assoc_hit" "declare -A is flagged"
    assert_contains "$CUR_VIOLATIONS" "localassoc_hit" "local -A is flagged"
    assert_contains "$CUR_VIOLATIONS" "mapfile_hit" "mapfile is flagged"
    assert_contains "$CUR_VIOLATIONS" "readarray_hit" "readarray is flagged"
    assert_contains "$CUR_VIOLATIONS" "nameref_hit" "declare -n nameref is flagged"
    assert_contains "$CUR_VIOLATIONS" "lower_hit" 'lowercase ${v,,} is flagged'
    assert_contains "$CUR_VIOLATIONS" "upper_hit" 'uppercase ${v^^} is flagged'
    assert_contains "$CUR_VIOLATIONS" ";;&" ';;& fallthrough is flagged'
    # Portable lines must NOT surface.
    assert_not_contains "$CUR_VIOLATIONS" "commentprose_ok" "A prose comment mentioning a construct is NOT flagged"
    assert_not_contains "$CUR_VIOLATIONS" "okset" "A space-delimited set + case membership is NOT flagged"
    assert_not_contains "$CUR_VIOLATIONS" "okfold" "tr-based case folding is NOT flagged"
}

# Negative case for the hardcoded-path ban: scan_file_paths must fire on a
# hardcoded /usr/bin//bin invocation and must NOT fire on the portable
# `command <tool>` form, the env shebang, /usr/bin/env, /usr/local/bin, or a
# prose comment mentioning an absolute path.
test_negative_case_paths_fire() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064
    trap "command rm -rf '$tmp'" RETURN

    command cat >"$tmp/paths.sh" <<'EOF'
#!/usr/bin/env bash
usrbin_hit="$(/usr/bin/mv a b)"
binhit="$(/bin/cat f)"
githit="$(/usr/bin/git status)"
echohit="$(/bin/echo hi)"
exprhit="$(/usr/bin/expr 1 + 1)"
okcommand="$(command mv a b)"
okenv="$(/usr/bin/env -i sh -c :)"
okenvthentool="$(/usr/bin/env -i sh)"
oklocal="$(/usr/local/bin/rm x)"
okprojpath="$(source "$ROOT"/bin/lib/release/util.sh)"
okprojscript="$(bash "$sb"/bin/release.sh patch)"
# a prose comment naming /usr/bin/rm is commentpath_ok
EOF

    scan_file_paths "$tmp/paths.sh"

    assert_not_empty "$CUR_PATH_VIOLATIONS" "scan_file_paths flags hardcoded paths (violation branch fires)"
    assert_contains "$CUR_PATH_VIOLATIONS" "usrbin_hit" "/usr/bin/mv is flagged"
    assert_contains "$CUR_PATH_VIOLATIONS" "binhit" "/bin/cat is flagged"
    assert_contains "$CUR_PATH_VIOLATIONS" "githit" "/usr/bin/git is flagged"
    # An `e*`-named tool must still be flagged (the exemption is `env` ALONE, not
    # every tool starting with `e` — regression guard for the #443-review gap).
    assert_contains "$CUR_PATH_VIOLATIONS" "echohit" "/bin/echo is flagged (not exempted as an e* tool)"
    assert_contains "$CUR_PATH_VIOLATIONS" "exprhit" "/usr/bin/expr is flagged (not exempted as an e* tool)"
    # Portable / allowed forms must NOT surface.
    assert_not_contains "$CUR_PATH_VIOLATIONS" "okcommand" "command <tool> is NOT flagged"
    assert_not_contains "$CUR_PATH_VIOLATIONS" "okenv" "/usr/bin/env is NOT flagged"
    assert_not_contains "$CUR_PATH_VIOLATIONS" "oklocal" "/usr/local/bin/<tool> is NOT flagged"
    assert_not_contains "$CUR_PATH_VIOLATIONS" "okprojpath" "a deeper /bin/lib/... project path is NOT flagged"
    assert_not_contains "$CUR_PATH_VIOLATIONS" "okprojscript" "a /bin/<name>.sh project script path is NOT flagged"
    assert_not_contains "$CUR_PATH_VIOLATIONS" "commentpath_ok" "A prose comment naming an absolute path is NOT flagged"
}

# Negative case for the GNU-only regex ban: scan_file_gnu_regex must fire on each
# construct when a regex tool is invoked, and must NOT fire on the POSIX
# equivalents, on prose, on an allow-marked line, or on a `\s` that is payload for
# ANOTHER language rather than a shell pattern (the fixture case the scoping
# exists for — see the rationale above scan_file_gnu_regex).
# Negative case for the GNU-only `env --unset=` ban: scan_file_gnu_env must fire
# on the GNU spelling in each shape it actually appears in, and stay silent on the
# portable `-u` forms. Without this the check could sit inert and a clean run
# would be indistinguishable from an unenforced rule (#932).
test_negative_case_gnu_env_fires() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064
    trap "command rm -rf '$tmp'" RETURN

    command cat >"$tmp/gnuenv.sh" <<'EOF'
#!/usr/bin/env bash
literal_hit="$(/usr/bin/env --unset=BASH_ENV cmd)"
array_hit="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" git init)"
bare_hit="$(env --unset=FOO cmd)"
command_hit="$(command env --unset=FOO cmd)"
okattached="$(/usr/bin/env -uBASH_ENV cmd)"
okseparate="$(/usr/bin/env -u FOO cmd)"
okarray="$(/usr/bin/env "${GIT_SCRUB[@]/#/-u}" git init)"
okmarked="$(env --unset=FOO cmd)"  # lint-allow-gnu-env: GNU-only helper
bareMarker_hit="$(env --unset=BAR cmd)"  # lint-allow-gnu-env:
okother="a --unset=X flag belonging to some other tool"
# a prose comment naming env --unset= is commentenv_ok
EOF

    scan_file_gnu_env "$tmp/gnuenv.sh"

    assert_not_empty "$CUR_GNUENV_VIOLATIONS" "scan_file_gnu_env flags --unset= (violation branch fires)"
    assert_contains "$CUR_GNUENV_VIOLATIONS" "literal_hit" 'a literal --unset=NAME is flagged'
    assert_contains "$CUR_GNUENV_VIOLATIONS" "array_hit" 'the "${ARR[@]/#/--unset=}" array idiom is flagged'
    assert_contains "$CUR_GNUENV_VIOLATIONS" "bare_hit" 'a bare `env --unset=` is flagged'
    assert_contains "$CUR_GNUENV_VIOLATIONS" "command_hit" '`command env --unset=` is flagged'
    assert_contains "$CUR_GNUENV_VIOLATIONS" "bareMarker_hit" 'a REASONLESS lint-allow-gnu-env marker does NOT exempt'

    assert_not_contains "$CUR_GNUENV_VIOLATIONS" "okattached" 'the portable -uNAME form is NOT flagged'
    assert_not_contains "$CUR_GNUENV_VIOLATIONS" "okseparate" 'the portable -u NAME form is NOT flagged'
    assert_not_contains "$CUR_GNUENV_VIOLATIONS" "okarray" 'the portable -u array idiom is NOT flagged'
    assert_not_contains "$CUR_GNUENV_VIOLATIONS" "okmarked" 'a lint-allow-gnu-env line is NOT flagged'
    assert_not_contains "$CUR_GNUENV_VIOLATIONS" "okother" 'a --unset= with no env on the line is NOT flagged'
    assert_not_contains "$CUR_GNUENV_VIOLATIONS" "commentenv_ok" 'a full-line comment is NOT flagged'
}

test_negative_case_gnu_regex_fires() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064
    trap "command rm -rf '$tmp'" RETURN

    command cat >"$tmp/gnure.sh" <<'EOF'
#!/usr/bin/env bash
sgrep_hit="$(grep -nE '^\s*print\(' f)"
wgrep_hit="$(grep -nE '^\w+\(\)' f)"
altsed_hit="$(sed 's/^\(a\|b\)//' f)"
capS_hit="$(grep -E '\S+' f)"
capW_hit="$(grep -E '\W+' f)"
awk_hit="$(awk '/^\s*x/ {print}' f)"
pcre_hit="$(grep -P 'a+' f)"
pcrebundled_hit="$(grep -oP 'a+' f)"
okspace="$(grep -nE '^[[:space:]]*print\(' f)"
okword="$(grep -nE '^[[:alnum:]_]+\(\)' f)"
okalt="$(sed -E 's/^(a|b)//' f)"
okmarked="$(grep -E '^\s*x' f)"  # lint-allow-gnu-regex: GNU-only helper
bareMarker_hit="$(grep -E '^\s*y' f)"  # lint-allow-gnu-regex:
okpayload="a python string r\"^\s*console\." handed to another language"
# a prose comment naming \s and \w and \| is commentgnu_ok
EOF

    # The whitespace-only-reason fixture is appended with printf, NOT written in
    # the heredoc above: its trailing spaces are the whole point, and a heredoc
    # line ending in whitespace is silently stripped by formatters/editors —
    # leaving a fixture byte-identical to the bare-marker one, which would test
    # nothing while looking like it did.
    command printf '%s\n' \
        "wsMarker_hit=\"\$(grep -E '^\\s*z' f)\"  # lint-allow-gnu-regex:   " \
        >>"$tmp/gnure.sh"

    scan_file_gnu_regex "$tmp/gnure.sh"

    assert_not_empty "$CUR_GNURE_VIOLATIONS" "scan_file_gnu_regex flags GNU constructs (violation branch fires)"
    assert_contains "$CUR_GNURE_VIOLATIONS" "sgrep_hit" '\s in a grep pattern is flagged'
    assert_contains "$CUR_GNURE_VIOLATIONS" "wgrep_hit" '\w in a grep pattern is flagged'
    assert_contains "$CUR_GNURE_VIOLATIONS" "altsed_hit" '\| BRE alternation in sed is flagged'
    assert_contains "$CUR_GNURE_VIOLATIONS" "capS_hit" '\S is flagged'
    assert_contains "$CUR_GNURE_VIOLATIONS" "capW_hit" '\W is flagged'
    assert_contains "$CUR_GNURE_VIOLATIONS" "awk_hit" '\s in an awk pattern is flagged'
    # `grep -P` is flagged on the FLAG alone — note both patterns above are
    # portable EREs, so only the PCRE mode selection can be what fires here.
    assert_contains "$CUR_GNURE_VIOLATIONS" "pcre_hit" 'grep -P (PCRE mode) is flagged'
    assert_contains "$CUR_GNURE_VIOLATIONS" "pcrebundled_hit" 'grep -oP (bundled PCRE flag) is flagged'
    # POSIX / allowed forms must NOT surface.
    assert_not_contains "$CUR_GNURE_VIOLATIONS" "okspace" '[[:space:]] is NOT flagged'
    assert_not_contains "$CUR_GNURE_VIOLATIONS" "okword" '[[:alnum:]_] is NOT flagged'
    assert_not_contains "$CUR_GNURE_VIOLATIONS" "okalt" 'sed -E (a|b) alternation is NOT flagged'
    assert_not_contains "$CUR_GNURE_VIOLATIONS" "okmarked" 'a lint-allow-gnu-regex line is NOT flagged'
    # The reason is enforced, not just documented: a marker with an empty tail
    # must NOT buy an exemption, or the escape hatch becomes a silent one.
    assert_contains "$CUR_GNURE_VIOLATIONS" "bareMarker_hit" 'a REASONLESS lint-allow-gnu-regex marker does NOT exempt'
    assert_contains "$CUR_GNURE_VIOLATIONS" "wsMarker_hit" 'a whitespace-only reason does NOT exempt'
    assert_not_contains "$CUR_GNURE_VIOLATIONS" "okpayload" 'a non-shell regex payload (no grep/sed/awk) is NOT flagged'
    assert_not_contains "$CUR_GNURE_VIOLATIONS" "commentgnu_ok" "A prose comment naming the constructs is NOT flagged"
}

# The `\b` EXEMPTION, pinned (#684). Measured on macos-latest (BSD grep
# 2.6.0-FreeBSD): `\b` is SUPPORTED under both `grep -E` and plain `grep` (BRE),
# so all 38 sites in the tree are safe and the ban deliberately omits it. See the
# rationale block above GNURE_BAD_RE for the full probe output.
#
# This is a pin, not a preference: without it, someone tightening GNURE_BAD_RE to
# "also catch \b" would flag 38 working sites and force a rewrite the evidence
# says is unnecessary — and the reasoning would have to be rediscovered from
# scratch on a GNU host, where it cannot be.
#
# The `sed` half is the one thing the probe found that DOES break: BSD sed reads
# `\b` as a literal. No site uses it there today, so nothing needed porting, and
# that asymmetry is exactly what the last assertion records — a documented
# KNOWN GAP rather than an oversight. If a `sed -E 's/\bfoo\b/'` is ever added it
# will silently stop substituting on macOS and this ban will not catch it.
test_word_boundary_exemption_is_pinned() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064
    trap "command rm -rf '$tmp'" RETURN

    command cat >"$tmp/wb.sh" <<'EOF'
#!/usr/bin/env bash
ereb_ok="$(grep -nE '\bfoo\b' f)"
breb_ok="$(grep -n '\bfoo\b' f)"
sedb_gap="$(sed -E 's/\bfoo\b/bar/' f)"
EOF

    scan_file_gnu_regex "$tmp/wb.sh"

    assert_not_contains "$CUR_GNURE_VIOLATIONS" "ereb_ok" \
        '\b under grep -E is NOT flagged — BSD-verified SUPPORTED, 32 sites (#684)'
    assert_not_contains "$CUR_GNURE_VIOLATIONS" "breb_ok" \
        '\b under plain grep (BRE) is NOT flagged — BSD-verified SUPPORTED, 6 sites (#684)'
    # KNOWN GAP, asserted so it cannot be mistaken for coverage: BSD sed reads
    # `\b` literally, but the ban is scoped to the constructs #679 swept and does
    # not cover it. Zero sites use it, so this documents the hole rather than a
    # regression.
    assert_not_contains "$CUR_GNURE_VIOLATIONS" "sedb_gap" \
        '\b in a sed expression is NOT flagged either — a KNOWN GAP: BSD sed reads it literally (#684)'
}

# Negative case for the parse check (#906). Both arms matter:
#
#   BAD  — a heredoc nested inside a command substitution. This is the exact
#          construct that kept the bsd-probe job inert. bash 3.2 cannot parse it
#          at all; bash 5 accepts it but WARNS, which is what this gate reads.
#   GOOD — the same probe rewritten with the heredoc OUTSIDE the substitution
#          (write the script to a file, then run it). This arm is what stops the
#          check from being a blanket "any heredoc is suspicious" rule and pins
#          the migration target as genuinely clean.
#
# The fixture is written with printf rather than a heredoc: a quoted heredoc
# containing the literal terminator `PY` would end THIS file's heredoc early.
test_negative_case_parse_fires() {
    local tmp hard_rc
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    {
        printf '#!/usr/bin/env bash\n'
        printf 'out="$(python3 - "$ARG" <<%sPY%s 2>&1)" || rc=$?\n' "'" "'"
        printf 'print("hi")\n'
        printf 'PY\n'
    } >"$tmp/bad.sh"

    {
        printf '#!/usr/bin/env bash\n'
        printf 'command cat >"$WORKDIR/probe.py" <<%sPY%s\n' "'" "'"
        printf 'print("hi")\n'
        printf 'PY\n'
        printf 'out="$(python3 "$WORKDIR/probe.py" "$ARG" 2>&1)" || rc=$?\n'
    } >"$tmp/good.sh"

    # Guard the fixture itself: if `bash -n` ever stops warning on the bad
    # spelling (a future bash change), the assertion below would pass for the
    # wrong reason and this gate would quietly become a no-op.
    assert_not_empty "$(bash -n "$tmp/bad.sh" 2>&1 || true)" \
        "fixture guard: this bash actually diagnoses heredoc-in-command-substitution"

    scan_file_parses "$tmp/bad.sh"
    assert_not_empty "$CUR_PARSE_VIOLATIONS" \
        "heredoc inside a command substitution IS flagged — bash 3.2 cannot parse it (#906)"

    scan_file_parses "$tmp/good.sh"
    assert_equals "" "$CUR_PARSE_VIOLATIONS" \
        "the temp-file rewrite is NOT flagged — the migration target must be clean (#906)"

    # The OTHER documented outcome: a hard syntax error, where `bash -n` exits
    # NON-ZERO. The header claims non-empty stderr covers both arms, so both
    # arms need a fixture — a comment asserting a property nothing tests is how
    # a later narrowing (e.g. matching only the "unterminated here-document"
    # substring) would silently drop this half. The exit-code guard is the
    # point: it pins that the two arms really do differ in exit status, so this
    # case cannot degenerate into a copy of the warning-only one above.
    printf '#!/usr/bin/env bash\nif [ x\n' >"$tmp/hard.sh"

    bash -n "$tmp/hard.sh" 2>/dev/null && hard_rc=0 || hard_rc=$?
    assert_true "[ \"$hard_rc\" -ne 0 ]" \
        "fixture guard: a hard syntax error really does exit non-zero (the other arm)"

    scan_file_parses "$tmp/hard.sh"
    assert_not_empty "$CUR_PARSE_VIOLATIONS" \
        "a hard syntax error IS flagged too — stderr capture is exit-code agnostic (#906)"
}

# Negative case: scan_file_pipe_grep_q must fire on every spelling of the shape
# — including the MULTI-LINE one, which is the whole reason the scanner carries
# continuation state — and must not fire on the here-string rewrite, on a
# properly-reasoned exemption, or on a `||` control operator.
#
# The multi-line assertions are the load-bearing ones. A per-line scanner passes
# every other case in this fixture while silently missing the six real sites that
# span two lines; without `multiline_hit`/`multiline_cmd_hit` a later
# "simplification" back to a single-line regex would go green.
test_negative_case_pipe_grep_q_fires() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064
    trap "command rm -rf '$tmp'" RETURN

    command cat >"$tmp/pipeq.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if printf '%s\n' "$hay" | grep -q "$n"; then plain_hit=1; fi
if printf '%s\n' "$hay" | command grep -qx "$n"; then cmd_hit=1; fi
if ! printf '%s\n' "$hay" | command grep -qxF "$n"; then negated_hit=1; fi
if printf '%s\n' "$hay" | command grep -Eq "$n"; then flagorder_hit=1; fi
if locale -a 2>/dev/null | command grep -qixF "$c"; then locale_hit=1; fi
if git worktree list --porcelain | command grep -qx "w $r"; then git_hit=1; fi
multiline_hit="$(printf '%s\n' "$hay" |
    grep -q "$n")"
multiline_cmd_hit="$(command printf '%s\n' "$hay" |
    command grep -qxF "$n")"
if command grep -qx "$n" <<<"$hay"; then ok_herestring=1; fi
if command grep -qx "$n" "$file"; then ok_directfile=1; fi
if printf '%s\n' "$hay" | command grep -c "$n"; then ok_notquiet=1; fi
if git worktree list | command grep -qx "w"; then ok_marked=1; fi  # lint-allow-pipe-grep-q: upstream failure must propagate
if git worktree list | command grep -qx "w"; then bareMarker_hit=1; fi  # lint-allow-pipe-grep-q:
ok_orlist=1 ||
    command grep -qx "$n" <<<"$hay"
# a prose comment naming printf | grep -q is commentpipeq_ok
EOF

    # The whitespace-only-reason fixture is appended with printf, NOT written in
    # the heredoc above: its trailing spaces are the whole point, and a heredoc
    # line ending in whitespace is silently stripped by formatters/editors —
    # leaving a fixture byte-identical to the bare-marker one, which would test
    # nothing while looking like it did. (Same reasoning as check 3's.)
    command printf '%s\n' \
        "if git worktree list | command grep -qx \"w\"; then wsMarker_hit=1; fi  # lint-allow-pipe-grep-q:   " \
        >>"$tmp/pipeq.sh"

    scan_file_pipe_grep_q "$tmp/pipeq.sh"

    assert_not_empty "$CUR_PIPEQ_VIOLATIONS" "scan_file_pipe_grep_q flags the shape (violation branch fires)"
    assert_contains "$CUR_PIPEQ_VIOLATIONS" "plain_hit" 'a bare `| grep -q` is flagged'
    assert_contains "$CUR_PIPEQ_VIOLATIONS" "cmd_hit" 'a `| command grep -qx` is flagged'
    assert_contains "$CUR_PIPEQ_VIOLATIONS" "negated_hit" 'a NEGATED site is flagged (fails in the unsafe direction)'
    assert_contains "$CUR_PIPEQ_VIOLATIONS" "flagorder_hit" '`grep -Eq` (q not first in the bundle) is flagged'
    assert_contains "$CUR_PIPEQ_VIOLATIONS" "locale_hit" 'a `locale -a | command grep -qixF` is flagged'
    assert_contains "$CUR_PIPEQ_VIOLATIONS" "git_hit" 'an UNMARKED genuine-upstream pipeline is flagged (the marker is what exempts)'
    # The continuation arm. These two lines carry no pipe of their own — only the
    # scanner's pending-pipe state can reach them.
    assert_contains "$CUR_PIPEQ_VIOLATIONS" "grep -q \"\$n\")" 'a MULTI-LINE pipeline is flagged (continuation state)'
    assert_contains "$CUR_PIPEQ_VIOLATIONS" "command grep -qxF \"\$n\")" 'a MULTI-LINE `command grep` pipeline is flagged'
    # Allowed forms must NOT surface.
    assert_not_contains "$CUR_PIPEQ_VIOLATIONS" "ok_herestring" 'the here-string rewrite is NOT flagged'
    assert_not_contains "$CUR_PIPEQ_VIOLATIONS" "ok_directfile" 'grep reading a file directly is NOT flagged'
    assert_not_contains "$CUR_PIPEQ_VIOLATIONS" "ok_notquiet" 'a pipe into a NON-quiet grep is NOT flagged (it reads all input)'
    assert_not_contains "$CUR_PIPEQ_VIOLATIONS" "ok_marked" 'a reasoned lint-allow-pipe-grep-q line is NOT flagged'
    # `||` is a control operator, not a pipe: it must not arm the continuation,
    # or every `x ||`-continued line followed by a grep would false-positive.
    assert_not_contains "$CUR_PIPEQ_VIOLATIONS" "ok_orlist" '`||` does NOT arm the continuation state'
    # The reason is enforced, not just documented: a marker with an empty tail
    # must NOT buy an exemption, or the escape hatch becomes a silent one.
    assert_contains "$CUR_PIPEQ_VIOLATIONS" "bareMarker_hit" 'a REASONLESS lint-allow-pipe-grep-q marker does NOT exempt'
    assert_contains "$CUR_PIPEQ_VIOLATIONS" "wsMarker_hit" 'a whitespace-only reason does NOT exempt'
    assert_not_contains "$CUR_PIPEQ_VIOLATIONS" "commentpipeq_ok" 'a prose comment naming the shape is NOT flagged'
}

# Discover the corpus.
scripts_list="$(list_shell_scripts)"

# Guard: the suite must actually inspect something. A gate that silently checks
# zero files (dir moved, find regressed) is worse than no gate.
test_corpus_non_empty() {
    assert_not_empty "$scripts_list" "At least one shell script must be found to lint"
}

run_test test_corpus_non_empty "Shell-script corpus is non-empty (gate is not a no-op)"
run_test test_negative_case_fires "scan_file flags every forbidden construct (violation path)"
run_test test_negative_case_paths_fire "scan_file_paths flags hardcoded /usr/bin//bin paths (#443)"
run_test test_negative_case_gnu_regex_fires "scan_file_gnu_regex flags GNU-only regex constructs (#679)"
run_test test_word_boundary_exemption_is_pinned "\\b stays exempt — BSD-verified for grep, known gap for sed (#684)"
run_test test_negative_case_gnu_env_fires "scan_file_gnu_env flags GNU-only env --unset= (#932)"
run_test test_negative_case_parse_fires "scan_file_parses flags heredoc-in-command-substitution, not its rewrite (#906)"
run_test test_negative_case_pipe_grep_q_fires "scan_file_pipe_grep_q flags \`| grep -q\` pipelines, incl. multi-line (#928)"

while IFS= read -r f; do
    [ -n "$f" ] || continue
    CUR_FILE="$f"
    run_test test_file_portable "${f#"$REPO_ROOT"/}: bash-3.2 clean"
    run_test test_file_no_hardcoded_paths "${f#"$REPO_ROOT"/}: no hardcoded core-utility paths (#443)"
    run_test test_file_no_gnu_regex "${f#"$REPO_ROOT"/}: no GNU-only regex constructs (#679)"
    run_test test_file_no_gnu_env "${f#"$REPO_ROOT"/}: no GNU-only env --unset= (#932)"
    run_test test_file_no_gnu_flags "${f#"$REPO_ROOT"/}: no GNU-only coreutils flags (#932)"
    run_test test_file_parses "${f#"$REPO_ROOT"/}: parses under bash -n (#906)"
    run_test test_file_no_pipe_grep_q "${f#"$REPO_ROOT"/}: no \`| grep -q\` under pipefail (#928)"
done <<<"$scripts_list"

generate_report
