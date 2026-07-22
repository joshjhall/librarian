#!/usr/bin/env bash
# PreToolUse Bash-guard hook for read-only review/analysis subagents (issue #448).
#
# #426 showed a nominally read-only reviewer subagent can run destructive shell
# (`rm -rf`) against the LIVE working tree and be technically compliant: the
# harness READONLY prompt banned file/VCS mutation but not destructive shell
# exec, and every review agent holds `Bash`. #426 shipped the belt (strengthened
# prose + a regression lint) and scope-locked the ONE origin agent
# (code-reviewer) at the tool level. This hook is the deferred remainder: it
# enforces the destructive-shell ban at the TOOL level for EVERY Bash-capable
# review/analysis subagent (checker, audit-*, the default orchestrate poll agent)
# that still holds unscoped `Bash` and is guarded only by prose.
#
# Mechanism: Claude Code fires PreToolUse before every Bash call, session-wide,
# and pipes the call's JSON on stdin. A plugin hook cannot be scoped to
# subagents-only at the matcher level, so this script does the branching. The
# stdin schema (verified empirically against the running CLI, 2.1.215, by
# capturing a live subagent Bash call) is:
#   { session_id, transcript_path, cwd, prompt_id, permission_mode, effort,
#     hook_event_name, tool_name, tool_input:{command}, tool_use_id,
#     agent_id, agent_type }
# where `agent_id` + `agent_type` are present ONLY for a subagent call — a
# main-session Bash call carries NO agent_id. That presence is the caller signal.
#
# GATING — DENY iff ALL of:
#   1. Positive subagent: stdin `agent_id` (or camelCase `agentId`) is non-empty.
#      The main session has none, so it is structurally in the ALLOW path — its
#      legitimate worktree-teardown deletes are never at risk, no matter how
#      broad the deny-set is.
#   2. Destructive head: the command (normalized, split on ; && || | ( $( )
#      matches the deny-set — the file-removing/renaming/truncating tokens and
#      the working-tree-resetting git verbs (clean, reset-hard, checkout-dashdash)
#      plus `>`/`>>` redirection — lifted from the READONLY_POLL / READONLY /
#      checker.md prose constants.
#   3. Not scratch-confined: allow when the command stages a mktemp sandbox or the
#      destructive target resolves under /tmp, $TMPDIR, or /var/tmp (the
#      sandbox carve-out those same prose constants grant).
#   To DENY: exit 0 with the JSON permissionDecision:"deny" envelope + a reason
#   the model can act on. Everything else exits 0 silently (allow).
#
# FAILURE MODE — fail-open for the session, fail-LOUD on parse trouble (operator
# decision, #448). On any parse failure (empty stdin, non-JSON, no agent_id
# resolvable) emit a loud stderr diagnostic then ALLOW. Rationale: fail-closed
# would, if the input shape ever regresses, deny the MAIN session's teardown rm —
# breaking the happy path for every session, the worse outcome. This guard is a
# SECOND layer behind #426's shipped prose+lint belt, so a *detectable* degraded-
# allow (loud on stderr, and validate-bash-guard.sh asserts the positive-block
# path so a permanent no-op fails CI) is tolerable where a false main-session
# block is not. Note the exit contract is INVERTED from the sibling golem-notify
# hook (which always exits 0 / never blocks) — this one must be able to deny.
#
# DETECTION SCOPE — a pragmatic tokenizer, NOT a shell parser or a sandbox. It is
# the second enforcement layer behind #426's shipped prose+lint belt, and it
# biases toward blocking with a clear reason (a false negative silently defeats a
# safety control; a false positive costs one denial the agent can react to by
# re-running under `mktemp -d`). It catches the common, non-adversarial shapes:
# separators (`;` `&&` `||` `&` `|` newline), pipes and subshells, quoted/escaped
# heads (`"rm"`/`\rm`), wrapper prefixes (`env`/`sudo`/`time`/`exec`/`xargs`),
# compound-command keywords (`if…then rm…fi`, `case`, `while…do`, brace groups),
# per-operand scratch checks, and full redirect-target scanning.
#
# ACCEPTED OUT-OF-SCOPE GAPS (documented, deliberately not covered — matching
# #426's literal-token prose; a real shell would be needed to close these, which
# is a non-goal for a defense-in-depth layer):
#   - command INDIRECTION: `b=rm; $b -rf x`, `$(which rm) -rf x`, `eval`.
#   - argument INDIRECTION: `xargs rm`, `find … -delete`, `find … -exec rm`.
#   - obfuscation/encoding: `base64 -d | sh`, char-by-char reconstruction.
#   - non-standard binaries: `busybox rm`, `/usr/local/bin/rm`, `perl -e unlink`.
#   - statement-ORDER edge: the contrived reverse `d=src; rm -rf $d;
#     d=$(mktemp -d)` (delete a live var BEFORE its name is reassigned to a
#     scratch dir) — the natural `mktemp-then-delete` forms ARE covered.
# These are logged nowhere and pass silently BY DESIGN; the belt (#426 prose) and
# human PR review remain the backstop for them.
#
# jq is used when present; a pure-bash fallback still enforces when jq is absent
# (base macOS ships no jq), so the guard never silently weakens for lack of jq.
#
# Input  (stdin):  PreToolUse hook JSON (see schema above).
# Output (stdout): nothing (allow) OR the permissionDecision:"deny" JSON envelope.
# Exit:            always 0 — the decision travels in the JSON, not the code.
set -uo pipefail

