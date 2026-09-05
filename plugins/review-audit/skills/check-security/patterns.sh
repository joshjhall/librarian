#!/usr/bin/env bash
# check-security — Deterministic Pre-Scan
#
# Detects security patterns that can be caught by regex: hardcoded secrets,
# injection risks, XSS patterns, and insecure cryptography. Results are
# passed to the LLM for context-dependent confirmation/dismissal.
#
# Input:  $1 = file containing paths to scan (one per line)
# Output: TSV to stdout: file\tline\tcategory\tevidence\tcertainty
#
# Exit codes:
#   0 = success (zero or more findings)
#   1 = usage error (missing argument)
#
# Note: Uses full paths for commands per project shell-scripting conventions.
#
# Runtime: this tool has a Python 3.11+ primary implementation (patterns.py) and
# this bash script as the portable fallback. When a python3>=3.11 is available
# the shim below execs patterns.py (identical TSV contract); otherwise the bash
# body runs. Set PATTERNS_FORCE_BASH=1 to force the fallback (used by the parity
# test). See CLAUDE.md § Key conventions (runtime policy).
set -euo pipefail

# --- runtime selection: prefer python3>=3.11, else this bash fallback --------
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${PATTERNS_FORCE_BASH:-0}" != "1" ] && [ -f "$_here/patterns.py" ] &&
    command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    exec python3 "$_here/patterns.py" "$@"
fi

FILE_LIST="${1:?Usage: patterns.sh <file-list>}"

if [ ! -f "$FILE_LIST" ]; then
    echo "Error: file list not found: $FILE_LIST" >&2
    exit 1
fi

# --- input-shape guard (#816) -----------------------------------------------
# The file-list argument is a list of PATHS, one per line -- not a diff. Handed
# a diff, the scan loop reads each diff line as a path, matches nothing, emits
# nothing, and exits 0: an output indistinguishable from a genuinely clean scan.
# That is the #538/#571 failure (a gate that sits inert and reads as a pass)
# reached through the INPUT rather than the runtime, and it is easy to hit --
# both inputs come from adjacent `git diff` invocations differing only by
# `--name-only`, and both are plausibly named `*.diff`.
#
# Two checks, deliberately different in severity:
#
#   DIFF SHAPE -> hard failure (exit 1). Unambiguous: no file list contains a
#     `diff --git`/`@@`/`+++`/`--- ` line, so there is no legitimate input this
#     rejects, and the silent-zero scan is exactly what the caller must not get.
#
#   NOTHING RESOLVES -> stderr warning, exit code UNCHANGED. This one cannot be
#     an error: a list naming only deleted files is legitimate (the paths are
#     gone by design), and an EMPTY list exiting 0 in silence is a contract
#     tests/validate-prescans.sh pins for every pre-scan. So it is a warning
#     that catches stale lists and wrong-cwd invocations without breaking either
#     real case -- which is why it is guarded on a NON-EMPTY list.
#
# BASH_SOURCE[0], not $0: inside a function it names the file this function was
# DEFINED in, so the message stays correct under a symlink, a relative
# invocation from another cwd, or a `source` -- the same reasoning the SCRIPT_DIR
# computation elsewhere in these scanners uses.
# The multi-byte Unicode format characters the reflected line must not carry:
# the zero-width family (U+200B-200F), bidi overrides/embeddings (U+202A-202E),
# bidi isolates (U+2066-2069) and BOM (U+FEFF). A bidi override is the dangerous
# one: it makes the reflected text RENDER reversed, so a hostile path can display
# as something other than what it is.
#
# Built with printf as LITERAL UTF-8 bytes, not written as \xNN escapes -- those
# are a GNU sed extension that BSD sed reads as literal text, which is the silent
# #679 failure class (the pattern stops matching and nothing reports it).
# An ALTERNATION, not a bracket class: a bracket over multi-byte sequences
# matches byte-wise and can split a character.
#
# This is what keeps the bash fallback in step with _strip_control() in the
# python primary, whose isprintable() rejects category Cf for free. Without it
# the two runtimes diverge on exactly the path the fallback exists to serve
# (measured: RTLO survived in bash, was stripped in python).
_PRESCAN_BIDI_BYTES="$(command printf '\342\200\213|\342\200\214|\342\200\215|\342\200\216|\342\200\217|')"
_PRESCAN_BIDI_BYTES="${_PRESCAN_BIDI_BYTES}$(command printf '\342\200\252|\342\200\253|\342\200\254|\342\200\255|\342\200\256|')"
_PRESCAN_BIDI_BYTES="${_PRESCAN_BIDI_BYTES}$(command printf '\342\201\246|\342\201\247|\342\201\250|\342\201\251|\357\273\277')"

