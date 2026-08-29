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
        *.[Ss][Cc][Aa][Ll][Aa]) command printf 'cfamily' ;;
        # JSON has NO comment syntax at all — see comment_re's json arm.
        *.[Jj][Ss][Oo][Nn]) command printf 'json' ;;
        *) command printf '' ;;
    esac
}

# comment_re <lang> — ERE matching a line that OPENS a comment in LANG, applied
# AFTER grep -n's "<lineno>:" prefix (hence the leading [0-9]+:). Anchored at
# line start: #837's defect was an unanchored substring test. POSIX classes only
# — BSD grep reads \s as a literal `s` (#679).
comment_re() {
    case "$1" in
        py | sh | rb | conf) command printf '^[0-9]+:[[:space:]]*#' ;;
        js | ts | rs | go | java | swift | cfamily) command printf '^[0-9]+:[[:space:]]*(//|/\*|\*)' ;;
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
    if [ -n "$file_lang" ]; then
        command grep -nEi '(password|passwd|secret|api_key|apikey|auth_token|access_token)[[:space:]]*[=:][[:space:]]*["'\''][^"'\'']{8,}["'\'']' "$file" 2>/dev/null |
            command grep -vE "$file_comment_re" |
            while IFS= read -r raw; do
                line_num=${raw%%:*}
                content=${raw#*:}
                # Extract just the credential value — the assignment fragment,
                # then peel the surrounding quotes with parameter expansion
                # (bash-3.2 clean; no sed, whose //I flag is GNU-only).
                assign=$(command printf '%s' "$content" |
                    command grep -oEi '(password|passwd|secret|api_key|apikey|auth_token|access_token)[[:space:]]*[=:][[:space:]]*["'\''][^"'\'']{8,}["'\'']' |
                    command head -n 1)
                value=${assign#*[\"\']}
                value=${value%[\"\']}
                if command printf '%s' "$value" |
                    command grep -qiE '(changeme|placeholder|xxx|TODO|example|REPLACE|your_|test_|fake_|dummy_)'; then
                    continue
                fi
                evidence=$(truncate_chars 80 "$content")
                command printf '%s\t%s\t%s\t%s\t%s\n' \
                    "$file" "$line_num" "hardcoded-secret" \
                    "Possible hardcoded credential: ${evidence}" "HIGH"
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
    fi

done <"$FILE_LIST"