DIAG_TAG="librarian-bash-guard"

# --- Portable tool resolution (#443) ----------------------------------------
# Claude Code invokes PreToolUse hooks with a potentially minimal environment, so
# this hook historically hardcoded /usr/bin/<tool> to survive a stripped PATH.
# Those absolute paths are WRONG on macOS (core utils in /bin) and hard-crash the
# hook there. `_bin <tool>` honors PATH first (the `command -v` builtin needs no
# external binary), then falls back to scanning the standard bin dirs so it still
# resolves under a stripped PATH, then yields the bare name. The candidate list is
# bare DIRECTORIES, not /usr/bin/<tool> literals, so the #443 lint does not flag
# them. NOTE: the deny-set `case` patterns below (e.g. `rm | /bin/rm |
# /usr/bin/rm`) are match DATA — the absolute-path command forms this guard must
# DETECT in a scanned subagent command — NOT invocations, so they stay literal.
_BIN_CANDIDATE_DIRS="/usr/bin /bin /usr/local/bin /opt/homebrew/bin /sbin /usr/sbin"
_bin() {
    _br="$(command -v "$1" 2>/dev/null || true)"
    if [ -z "$_br" ]; then
        for _bd in $_BIN_CANDIDATE_DIRS; do
            [ -x "$_bd/$1" ] && {
                _br="$_bd/$1"
                break
            }
        done
    fi
    printf '%s' "${_br:-$1}"
}
CAT="$(_bin cat)"
SED="$(_bin sed)"
HEAD="$(_bin head)"
TR="$(_bin tr)"

# --- Read stdin -------------------------------------------------------------
payload="$("$CAT" 2>/dev/null || true)"
if [ -z "$payload" ]; then
    printf '%s: empty PreToolUse input; NOT enforcing (fail-open)\n' "$DIAG_TAG" >&2
    exit 0
fi

# --- Extract agent_id + command --------------------------------------------
# Prefer jq; fall back to a pure-bash extractor so the guard enforces without jq.
agent_id=""
command_str=""
have_fields=0
if command -v jq >/dev/null 2>&1; then
    # `have_fields` gates on whether jq successfully PARSED the payload as JSON —
    # not on the presence of any particular field. Once the bytes parse, jq's
    # extraction of agent_id/command is authoritative and MORE robust than the sed
    # fallback, so we must not discard it and re-derive via the weaker scraper just
    # because some unrelated field is absent (#448 review). `jq empty` succeeds iff
    # the input is valid JSON.
    if printf '%s' "$payload" | jq empty >/dev/null 2>&1; then
        have_fields=1
        # `// empty` yields "" for absent/null. agentId is read as a defensive
        # alternate spelling (the verified field is snake_case agent_id).
        agent_id="$(printf '%s' "$payload" | jq -r '(.agent_id // .agentId) // empty' 2>/dev/null || true)"
        command_str="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
        # A parsed payload with no command is not a Bash call we can evaluate —
        # nothing to enforce against, so allow (no destructive command present).
        if [ -z "$command_str" ]; then
            exit 0
        fi
    fi