assert_file_list_shape() {
    local list="$1"
    local tool="${BASH_SOURCE[0]##*/}"
    local line total=0 resolved=0

    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        total=$((total + 1))
        case "$line" in
            'diff --git '* | '--- '* | '+++ '* | '@@ '*)
                # STRIP CONTROL BYTES before echoing the line back. The input is
                # caller-supplied and may come from an untrusted diff; raw ESC/BEL
                # reaching the operator's terminal can move the cursor, hide
                # following output, or drive an OSC title-bar sequence. Keep tab
                # (\011) so indentation still reads. Measured: without this, a
                # crafted `diff --git \033[31m...\033]0;X\007` line renders as
                # live escapes rather than text.
                # Two passes, because one tool cannot do both portably.
                # (1) tr strips single-byte C0 controls + DEL (ESC, BEL, ...).
                #     Tab (\011) is kept so indentation still reads.
                # (2) sed strips the MULTI-BYTE Unicode format characters that
                #     tr cannot express: bidi overrides/isolates (U+202A-202E,
                #     U+2066-2069), the zero-width family (U+200B-200F) and BOM
                #     (U+FEFF). A bidi override is the dangerous one -- it makes
                #     the reflected path RENDER in reverse, so `evil.js` can be
                #     displayed as something else entirely. `tr -d '[:cntrl:]'`
                #     does NOT cover these (locale-dependent, and C0-only in the
                #     C locale, measured), which is why they are enumerated as
                #     literal UTF-8 byte sequences -- a spelling that behaves
                #     identically under BSD and GNU sed.
                #     This mirrors _strip_control() in the python primary, whose
                #     `isprintable()` rejects category Cf for free. Without pass
                #     (2) the two runtimes DIVERGE on exactly the fallback path
                #     the bash body exists to serve (verified: RTLO survived in
                #     bash and was stripped in python).
                _safe_line="$(command printf '%s' "$line" |
                    command tr -d '\000-\010\013-\037\177' |
                    command sed -E "s/(${_PRESCAN_BIDI_BYTES})//g")"
                echo "Error: ${tool}: input looks like a DIFF, not a file list: ${list}" >&2
                echo "  Offending line: ${_safe_line}" >&2
                echo "  Expected one path per line -- did you mean 'git diff --name-only'?" >&2
                echo "  Refusing to scan: a diff matches no path, so this would emit nothing and exit 0, which reads as a clean scan." >&2
                exit 1
                ;;
        esac
        if [ -e "$line" ]; then
            resolved=$((resolved + 1))
        fi
    done <"$list"

    if [ "$total" -gt 0 ] && [ "$resolved" -eq 0 ]; then
        echo "Warning: ${tool}: no path listed in ${list} exists (${total} non-empty lines); scanning nothing." >&2
        echo "  A stale list or a wrong working directory yields an empty scan that reads as clean. Findings below (if any) are from a partial view." >&2
    fi
}

assert_file_list_shape "$FILE_LIST"

# --- char-aware evidence truncation (#17 bash<->python equivalence) ----------
# Evidence is truncated to a fixed number of CHARACTERS to match the Python
# primary's str[:N]. `printf '%.Ns'` truncates by BYTES (and can split a UTF-8
# character), so multibyte evidence diverged between the two impls. Detect a
# UTF-8 locale once, then slice with bash parameter expansion under it
# (char-wise); fall back to the byte-wise printf if no UTF-8 locale exists.
_PRESCAN_UTF8_LOCALE=""
for _cand in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    if locale -a 2>/dev/null | command grep -qixF "$_cand"; then
        _PRESCAN_UTF8_LOCALE="$_cand"
        break
    fi
done
unset _cand
# truncate_chars <maxchars> <string> — first <maxchars> characters on stdout.
truncate_chars() {
    local n="$1" s="$2"
    if [ -n "$_PRESCAN_UTF8_LOCALE" ]; then
        local LC_CTYPE="$_PRESCAN_UTF8_LOCALE"
        printf '%s' "${s:0:$n}"
    else
        command printf "%.${n}s" "$s"
    fi
}

# --- the lexical model (ADR 0002 § 2, #622 Phase 1) --------------------------
# A SUBSET of the normative EXT_LANG / COMMENT_RE in
# check-decomposition/loc_engine.py, mirroring patterns.py's copy arm-for-arm.
# tests/lint-language-table-sync.sh asserts subset-consistency: this may cover
# FEWER extensions than the normative table but may never contradict it.
#
# Two `case` functions rather than an associative array: `declare -A` is bash 4
# and macOS ships bash 3.2 (CLAUDE.md § runtime policy). The same idiom
# check-decomposition/patterns.sh already uses for its awk is_comment().