fi

if [ "$have_fields" -eq 0 ]; then
    # jq absent or parse failed — hand-roll extraction. These are deliberately
    # simple string scrapes over the raw JSON: they can only ADD enforcement
    # (find an agent_id / command that jq would have found), never relax it, and
    # any miss lands in the fail-open+loud branch below.
    #
    # agent_id: capture the value after "agent_id"|"agentId" : "..." — a sed
    # regex tolerating whitespace around the colon. Empty if absent.
    agent_id="$(printf '%s' "$payload" |
        "$SED" -n 's/.*"agent_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        "$HEAD" -n1)"
    if [ -z "$agent_id" ]; then
        agent_id="$(printf '%s' "$payload" |
            "$SED" -n 's/.*"agentId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
            "$HEAD" -n1)"
    fi
    # command: value of "command":"..." inside tool_input. A command string may
    # contain escaped quotes; the scrape takes the shortest span to the first
    # unescaped closing quote, which is conservative — a truncated command can
    # only DROP trailing deny-tokens (fail toward allow), and the primary jq path
    # handles the exact bytes whenever jq is present.
    command_str="$(printf '%s' "$payload" |
        "$SED" -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        "$HEAD" -n1)"
    if [ -z "$command_str" ]; then
        printf '%s: could not parse PreToolUse input; NOT enforcing (fail-open)\n' "$DIAG_TAG" >&2
        exit 0
    fi
fi

# --- Caller gate: main session (no agent_id) is never blocked ---------------
if [ -z "$agent_id" ]; then
    exit 0
fi

# --- Deny-set detection -----------------------------------------------------
# Normalize in TWO steps so statement separators survive. A real newline inside
# tool_input.command is itself a statement separator, so translate newlines (and
# carriage returns) to a literal `;` FIRST, before collapsing the remaining
# control chars to spaces — otherwise a multi-line script would join two
# statements into one segment and hide a destructive second line (#448 review).
norm="$(printf '%s' "$command_str" |
    "$TR" '\n\r' ';;' |
    "$TR" '[:cntrl:]' ' ' |
    "$TR" -s ' ')"

# The ONLY sanctioned variable-target carve-out is deleting the very directory a
# `mktemp -d` was assigned to: `d=$(mktemp -d); ... "$d"`. `mktemp_var` holds that
# exact variable NAME so operand_ok can allow a reference to `$d`/`"$d"`/`${d}` and
# NOTHING else — an unrelated live variable like `$HOME/repo` must not piggyback on
# a stray mktemp (#448 review #2). Detection runs on a STATEMENT-level split (only
# `;`/`&&`/`||`/`&`/newline, NOT the finer `$(`/`|`/`(` command-level split) so the
# `VAR=$(mktemp -d)` assignment stays intact in one piece to match. mktemp_var is
# then set as each statement is walked below, so a `$d` use is excused only if its
# mktemp assignment already appeared EARLIER in statement order (#448 review #3).
# Starts empty; the `VAR=$(mktemp)-then-use` ordering is what the carve-out targets.
# Detect the name once, on a STATEMENT-level split (only `;`/`&&`/`||`/`&`/newline,
# NOT the finer `$(`/`|`/`(` command-level split used for head-matching) so a
# `VAR=$(mktemp -d)` assignment stays intact in one piece to match. Boundary-
# anchored so a longer `.*` prefix cannot shave leading chars off the name.
# ACCEPTED GAP (#448 review #3, documented out-of-scope): detection is not
# statement-ORDER-aware, so the contrived reverse form `d=src; rm -rf $d;
# d=$(mktemp -d)` (assign live, delete, THEN stage a scratch dir under the same
# name) is not caught — the natural forms `d=$(mktemp -d); rm -rf "$d"` are.
mktemp_var="$(printf '%s' "$norm" |
    "$TR" ';&|' '\n\n\n' |
    "$SED" -n 's/.*\(^\|[^A-Za-z0-9_]\)\([A-Za-z_][A-Za-z0-9_]*\)=[`$]\{1\}[({]*mktemp[[:space:]].*/\2/p' |
    "$HEAD" -n1)"