# lang_of <file> — language key on stdout, or EMPTY when unmodeled. An empty
# result is the ADR § 1 `—` state and gates every lexical-dependent detector.
# Bracket classes keep the match case-insensitive and fork-free (#754).
lang_of() {
    case "$1" in
        *.[Pp][Yy]) command printf 'py' ;;
        *.[Jj][Ss] | *.[Jj][Ss][Xx] | *.[Mm][Jj][Ss] | *.[Cc][Jj][Ss]) command printf 'js' ;;
        *.[Tt][Ss] | *.[Tt][Ss][Xx]) command printf 'ts' ;;
        *.[Rr][Ss]) command printf 'rs' ;;
        *.[Gg][Oo]) command printf 'go' ;;
        *.[Rr][Bb]) command printf 'rb' ;;
        *.[Ss][Hh] | *.[Bb][Aa][Ss][Hh]) command printf 'sh' ;;
        *.[Jj][Aa][Vv][Aa] | *.[Kk][Tt]) command printf 'java' ;;
        *.[Ss][Ww][Ii][Ff][Tt]) command printf 'swift' ;;
        # CONFIG FORMATS — see the long note beside patterns.py's EXT_LANG.
        # Scanner-local (absent from the normative table, so they cannot
        # contradict it), and present because omitting them silently stops
        # scanning the file types where checked-in credentials most often live.
        # All spell a line comment with `#`.
        *.[Yy][Mm][Ll] | *.[Yy][Aa][Mm][Ll]) command printf 'conf' ;;
        *.[Ii][Nn][Ii] | *.[Cc][Ff][Gg] | *.[Cc][Oo][Nn][Ff]) command printf 'conf' ;;
        *.[Tt][Oo][Mm][Ll] | *.[Pp][Rr][Oo][Pp][Ee][Rr][Tt][Ii][Ee][Ss]) command printf 'conf' ;;
        *.[Ee][Nn][Vv]) command printf 'conf' ;;
        # MAINSTREAM C-FAMILY — see the note beside patterns.py's EXT_LANG.
        # Scanner-local, and present because main DID scan them: a
        # `$password = "…"` in .php and an `MD5(` in .c both fired before this
        # branch. All spell `//` line comments with `/* */` blocks.
        *.[Pp][Hh][Pp]) command printf 'cfamily' ;;
        *.[Cc] | *.[Hh] | *.[Cc][Cc]) command printf 'cfamily' ;;
        *.[Cc][Pp][Pp] | *.[Hh][Pp][Pp] | *.[Cc][Ss]) command printf 'cfamily' ;;
        *.[Ss][Cc][Aa][Ll][Aa] | *.[Mm] | *.[Mm][Mm]) command printf 'cfamily' ;;
        *.[Dd][Aa][Rr][Tt] | *.[Vv] | *.[Zz][Ii][Gg] | *.[Cc][Rr]) command printf 'cfamily' ;;
        *.[Gg][Rr][Oo][Oo][Vv][Yy] | *.[Gg][Rr][Aa][Dd][Ll][Ee]) command printf 'cfamily' ;;
        # `#`-COMMENT LANGUAGES beyond py/sh/rb — grouped by MARKER, since the
        # lexical fact is the marker itself.
        *.[Pp][Ll] | *.[Pp][Mm] | *.[Rr] | *.[Jj][Ll]) command printf 'hash' ;;
        *.[Ee][Xx] | *.[Ee][Xx][Ss] | *.[Nn][Ii][Mm] | *.[Tt][Cc][Ll]) command printf 'hash' ;;
        *.[Zz][Ss][Hh] | *.[Ff][Ii][Ss][Hh]) command printf 'hash' ;;
        *.[Pp][Ss]1 | *.[Pp][Ss][Mm]1) command printf 'hash' ;;
        *.[Tt][Ff] | *.[Tt][Ff][Vv][Aa][Rr][Ss]) command printf 'hash' ;;
        # MISCELLANEOUS MARKERS — one family per distinct spelling.
        *.[Ll][Uu][Aa] | *.[Ss][Qq][Ll]) command printf 'dashdash' ;;
        *.[Hh][Ss] | *.[Ee][Ll][Mm]) command printf 'dashdash' ;;
        *.[Vv][Bb] | *.[Bb][Aa][Ss]) command printf 'quote' ;;
        *.[Ee][Rr][Ll]) command printf 'percent' ;;
        *.[Cc][Ll][Jj] | *.[Aa][Ss][Mm]) command printf 'semicolon' ;;
        *.[Bb][Aa][Tt]) command printf 'rem' ;;
        *.[Vv][Uu][Ee] | *.[Ss][Vv][Ee][Ll][Tt][Ee]) command printf 'html' ;;
        *.[Hh][Tt][Mm][Ll] | *.[Xx][Mm][Ll]) command printf 'html' ;;
        *.[Pp][Aa][Ss]) command printf 'brace' ;;
        # JSON has NO comment syntax at all — see comment_re's json arm.
        *.[Jj][Ss][Oo][Nn]) command printf 'json' ;;
        # EXTENSIONLESS FILES, dispatched by BASENAME — mirroring patterns.py's
        # BASENAME_LANG. An extension-keyed table cannot reach these at all, so
        # without them a Dockerfile loses every lexical-dependent detector.
        # Measured: `ENV PASSWORD="…"` fired on main and went silent here.
        # A `*/` prefix is required so the arm matches a full path, not just a
        # bare basename; both spellings reach this function.
        # The `.*` arms are the PREFIX family (patterns.py's PREFIX_LANG): the
        # suffix names a VARIANT of the same artifact by universal convention —
        # a `Dockerfile.prod` is a Dockerfile. Measured: `ENV PASSWORD="…"` in a
        # Dockerfile.prod fired on main and went silent without this.
        Dockerfile | */Dockerfile | Dockerfile.* | */Dockerfile.*) command printf 'hash' ;;
        Containerfile | */Containerfile | Containerfile.* | */Containerfile.*) command printf 'hash' ;;
        Makefile | */Makefile | Makefile.* | */Makefile.*) command printf 'hash' ;;
        makefile | */makefile | makefile.* | */makefile.*) command printf 'hash' ;;
        GNUmakefile | */GNUmakefile) command printf 'hash' ;;
        Jenkinsfile | */Jenkinsfile) command printf 'hash' ;;
        Vagrantfile | */Vagrantfile) command printf 'hash' ;;
        Procfile | */Procfile) command printf 'hash' ;;
        Rakefile | */Rakefile) command printf 'hash' ;;
        Gemfile | */Gemfile) command printf 'hash' ;;
        Brewfile | */Brewfile) command printf 'hash' ;;
        Justfile | */Justfile) command printf 'hash' ;;
        justfile | */justfile) command printf 'hash' ;;
        Caddyfile | */Caddyfile) command printf 'hash' ;;
        CMakeLists.txt | */CMakeLists.txt) command printf 'hash' ;;
        # DOTFILES — mirroring patterns.py's BASENAME_LANG / DOT_PREFIX_LANG.
        # A leading-dot name defeats extension keying in a subtler way than an
        # extensionless one: `.npmrc` yields ext `npmrc` and `.env.local` yields
        # `local`, so both resolve to a WRONG key rather than an empty one.
        # Measured: all three fired on main and went silent. `.netrc`/`.npmrc`
        # exist to hold credentials. All are `#`-comment formats.
        #
        # `.env.*` is a PREFIX arm on purpose: `.env.local` / `.env.production`
        # are env files by convention. (`.env.example` and friends are dropped
        # earlier by the SKIP_GLOBS block, which runs before this function.)
        .env | */.env | .env.* | */.env.*) command printf 'hash' ;;
        .npmrc | */.npmrc | .netrc | */.netrc) command printf 'hash' ;;
        .yarnrc | */.yarnrc | .pypirc | */.pypirc) command printf 'hash' ;;
        .dockerignore | */.dockerignore) command printf 'hash' ;;
        .gitconfig | */.gitconfig | .gitignore | */.gitignore) command printf 'hash' ;;
        .editorconfig | */.editorconfig) command printf 'hash' ;;
        .bashrc | */.bashrc | .zshrc | */.zshrc) command printf 'hash' ;;
        .profile | */.profile | .bash_profile | */.bash_profile) command printf 'hash' ;;
        .htaccess | */.htaccess | .mailmap | */.mailmap) command printf 'hash' ;;
        # SHEBANG — the fifth shape (#858), and the LAST resort. Mirrors
        # patterns.py's SHEBANG_LANG/_shebang_lang arm for arm.
        #
        # Every arm above keys on the NAME. An extensionless script whose
        # basename is not tabled (`run`, `deploy`, `entrypoint`, `bootstrap`)
        # reaches none of them, and the set of such names is UNBOUNDED — so no
        # longer table closes it and the file's own first line is the evidence.
        #
        # Guarded so an ordinary `app.py` never opens the file: this arm is
        # reached only when the BASENAME carried no extension. Cost is one
        # line-read, and lang_of runs once per file.
        #
        # The guard strips the directory first (`${1##*/}`) rather than testing
        # the whole path against `*.*`. A whole-path test would exclude every
        # file under a dotted directory -- `.github/deploy`,
        # `node_modules/.bin/tool` -- which is precisely the extensionless-script
        # case this shape exists to reach. patterns.py gates on its basename for
        # the same reason; two whole-path tests would AGREE, so parity would have
        # hidden the miss rather than caught it (#684).
        *)
            case "${1##*/}" in
                *.*) command printf '' ;;
                *) shebang_lang "$1" ;;
            esac
            ;;
    esac
}

# shebang_lang <file> — language key from the file's `#!` line, or empty.
#
# Reads with the `read` BUILTIN rather than `head -n 1`: the rest of lang_of is
# fork-free (#754) and this is the hot path's last resort. `read` returns
# non-zero on an unterminated final line, which a one-line file legitimately has,
# so its status is deliberately ignored -- the VALUE is what matters.
#
# BSD-clean: POSIX classes only, no \s/\w, no grep -P (#679). bash-3.2 clean:
# `case` rather than an associative array.
shebang_lang() {
    local first='' interp='' tok=''
    # BOUNDED read, matching patterns.py's `readline(_SHEBANG_MAX)` cap.
    #
    # `read` alone is NOT a bound: the builtin stops at a newline or EOF, so a
    # file with NO newline is slurped whole into the variable. Measured: a 20MB
    # newline-free file read 20,000,020 bytes into `first`. An extensionless
    # path is exactly where a committed binary blob turns up, and this is the
    # PRIMARY implementation on base macOS (bash 3.2, no usable python3), so the
    # bound has to be real rather than incidental. `head -c` caps the bytes and
    # `read` then takes the first line of that slice.
    #
    # 512 must match patterns.py's _SHEBANG_MAX; see the note there before
    # changing either (this cap counts BYTES, that one CHARACTERS).
    first=$(command head -c 512 "$1" 2>/dev/null | {
        IFS= read -r l || true
        command printf '%s' "$l"
    })
    case "$first" in
        '#!'*) ;;
        *)
            command printf ''
            return
            ;;
    esac
    # Strip the leading `#!` and tokenize on whitespace.
    first=${first#'#!'}
    # GLOBBING OFF around the split. `set -- $first` needs word-splitting, but
    # unquoted expansion also PATHNAME-expands, so a shebang containing `*` or
    # `?` would match files in the CURRENT DIRECTORY: `#!/usr/bin/env *sh` run
    # from a directory containing `zsh` resolves to `zsh` here while patterns.py
    # resolves nothing. Measured -- that spelling made the two runtimes disagree
    # by CWD, a divergence the parity gate would only catch if its fixture tree
    # happened to hold a matching name. `set -f` is restored immediately after
    # the split, since the rest of lang_of relies on `case` globbing.
    set -f
    # shellcheck disable=SC2086 # deliberate word-splitting: tokenize the line
    set -- $first
    set +f
    [ "$#" -gt 0 ] || {
        command printf ''
        return
    }
    interp=${1##*/}
    # `env` (and `env -S`) delegates -- the real interpreter is the next
    # non-option token.
    if [ "$interp" = "env" ]; then
        shift
        interp=''
        for tok in "$@"; do
            case "$tok" in
                -*) continue ;;
            esac
            interp=${tok##*/}
            break
        done
        [ -n "$interp" ] || {
            command printf ''
            return
        }
    fi
    # Strip a trailing CR so a CRLF-terminated shebang resolves. `read` splits on
    # IFS (space/tab/newline) and a lone `\r` is none of those, so a
    # `#!/usr/bin/env bash\r\n` line yields the token `bash\r`, matching no arm
    # below -- while patterns.py's text-mode readline() strips it and resolves
    # `sh`. Measured: python fired and bash stayed SILENT on the same file, a
    # security false negative on the bash runtime. Applied after both the
    # direct-path and env-delegated branches, since either can end the line.
    interp=${interp%"$(command printf '\r')"}
    # Strip a trailing version suffix: python3, python3.11, perl5, ruby2.7.
    while :; do
        case "$interp" in
            *[0-9] | *.) interp=${interp%?} ;;
            *) break ;;
        esac
    done
    # Values are EXISTING keys from the tables above -- this shape adds no new
    # language. zsh/fish/perl map to `hash` because that is where their
    # EXTENSIONS map, so a file resolves alike by name and by content.
    #
    # The sh-vs-hash distinction is currently UNOBSERVABLE through the TSV --
    # comment_re spells sh/hash/py/rb identically and injection-risk dispatches
    # on the extension -- so a mis-map here changes no row today. See the longer
    # note beside patterns.py's SHEBANG_LANG for why it is kept correct anyway.
    case "$interp" in
        sh | bash | dash | ksh) command printf 'sh' ;;
        zsh | fish | perl) command printf 'hash' ;;
        python) command printf 'py' ;;
        ruby) command printf 'rb' ;;
        node) command printf 'js' ;;
        *) command printf '' ;;
    esac
}