# is_scratch <path> -> return 0 only when the path is PREFIX-anchored under a
# recognized scratch root (/tmp, /var/tmp, $TMPDIR). A substring match would
# wrongly carve out a live path that merely contains `/tmp/` (`src/tmp/live`) or
# one that escapes via `..` (`/tmp/../etc`), so anchor to the prefix and reject
# any `..` traversal segment (#448 review).
is_scratch() {
    case "$1" in
        *".."*) return 1 ;; # a traversal can escape the sandbox
    esac
    case "$1" in
        /tmp | /var/tmp) return 0 ;;
        /tmp/* | /var/tmp/*) return 0 ;;
        '$TMPDIR'* | '${TMPDIR}'*) return 0 ;;
        '"$TMPDIR"'* | '"${TMPDIR}"'*) return 0 ;;
    esac
    return 1
}

# Redirection to a NON-scratch path is destructive regardless of the command
# head (e.g. `echo x > tracked.py`). Check EVERY `>` target, not just the last:
# a command can pair an early destructive redirect with a trailing scratch one
# (`cmd 2> tracked.py > /tmp/log`) — inspecting only the final `>` would miss the
# first (#448 review). Split on `>` and test each following token. (Defined after
# is_scratch — shell functions must exist before this scan runs.)
redir_bad=1
case "$norm" in
    *">"*)
        _rest="$norm"
        while :; do
            case "$_rest" in
                *">"*) ;;
                *) break ;;
            esac
            # Drop everything through the next `>`, then a leading `>` (from `>>`)
            # and any whitespace, so `_tgt` is the redirect's actual file token.
            _rest="${_rest#*>}"
            _rest="${_rest#>}"                         # second `>` of `>>`
            _rest="${_rest#"${_rest%%[![:space:]]*}"}" # trim leading spaces
            _tgt="${_rest%%[[:space:]]*}"              # token up to next whitespace
            _tgt="${_tgt#&}"                           # `>&2` fd-dup, not a file — strip &
            [ -n "$_tgt" ] || continue
            case "$_tgt" in
                [0-9]) continue ;; # `2>`/`>&1` fd number, not a file
            esac
            is_scratch "$_tgt" || {
                redir_bad=0
                break
            }
        done
        ;;
esac

# operand_ok <token> -> return 0 when a single destructive operand is safe: a
# scratch-confined path, or a reference to the EXACT variable that a `mktemp -d`
# was assigned to (`$d`/`"$d"`/`${d}` when `d=$(mktemp -d)` staged it). A generic
# "any $-operand" allowance is unsafe — `$HOME/repo` is not scratch — so we bind
# strictly to `mktemp_var` (#448 review #2).
operand_ok() {
    is_scratch "$1" && return 0
    if [ -n "$mktemp_var" ]; then
        case "$1" in
            '$'"$mktemp_var" | '"$'"$mktemp_var"'"' | \
                '${'"$mktemp_var"'}' | '"${'"$mktemp_var"'}"') return 0 ;;
            '$'"$mktemp_var"/* | '"$'"$mktemp_var"'"'/* | \
                '${'"$mktemp_var"'}'/* | '"${'"$mktemp_var"'}"'/*) return 0 ;;
        esac
    fi
    return 1
}

# target_ok <segment> -> return 0 (safe, skip the deny) ONLY when EVERY path-like
# operand of the destructive command is safe (operand_ok). A single live-literal
# target makes the whole segment unsafe — so `rm -rf src/live` is never excused by
# a sibling `mktemp -d`, and `rm /tmp/a live/b` (mixed) is denied. Flags (leading
# `-`) and the git subcommand token are skipped; a segment with NO path operand at
# all is NOT auto-safe (returns 1) so a bare destructive verb still denies.
target_ok() {
    local seg="$1" tok saw_path=1 skip_next=0 is_truncate=1
    # Drop the command head (and, for git, the subcommand) — operands follow.
    case "$1" in
        truncate\ * | /usr/bin/truncate\ *) is_truncate=0 ;; # lint-allow-path: deny-set match DATA, not an invocation
    esac
    seg="${seg#* }"
    case "$1" in
        git\ * | /usr/bin/git\ *) seg="${seg#* }" ;; # lint-allow-path: deny-set match DATA, not an invocation
    esac
    for tok in $seg; do
        if [ "$skip_next" = "1" ]; then
            skip_next=0
            # The skipped token is a size/reference VALUE — but if it looks like a
            # path (contains `/`), don't blindly trust it: fall through and check
            # it as an operand so `truncate -s live/file.py x` can't hide a live
            # target in the size slot (#448 review #2).
            case "$tok" in
                */*) ;;        # path-like: check it below
                *) continue ;; # a bare size/ref value: not a path
            esac
        fi
        # Only `truncate` takes a separated value flag whose next token is a size
        # or a reference file, not the target (`truncate -s 0 f`, `-r ref f`).
        # `-r` must NOT be treated this way for rm/mv/git-clean, where it is the
        # boolean recursive switch (#448 review #1) — hence the truncate scoping.
        if [ "$is_truncate" -eq 0 ]; then
            case "$tok" in
                -s | -r | --size | --reference)
                    skip_next=1
                    continue
                    ;;
            esac
        fi
        case "$tok" in
            -*) continue ;;  # a flag, not a path operand
            *=*) continue ;; # inline assignment, not a target
        esac
        saw_path=0
        operand_ok "$tok" || return 1 # any unsafe operand -> not safe
    done
    # No path operand seen -> cannot prove scratch-confinement -> not safe.
    [ "$saw_path" -eq 0 ]
}