# comment_re <lang> — ERE matching a line that OPENS a comment in LANG, applied
# AFTER grep -n's "<lineno>:" prefix (hence the leading [0-9]+:). Anchored at
# line start: #837's defect was an unanchored substring test. POSIX classes only
# — BSD grep reads \s as a literal `s` (#679).
comment_re() {
    case "$1" in
        py | sh | rb | conf | hash) command printf '^[0-9]+:[[:space:]]*#' ;;
        js | ts | rs | go | java | swift | cfamily) command printf '^[0-9]+:[[:space:]]*(//|/\*|\*)' ;;
        dashdash) command printf '^[0-9]+:[[:space:]]*--' ;;
        quote) command printf "^[0-9]+:[[:space:]]*'" ;;
        percent) command printf '^[0-9]+:[[:space:]]*%%' ;;
        semicolon) command printf '^[0-9]+:[[:space:]]*;' ;;
        rem) command printf '^[0-9]+:[[:space:]]*([Rr][Ee][Mm][[:space:]]|::)' ;;
        html) command printf '^[0-9]+:[[:space:]]*(<!--|//|/\*|\*)' ;;
        brace) command printf '^[0-9]+:[[:space:]]*(\{|\(\*)' ;;
        # JSON has no comment syntax, so NO line opens a comment. This must be a
        # NEVER-MATCHING pattern, not an empty one: the consumers pipe through
        # `grep -vE "$file_comment_re"`, and an empty ERE matches EVERY line, so
        # `-v` would suppress the whole file — silently turning "no comments" into
        # "no findings". Every line here has come through `grep -n`, so it starts
        # with a digit; a `^Z`-anchored pattern therefore cannot match.
        json) command printf '^ZZ_JSON_HAS_NO_COMMENTS_ZZ' ;;
        *) command printf '' ;;
    esac
}

# XSS detection patterns — stored as variable to avoid hook false positives
# on the pattern strings themselves (this script DETECTS these, not uses them)
XSS_REACT_PATTERN='dangerously''SetInnerHTML'
XSS_VUE_PATTERN='v-html'
XSS_SAFE_PATTERN='\|safe\b|mark_safe\('
XSS_BLADE_PATTERN='{!!'

# --- OWASP detector patterns (#707) -----------------------------------------
# Fragment-concatenated for the same reason as the XSS_* patterns above: this
# scanner must not flag its own source. Not hypothetical — `.yml` is a modeled
# language here, and check-security/owasp-coverage.yml documents these very
# detectors in prose.
#
# NO GNU-ONLY REGEX (CLAUDE.md § runtime policy): BSD grep reads `\s`/`\w` as
# literals and has no `-P`, and that failure is SILENT — the pattern simply
# stops matching and the scan still exits 0. Hence [[:space:]] / [[:alnum:]_]
# throughout, and `-E` everywhere.
#
# The eval/exec arm cannot use the python impl's `(?<![\w.])` lookbehind, which
# POSIX ERE does not have. The portable equivalent CONSUMES a leading character
# — `(^|[^[:alnum:]_.])` — which is equivalent here because both impls report
# only the LINE, never the match offset, so the TSV stays identical.
CMD_SHELL_TRUE_PATTERN='subprocess\.[a-z_]+[[:space:]]*\([^)]*shell[[:space:]]*=[[:space:]]*''Tru''e'
CMD_OS_SYSTEM_PATTERN='(^|[^[:alnum:]_])os\.''syste''m[[:space:]]*\('
CMD_CHILD_EXEC_PATTERN='child_process\.''exe''c[[:space:]]*\('
CMD_EVAL_PATTERN='(^|[^[:alnum:]_.])(''eva''l|''exe''c)[[:space:]]*\([[:space:]]*[^"'\'')[:space:]][^)]*\)'

DESERIALIZE_PATTERN='(''pickl''e\.loads?[[:space:]]*\(|''yaml\.loa''d[[:space:]]*\(|''marshal\.loa''ds?[[:space:]]*\(|''Marshal\.loa''d[[:space:]]*\(|''readObjec''t[[:space:]]*\(|''unserializ''e[[:space:]]*\()'
DESERIALIZE_SAFE_PATTERN='(Loader[[:space:]]*=|safe_load)'

WEAK_RANDOM_FN_PATTERN='(Math\.random[[:space:]]*\(\)|random\.random[[:space:]]*\(\)|(^|[^[:alnum:]_.])rand[[:space:]]*\(\))'
WEAK_RANDOM_CTX_PATTERN='(token|nonce|salt|session|secret|password|(^|[^[:alnum:]_])key([^[:alnum:]_]|$)|iv([^[:alnum:]_]|$))'

TLS_DISABLED_PATTERN='(''verif''y[[:space:]]*=[[:space:]]*''Fals''e|''rejectUnauthorize''d[[:space:]]*:[[:space:]]*''fals''e|''InsecureSkipVerif''y[[:space:]]*:[[:space:]]*''tru''e|''NODE_TLS_REJECT_UNAUTHORIZE''D[[:space:]]*=[[:space:]]*.?0)'

CORS_PATTERN='(''Access-Control-Allow-Origi''n[[:space:]]*:?[[:space:]]*"?[[:space:]]*\*|''origi''n[[:space:]]*:[[:space:]]*''tru''e)'

JWT_PATTERN='(''al''g["'\'']?[[:space:]]*:[[:space:]]*["'\'']?''non''e|''jwt\.decod''e[[:space:]]*\([^)]*''verif''y[[:space:]]*=[[:space:]]*''Fals''e|''jwt\.decod''e[[:space:]]*\([^)]*''verif''y[[:space:]]*:[[:space:]]*''fals''e)'

XXE_PATTERN='(''resolve_entitie''s[[:space:]]*=[[:space:]]*''Tru''e|''libxml_disable_entity_loade''r[[:space:]]*\([[:space:]]*''fals''e|''XMLConstant''s)'

# emit_simple PATTERN CATEGORY LABEL — the single-pattern, comment-gated,
# one-message-per-match shape shared by six of the #707 arms. Defined once at
# top level (NOT inside the per-file loop, which would redefine it per file) and
# reads $file / $file_comment_re from the loop's scope, as the surrounding
# inline arms do. The two-stage arms (insecure-deserialization, weak-randomness,
# tls-verification-disabled) each need an extra filter and stay written out.
emit_simple() {
    command grep -nE "$1" "$file" 2>/dev/null |
        command grep -vE "$file_comment_re" |
        while IFS= read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "$2" "$3: ${evidence}" "HIGH"
        done || true
}

while IFS= read -r file; do
    [ -f "$file" ] || continue

    # Skip test fixtures, example env files, and lock files
    case "$file" in
        *test*fixture* | *testdata* | *.env.example | *.env.sample | *.env.template) continue ;;
        *lock.json | *lock.yaml | *.lock | *go.sum) continue ;;
    esac

    # Resolved ONCE PER FILE — the language is a property of the path, not of a
    # line. Empty means unmodeled, which gates every lexical-dependent detector
    # below (ADR 0002 § 1, the `—` state; silent per § 5).
    file_lang="$(lang_of "$file")"
    file_comment_re="$(comment_re "$file_lang")"

    # --- Category: hardcoded-secret ---
    # The four literal patterns below are LEXICAL-INDEPENDENT (ADR 0002 § 3) and
    # run on every file: a leaked AKIA key is interesting wherever it appears,
    # arguably MORE so inside a comment.

    # AWS access keys (AKIA followed by 16 uppercase alphanumeric chars)
    command grep -nE 'AKIA[0-9A-Z]{16}' "$file" 2>/dev/null |
        while IFS= read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "hardcoded-secret" \
                "AWS access key pattern: ${evidence}" "HIGH"
        done || true

    # GitHub tokens (ghp_, gho_, ghs_, ghr_, github_pat_)
    command grep -nE '(ghp_|gho_|ghs_|ghr_|github_pat_)[A-Za-z0-9_]{20,}' "$file" 2>/dev/null |
        while IFS= read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "hardcoded-secret" \
                "GitHub token pattern: ${evidence}" "HIGH"
        done || true

    # Stripe keys (sk_live_, rk_live_, pk_live_)
    command grep -nE '(sk_live_|rk_live_|pk_live_)[A-Za-z0-9]{20,}' "$file" 2>/dev/null |
        while IFS= read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "hardcoded-secret" \
                "Stripe live key pattern: ${evidence}" "HIGH"
        done || true

    # Private key headers
    command grep -nE 'BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY' "$file" 2>/dev/null |
        while IFS= read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "hardcoded-secret" \
                "Private key header: ${evidence}" "HIGH"
        done || true

    # Generic password/secret/token assignment with string literal values
    # (skip env var reads, placeholders, and comments). The quote delimiter class
    # is ["'] — a double- or single-quote. It is written ["'\''] so the single
    # quote is a real quote char: `'\''` closes the outer '-string, emits an
    # escaped ', and reopens. (Earlier this was `["\x27]`, but GNU grep does not
    # expand \x27 inside a bracket expression — it added literal \,x,2,7 to the
    # class, so any value containing x/2/7 was silently missed. Fixed in #168.)
    # LEXICAL-DEPENDENT (ADR 0002 § 3) — gated on the resolved language, and
    # skipped entirely for a file whose lexical model this scanner lacks.
    #
    # #837: the old denylist conflated two unrelated tests in ONE unanchored
    # substring match over the WHOLE line —
    #   (changeme|placeholder|...|#|//|/\*)
    # which failed in both directions:
    #   FALSE NEGATIVE  password = "Str0ng#Pass#Value"   (# inside the value)
    #   FALSE NEGATIVE  password = "realsecret123"  # noqa  (trailing comment)
    #   FALSE POSITIVE  -- password = "x"   in .lua/.sql (`--` not modeled)
    # A false-clean in a security scanner, so the two tests are now separate:
    #   1. the COMMENT test is line-start anchored and per-language (grep -vE
    #      "$file_comment_re", which already carries grep -n's "<lineno>:");
    #   2. the PLACEHOLDER test matches only the extracted VALUE, never the
    #      whole line, so a `#` outside the value can no longer suppress.
    #
    # #860: EVERY match on the line, not just the first. Two independent defects
    # were closed here; both emitted nothing in BOTH runtimes, so the TSV parity
    # gate stayed green on the shared limitation:
    #   1. FIRST-MATCH-ONLY — `| head -n 1` took one assignment, so a leading
    #      placeholder suppressed a real secret sharing the line.
    #   2. QUOTED KEYS NEVER MATCHED — the key had to be followed IMMEDIATELY by
    #      whitespace/=/:, so `{"api_key": "…"}` did not match at all. The
    #      `["']?` accepts the closing quote; this, not (1), is what silenced
    #      #860's headline JSON repro.
    # ONE ROW PER LINE (the TSV is keyed file/line/category), with the evidence
    # NAMING EVERY real secret — naming only the first would re-create this bug
    # in miniature, and the 80-char cap can truncate a later secret off the line.
    #
    # The key list is accumulated in a `while` fed by a HEREDOC, not by a pipe: a
    # piped `while` runs in a SUBSHELL and every key appended there would be
    # discarded at the loop's end.
    if [ -n "$file_lang" ]; then
        command grep -nEi '(password|passwd|secret|api_key|apikey|auth_token|access_token)["'\'']?[[:space:]]*[=:][[:space:]]*["'\''][^"'\'']{8,}["'\'']' "$file" 2>/dev/null |
            command grep -vE "$file_comment_re" |
            while IFS= read -r raw; do
                line_num=${raw%%:*}
                content=${raw#*:}
                # Walk every credential-shaped assignment on the line, peeling
                # each value's quotes with parameter expansion (bash-3.2 clean;
                # no sed, whose //I flag is GNU-only) and keeping the KEY of any
                # match whose VALUE is not a placeholder.
                cred_keys=""
                while IFS= read -r assign; do
                    [ -n "$assign" ] || continue
                    value=${assign#*[\"\']}
                    value=${value%[\"\']}
                    # The placeholder test is VALUE-scoped (#837), never the
                    # whole line, and applied PER MATCH so one placeholder
                    # cannot speak for its neighbours.
                    if command printf '%s' "$value" |
                        command grep -qiE '(changeme|placeholder|xxx|TODO|example|REPLACE|your_|test_|fake_|dummy_)'; then
                        continue
                    fi
                    cred_key=$(command printf '%s' "$assign" |
                        command grep -oEi '^[[:alpha:]_]+')
                    if [ -z "$cred_keys" ]; then
                        cred_keys="$cred_key"
                    else
                        cred_keys="${cred_keys}, ${cred_key}"
                    fi
                done <<EOF
$(command printf '%s' "$content" |
                    command grep -oEi '(password|passwd|secret|api_key|apikey|auth_token|access_token)["'\'']?[[:space:]]*[=:][[:space:]]*["'\''][^"'\'']{8,}["'\'']')
EOF
                [ -n "$cred_keys" ] || continue
                evidence=$(truncate_chars 80 "$content")
                command printf '%s\t%s\t%s\t%s\t%s\n' \
                    "$file" "$line_num" "hardcoded-secret" \
                    "Possible hardcoded credential (${cred_keys}): ${evidence}" "HIGH"
            done || true
    fi

    # --- Category: injection-risk ---

    # SQL injection: f-string or string concat with SQL keywords
    #
    # CASE-INSENSITIVE extension arms (#754), matching patterns.py's `.lower()`
    # before dispatch. A literal `case` here skipped `Db.PY` under bash while
    # python scanned it — and in a SECURITY scanner a silently unscanned file is
    # a false clean report, not a cosmetic gap. Bracket classes keep the match
    # fork-free and bash-3.2 clean (`${file,,}` is bash 4; macOS ships 3.2).
    case "$file" in
        *.[Pp][Yy])
            # f"..." or f'...' opening a SQL statement. Quote class ["'] written
            # as ["'\''] so the single quote is literal (see #168 — the old
            # ["\x27] never matched f'SELECT because \x27 is not expanded in a
            # bracket expression).
            command grep -nE 'f["'\''](SELECT|INSERT|UPDATE|DELETE|DROP)\b' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "injection-risk" \
                        "SQL in f-string: ${evidence}" "HIGH"
                done || true
            ;;
        *.[Jj][Ss] | *.[Tt][Ss] | *.[Jj][Ss][Xx] | *.[Tt][Ss][Xx])
            command grep -nE '`(SELECT|INSERT|UPDATE|DELETE|DROP)\b.*\$\{' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "injection-risk" \
                        "SQL in template literal: ${evidence}" "HIGH"
                done || true
            ;;
        *.[Rr][Bb])
            command grep -nE '"(SELECT|INSERT|UPDATE|DELETE|DROP)\b.*#\{' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "injection-risk" \
                        "SQL with string interpolation: ${evidence}" "HIGH"
                done || true
            ;;
        *.[Rr][Ss])
            # Rust builds SQL with format!-family interpolation ({} holes) or by
            # push_str onto a String — the idiomatic spelling of the same
            # unsanitized-concatenation defect the other arms catch (#838).
            #
            # TWO patterns, because the macros differ in ARGUMENT POSITION and a
            # single alternation cannot cover both: `format!` takes the format
            # string FIRST, while `write!`/`writeln!` take the `Write`
            # destination first and the format string SECOND. Folding them into
            # one `(format!|write!|writeln!)[[:space:]]*\([[:space:]]*"`
            # alternation makes the write!/writeln! branches dead — no valid
            # call has its format string in argument one.
            command grep -nE 'format![[:space:]]*\([[:space:]]*"(SELECT|INSERT|UPDATE|DELETE|DROP)\b.*\{' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "injection-risk" \
                        "SQL in format! interpolation: ${evidence}" "HIGH"
                done || true
            # The destination is skipped with `.*` rather than `[^,]+`: a
            # destination expression may itself contain a comma
            # (`write!(conn.buffer(a, b), "SELECT …", id)`), and a
            # comma-free-argument class stops at the FIRST comma, never reaching
            # the format string. Anchoring on the quoted SQL keyword is what
            # actually identifies the argument, so let `.*` reach it.
            command grep -nE '(write|writeln)![[:space:]]*\(.*,[[:space:]]*"(SELECT|INSERT|UPDATE|DELETE|DROP)\b.*\{' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "injection-risk" \
                        "SQL in write! interpolation: ${evidence}" "HIGH"
                done || true
            command grep -nE 'push_str[[:space:]]*\([[:space:]]*&?(format![[:space:]]*\([[:space:]]*)?"(SELECT|INSERT|UPDATE|DELETE|DROP)\b' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    evidence=$(truncate_chars 80 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "injection-risk" \
                        "SQL appended to String: ${evidence}" "HIGH"
                done || true
            ;;
    esac

    # String concatenation with SQL keywords. LEXICAL-DEPENDENT (ADR 0002 § 3) —
    # it reasons about string-literal form, so it is gated on the resolved
    # language and skipped on a comment line.
    if [ -n "$file_lang" ]; then
        command grep -nE '"(SELECT|INSERT|UPDATE|DELETE)\b.*"[[:space:]]*\+[[:space:]]*' "$file" 2>/dev/null |
            command grep -vE "$file_comment_re" |
            while IFS= read -r raw; do
                line_num=${raw%%:*}
                content=${raw#*:}
                evidence=$(truncate_chars 80 "$content")
                command printf '%s\t%s\t%s\t%s\t%s\n' \
                    "$file" "$line_num" "injection-risk" \
                    "SQL string concatenation: ${evidence}" "HIGH"
            done || true
    fi

    # --- Category: xss-risk ---

    # React: raw HTML rendering
    command grep -n "$XSS_REACT_PATTERN" "$file" 2>/dev/null |
        while IFS= read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "xss-risk" \
                "React raw HTML rendering: ${evidence}" "HIGH"
        done || true

    # Vue: v-html directive
    command grep -n "$XSS_VUE_PATTERN" "$file" 2>/dev/null |
        while IFS= read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "xss-risk" \
                "Vue raw HTML directive: ${evidence}" "HIGH"
        done || true

    # Django/Jinja: |safe filter, mark_safe()
    command grep -nE "$XSS_SAFE_PATTERN" "$file" 2>/dev/null |
        while IFS= read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "xss-risk" \
                "Template safe filter bypassing escaping: ${evidence}" "HIGH"
        done || true

    # Blade: unescaped output
    command grep -n "$XSS_BLADE_PATTERN" "$file" 2>/dev/null |
        while IFS= read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "xss-risk" \
                "Blade unescaped output: ${evidence}" "HIGH"
        done || true

    # --- Category: insecure-crypto ---

    # LEXICAL-DEPENDENT (ADR 0002 § 3). This detector always ATTEMPTED to consult
    # a comment model — the skip filter matches AFTER grep -n's "<lineno>:"
    # prefix, since anchoring at plain `^\s*#` never fired (#168) — but the model
    # was hardcoded C-family (`#|//|/\*|\*`) and applied to every file regardless
    # of language, so a `--` comment in .lua/.sql was scanned as code. It now
    # consults the language's own model and does not run on an unresolved one.
    if [ -n "$file_lang" ]; then
        # MD5/SHA1 used for security (skip comment lines).
        command grep -nEi '\b(md5|sha1)[[:space:]]*\(' "$file" 2>/dev/null |
            command grep -vE "$file_comment_re" |
            while IFS= read -r raw; do
                line_num=${raw%%:*}
                content=${raw#*:}
                evidence=$(truncate_chars 80 "$content")
                command printf '%s\t%s\t%s\t%s\t%s\n' \
                    "$file" "$line_num" "insecure-crypto" \
                    "Weak hash algorithm: ${evidence}" "HIGH"
            done || true

        # ECB mode encryption (skip comment lines).
        command grep -nEi '\bECB\b|MODE_ECB|mode.*ecb' "$file" 2>/dev/null |
            command grep -vE "$file_comment_re" |
            while IFS= read -r raw; do
                line_num=${raw%%:*}
                content=${raw#*:}
                evidence=$(truncate_chars 80 "$content")
                command printf '%s\t%s\t%s\t%s\t%s\n' \
                    "$file" "$line_num" "insecure-crypto" \
                    "ECB mode encryption: ${evidence}" "HIGH"
            done || true

        # --- OWASP detectors (#707) ---
        # All LEXICAL-DEPENDENT, inside this same `[ -n "$file_lang" ]` gate: a
        # commented-out `verify=False`, or a prose line describing pickle.loads,
        # is not a finding. That gating is also what stops the scanner flagging
        # its own documentation.

        # command-injection — four arms, each its own message.
        emit_simple "$CMD_SHELL_TRUE_PATTERN" "command-injection" \
            "Subprocess with shell=True"
        emit_simple "$CMD_OS_SYSTEM_PATTERN" "command-injection" \
            "Shell command execution"
        emit_simple "$CMD_CHILD_EXEC_PATTERN" "command-injection" \
            "Unsanitized child process exec"
        emit_simple "$CMD_EVAL_PATTERN" "command-injection" \
            "Dynamic evaluation of a non-literal"

        # insecure-deserialization — two-stage, mirroring the python impl: a
        # positive match that an explicit safe loader does NOT excuse, so
        # yaml.safe_load and `Loader=SafeLoader` both stay silent.
        command grep -nE "$DESERIALIZE_PATTERN" "$file" 2>/dev/null |
            command grep -vE "$file_comment_re" |
            command grep -vE "$DESERIALIZE_SAFE_PATTERN" |
            while IFS= read -r raw; do
                line_num=${raw%%:*}
                content=${raw#*:}
                evidence=$(truncate_chars 80 "$content")
                command printf '%s\t%s\t%s\t%s\t%s\n' \
                    "$file" "$line_num" "insecure-deserialization" \
                    "Unsafe deserialization of untrusted data: ${evidence}" "HIGH"
            done || true

        # weak-randomness — requires the security-context co-occurrence on the
        # same line; a non-CSPRNG picking UI jitter is not a finding.
        command grep -nE "$WEAK_RANDOM_FN_PATTERN" "$file" 2>/dev/null |
            command grep -vE "$file_comment_re" |
            command grep -iE "$WEAK_RANDOM_CTX_PATTERN" |
            while IFS= read -r raw; do
                line_num=${raw%%:*}
                content=${raw#*:}
                evidence=$(truncate_chars 80 "$content")
                command printf '%s\t%s\t%s\t%s\t%s\n' \
                    "$file" "$line_num" "weak-randomness" \
                    "Non-CSPRNG used for a security value: ${evidence}" "HIGH"
            done || true

        # tls-verification-disabled. The JWT exclusion matches the python impl:
        # `verify=False` on a jwt.decode line disables a SIGNATURE check, not a
        # TLS certificate check, and naming it TLS sends a reader to the wrong
        # fix. The jwt-unverified arm below still reports that line.
        command grep -nE "$TLS_DISABLED_PATTERN" "$file" 2>/dev/null |
            command grep -vE "$file_comment_re" |
            command grep -vE "$JWT_PATTERN" |
            while IFS= read -r raw; do
                line_num=${raw%%:*}
                content=${raw#*:}
                evidence=$(truncate_chars 80 "$content")
                command printf '%s\t%s\t%s\t%s\t%s\n' \
                    "$file" "$line_num" "tls-verification-disabled" \
                    "TLS certificate verification disabled: ${evidence}" "HIGH"
            done || true

        emit_simple "$CORS_PATTERN" "permissive-cors" "Permissive CORS policy"
        emit_simple "$JWT_PATTERN" "jwt-unverified" "JWT signature not verified"
        emit_simple "$XXE_PATTERN" "xxe-risk" \
            "XML parser with external entities enabled"
    fi

done <"$FILE_LIST"