# Split the normalized command into segments on shell separators so a deny-head
# after any of them is caught (e.g. a delete chained after `ls &&`, `sleep 1 &`,
# or a newline — already mapped to `;` above). Order matters: collapse the
# two-char operators `&&`/`||` to a break FIRST, then the single-char `&`/`|`, so
# the two-char forms are not shredded into stray single breaks (#448 review).
# bash-3.2 clean — translate every separator to a newline, then read the lines.
segments="$(printf '%s' "$norm" |
    "$SED" 's/&&/\n/g; s/||/\n/g; s/&/\n/g; s/;/\n/g; s/|/\n/g; s/\$(/\n/g; s/`/\n/g; s/(/\n/g; s/)/\n/g')"

matched=""
while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    # Trim leading whitespace.
    seg="${seg#"${seg%%[![:space:]]*}"}"
    # Strip leading `VAR=value ` assignments, and a leading `env`/`sudo` /
    # `command`/`builtin` wrapper, so the real head is exposed. Each arm must
    # make progress (consume a token) or break, so a segment that is ONLY an
    # assignment / wrapper with no following command (`first` has no trailing
    # space) terminates the loop instead of spinning.
    while :; do
        first="${seg%% *}"
        # No space left -> `first` IS the whole segment; nothing follows to
        # expose as a head, so stop (covers a bare `d=$(mktemp` fragment).
        case "$seg" in
            *" "*) ;;
            *) break ;;
        esac
        case "$first" in
            */*) break ;; # a path, not a bare VAR=/wrapper
            *=*)
                seg="${seg#* }"
                seg="${seg#"${seg%%[![:space:]]*}"}"
                ;;
            env | sudo | command | builtin | nice | nohup | time | exec | xargs)
                seg="${seg#* }"
                seg="${seg#"${seg%%[![:space:]]*}"}"
                ;;
            # Bash compound-command reserved words that can PRECEDE a command in a
            # split segment (`if …; then rm …; fi` splits to a segment headed by
            # `then`). Strip them so the real deny-head is exposed — a common
            # cleanup idiom, not an adversarial trick (#448 review 3).
            if | then | elif | else | fi | for | while | until | do | done | \
                case | 'esac' | 'in' | '{' | '}' | '!')
                seg="${seg#* }"
                seg="${seg#"${seg%%[![:space:]]*}"}"
                ;;
            *) break ;;
        esac
    done

    # Head token and the segment tail (for two-word git heads + target scan).
    head="${seg%% *}"
    # Strip shell quoting/escaping that a real shell resolves away before running
    # the binary, so `"rm"`, `'rm'`, and `\rm` (the classic alias-bypass idiom)
    # all normalize to `rm` before the exact-token case-match (#448 review).
    head="${head#\\}" # leading backslash-escape
    head="${head#\"}"
    head="${head%\"}" # surrounding double quotes
    head="${head#\'}"
    head="${head%\'}" # surrounding single quotes
    case "$head" in
        rm | /bin/rm | /usr/bin/rm) # lint-allow-path: deny-set match DATA, not an invocation
            target_ok "$seg" && continue
            matched="rm"
            break
            ;;
        mv | /bin/mv | /usr/bin/mv) # lint-allow-path: deny-set match DATA, not an invocation
            target_ok "$seg" && continue
            matched="mv"
            break
            ;;
        truncate | /usr/bin/truncate) # lint-allow-path: deny-set match DATA, not an invocation
            target_ok "$seg" && continue
            matched="truncate"
            break
            ;;
        git | /usr/bin/git) # lint-allow-path: deny-set match DATA, not an invocation
            rest="${seg#"$head"}"
            rest="${rest# }"
            # Skip git's global options so `sub` lands on the real subcommand:
            # `git -C src clean -fd` must still read as `clean` (#448 review 4).
            # `-C`/`-c`/`--git-dir`/`--work-tree`/`--namespace` (separated forms)
            # take a following argument; the `--opt=val` attached forms are single
            # tokens. Loop until the head is no longer a global option.
            while :; do
                sub="${rest%% *}"
                case "$rest" in *" "*) ;; *) break ;; esac
                case "$sub" in
                    -C | -c | --git-dir | --work-tree | --namespace)
                        rest="${rest#* }"
                        rest="${rest# }" # drop opt
                        rest="${rest#* }"
                        rest="${rest# }"
                        ;; # drop its value
                    --*=* | -*)
                        rest="${rest#* }"
                        rest="${rest# }"
                        ;; # attached/boolean opt
                    *) break ;;
                esac
            done
            sub="${rest%% *}"
            case "$sub" in
                clean)
                    target_ok "$seg" && continue
                    matched="git clean"
                    break
                    ;;
                reset)
                    case " $rest " in
                        *" --hard"*)
                            matched="git reset --hard"
                            break
                            ;;
                    esac
                    ;;
                checkout)
                    # `$rest` is padded with a trailing space in the case word,
                    # so a trailing `--` becomes `-- ` and `*" -- "*` matches both
                    # `git checkout -- file` and a bare `git checkout --`.
                    case " $rest " in
                        *" -- "*)
                            matched="git checkout --"
                            break
                            ;;
                    esac
                    ;;
            esac
            ;;
    esac
done <<EOF
$segments
EOF

# Redirection to a non-scratch target is its own deny reason (redir_bad=0 means
# the scan above found at least one `>` target outside a scratch root).
if [ -z "$matched" ] && [ "$redir_bad" = "0" ]; then
    matched="output redirection to a tracked path"
fi

if [ -z "$matched" ]; then
    exit 0
fi

# --- Deny -------------------------------------------------------------------
reason="Blocked destructive shell (\`$matched\`) in read-only review/analysis subagent ${agent_id}: this agent must not delete or mutate the live working tree (#426/#448). If you must reproduce something, do it inside a fresh \`mktemp -d\` sandbox, never against the checkout."

if command -v jq >/dev/null 2>&1; then
    jq -cn --arg reason "$reason" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' \
        2>/dev/null && exit 0
fi
# No jq: hand-roll the deny envelope. Sanitize the reason (drop backslashes and
# control chars that can't be JSON-escaped without a real encoder, then escape
# double quotes) so the output stays valid JSON.
reason_safe="$(printf '%s' "${reason//\\/}" | "$TR" -d '[:cntrl:]')"
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' \
    "${reason_safe//\"/\\\"}"
exit 0
