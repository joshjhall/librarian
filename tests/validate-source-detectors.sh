#!/usr/bin/env bash
# check-security + check-code-health detector behavioral gate (issue #348).
#
# These two review-audit source-scanning pre-scans —
#
#   check-security      (hardcoded-secret / injection-risk / xss-risk / insecure-crypto)
#   check-code-health   (tech-debt-marker / debug-statement / empty-handler)
#
# — were among the lowest-coverage Python ports (check-code-health 68%,
# check-security 84%) because, like the check-docs-* family before #243, NEITHER
# had a dedicated behavioral gate: only tests/validate-python-ports.sh covered
# them, and it asserts bash==python PARITY over one shared fixture tree, which —
# as its own header notes — "cannot catch a regression where both impls break the
# same way." Whole per-language and per-category arms (the private-key header, the
# Stripe/React/Blade branches, the Go/Ruby/Java debug + empty-handler arms, the
# insecure-crypto comment-skip boundary, the is-test-file segment anchoring) never
# executed and had zero output-asserting coverage.
#
# This gate is the behavioral half of the #204 two-surface convention for the
# source family: it drives PURPOSE-BUILT fixtures through each scanner and asserts
# the SPECIFIC finding category each fixture must emit — AND that a clean
# counter-fixture stays silent — with emphasis on BOUNDARIES and NEGATIVE paths
# (the credential denylist skip, the crypto comment-only skip, the
# print()-with-logger negative, the debug-in-test-file suppression, the
# segment-anchored is-test-file that must NOT match contest.py). The sibling
# tests/coverage-python.sh corpus is extended in lockstep so the same branches
# execute under measurement; coverage rises because behavior is asserted, never
# the reverse.
#
# Each category is asserted against BOTH the Python primary (patterns.py) and the
# bash fallback (PATTERNS_FORCE_BASH=1 patterns.sh) — free parity reinforcement on
# top of validate-python-ports.sh's whole-corpus diff.
#
# Fault-injection verified (the #221 precedent): each boundary below was proven
# to catch a regression by transiently mutating the port and confirming this gate
# goes red, then reverting. The mutations checked, one per port:
#   check-security      — the insecure-crypto `not is_comment` guard forced true
#                         (so a commented md5() would wrongly fire) → the
#                         comment-skip silent assertion goes red.
#   check-code-health   — the debug-statement `if not test_file:` guard dropped
#                         (so a print() inside a test file would wrongly fire) →
#                         the test-file-suppression silent assertion goes red.
# Both went red under mutation and green on revert.
#
# Both ports read only file CONTENT (no git-rooting), so their CWD is irrelevant
# and every fixture runs from $WORKDIR.
#
# SKIPS (does not fail) when a python3>=3.11 is unavailable — the same posture as
# validate-python-ports.sh; the bash path is still asserted where present.
#
# Pure bash-3.2 + coreutils; full /usr/bin/* paths per project convention.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS_DIR="$REPO_ROOT/plugins/review-audit/skills"

REAL_BASH="$(command -v bash)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "check-security + check-code-health detector fixtures (#348)"

HAVE_PY=0
if command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    HAVE_PY=1
fi

WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

SK_SEC="$SKILLS_DIR/check-security"
SK_HEALTH="$SKILLS_DIR/check-code-health"

# --- Scanner drivers ---------------------------------------------------------
# emit_rows IMPL SKILLDIR LIST CAT [ENV...] — the rows one impl emits for a
# single category. IMPL is "py" or "sh"; extra args are VAR=VALUE env overrides.
emit_rows() {
    local impl="$1" skill="$2" list="$3" cat="$4"
    shift 4
    if [ "$impl" = py ]; then
        /usr/bin/env "$@" python3 "$skill/patterns.py" "$list" 2>/dev/null
    else
        /usr/bin/env PATTERNS_FORCE_BASH=1 "$@" "$REAL_BASH" "$skill/patterns.sh" "$list" 2>/dev/null
    fi | command awk -F '\t' -v c="$cat" '$3 == c'
}

# assert_fires SKILLDIR LIST CAT NEEDLE MSG [ENV...] — the category fires (rows
# contain NEEDLE) in BOTH impls. Python side skipped (not failed) when absent.
assert_fires() {
    local skill="$1" list="$2" cat="$3" needle="$4" msg="$5"
    shift 5
    assert_contains "$(emit_rows sh "$skill" "$list" "$cat" "$@")" \
        "$needle" "$msg (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_contains "$(emit_rows py "$skill" "$list" "$cat" "$@")" \
            "$needle" "$msg (python)"
    fi
}

# assert_silent SKILLDIR LIST CAT MSG [ENV...] — the category emits NOTHING in
# both impls.
assert_silent() {
    local skill="$1" list="$2" cat="$3" msg="$4"
    shift 4
    assert_output_empty "$(emit_rows sh "$skill" "$list" "$cat" "$@")" \
        "$msg (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_output_empty "$(emit_rows py "$skill" "$list" "$cat" "$@")" \
            "$msg (python)"
    fi
}

# fresh_dir — unique scratch dir per fixture so path resolution is clean.
fresh_dir() { command mktemp -d "$WORKDIR/case.XXXXXX"; }

# make_list OUTFILE PATH... — write a newline file list, echo its path.
make_list() {
    local out="$1"
    shift
    : >"$out"
    local p
    for p in "$@"; do
        command printf '%s\n' "$p" >>"$out"
    done
    command printf '%s' "$out"
}

# Fake secret tokens assembled from fragments so THIS gate file holds no
# contiguous secret for a scanner/gitleaks to flag; the fixtures on disk carry
# the full token. All are obvious fakes (sequential/repeated filler).
AKIA_TOK="AKIA""0123456789ABCDEF"
GHP_TOK="ghp_""ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
STRIPE_TOK="sk_""live_""ABCDEFGHIJKLMNOPQRSTUV"

# ============================================================================
# check-security — hardcoded-secret
# ============================================================================
test_security_secrets() {
    local d list

    # AWS access-key pattern.
    d="$(fresh_dir)"
    command printf 'aws = "%s"\n' "$AKIA_TOK" >"$d/aws.py"
    list="$(make_list "$d/l" "$d/aws.py")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "AWS access key pattern" \
        "security: AWS AKIA key fires"

    # GitHub token pattern.
    d="$(fresh_dir)"
    command printf 'gh = "%s"\n' "$GHP_TOK" >"$d/gh.py"
    list="$(make_list "$d/l" "$d/gh.py")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "GitHub token pattern" \
        "security: GitHub ghp_ token fires"

    # Stripe live-key pattern.
    d="$(fresh_dir)"
    command printf 'stripe = "%s"\n' "$STRIPE_TOK" >"$d/stripe.py"
    list="$(make_list "$d/l" "$d/stripe.py")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "Stripe live key pattern" \
        "security: Stripe sk_live_ key fires"

    # Private-key header (per-language-agnostic, all files).
    d="$(fresh_dir)"
    command printf '%s\n' "-----BEGIN RSA PRIVATE KEY-----" >"$d/id.pem"
    list="$(make_list "$d/l" "$d/id.pem")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "Private key header" \
        "security: PEM private-key header fires"

    # Generic credential assignment with a literal value fires...
    d="$(fresh_dir)"
    command printf '%s\n' 'password = "hunter2hunter2"' >"$d/cred.py"
    list="$(make_list "$d/l" "$d/cred.py")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "Possible hardcoded credential" \
        "security: generic credential assignment fires"

    # ...but the DENYLIST boundary keeps placeholder / env-read / comment silent.
    d="$(fresh_dir)"
    command printf '%s\n' \
        'password = "changeme_placeholder"' \
        'api_key = os.environ["API_KEY"]' \
        '# secret = "realvalue_but_comment"' >"$d/clean.py"
    list="$(make_list "$d/l" "$d/clean.py")"
    assert_silent "$SK_SEC" "$list" hardcoded-secret \
        "security: placeholder/env/comment credentials stay silent (denylist boundary)"

    # SKIP_GLOBS: a *.env.example carrying a real-looking secret is skipped whole.
    d="$(fresh_dir)"
    command printf 'stripe = "%s"\n' "$STRIPE_TOK" >"$d/secrets.env.example"
    list="$(make_list "$d/l" "$d/secrets.env.example")"
    assert_silent "$SK_SEC" "$list" hardcoded-secret \
        "security: a secret inside *.env.example is skipped (SKIP_GLOBS)"

    # #837: the denylist was an UNANCHORED SUBSTRING test over the whole line, so
    # a `#` ANYWHERE suppressed the finding — a false-clean in a security
    # scanner. Both spellings below emitted ZERO rows before #838 and fire now;
    # the negative above pins that the fix did not simply delete the denylist.
    d="$(fresh_dir)"
    command printf '%s\n' 'password = "Str0ng#Pass#Value"' >"$d/hash.py"
    list="$(make_list "$d/l" "$d/hash.py")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "Possible hardcoded credential" \
        "security: a # INSIDE the secret value no longer suppresses (#837)"

    d="$(fresh_dir)"
    command printf '%s\n' 'password = "realsecret123"  # noqa' >"$d/noqa.py"
    list="$(make_list "$d/l" "$d/noqa.py")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "Possible hardcoded credential" \
        "security: a trailing # comment no longer suppresses (#837)"

    # The placeholder test now matches the VALUE only, so a placeholder token in
    # a trailing comment must NOT suppress a real credential. This is the exact
    # input on which "match the value" and "match the line" diverge — without it
    # a value-anchored fix and a line-anchored one both pass.
    d="$(fresh_dir)"
    command printf '%s\n' 'password = "realsecret123"  # not a placeholder' >"$d/word.py"
    list="$(make_list "$d/l" "$d/word.py")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "Possible hardcoded credential" \
        "security: a placeholder word OUTSIDE the value does not suppress (#837)"

    # A language with no lexical model is not scanned by this lexical-dependent
    # detector at all (ADR 0002 § 1). `--` is a SQL comment the old hardcoded
    # C-family model never knew, so this fired as a false positive before #838.
    d="$(fresh_dir)"
    command printf '%s\n' '-- password = "supersecret1"' >"$d/q.sql"
    list="$(make_list "$d/l" "$d/q.sql")"
    assert_silent "$SK_SEC" "$list" hardcoded-secret \
        "security: an unmodeled language is not scanned for credentials"

    # CONFIG FORMATS keep their coverage through the gating. Caught in review:
    # scoping the lexical model to source languages alone would have silently
    # stopped scanning docker-compose.yml / application.properties / .env — the
    # file types where checked-in credentials most often live — and ADR § 5
    # makes that silence total. Verified against origin/main: both of these DID
    # fire before this change.
    d="$(fresh_dir)"
    command printf '%s\n' 'password: "realsecret123"' >"$d/compose.yml"
    list="$(make_list "$d/l" "$d/compose.yml")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "Possible hardcoded credential" \
        "security: a credential in .yml still fires after gating"

    d="$(fresh_dir)"
    command printf '%s\n' 'password = "realsecret123"' >"$d/app.ini"
    list="$(make_list "$d/l" "$d/app.ini")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "Possible hardcoded credential" \
        "security: a credential in .ini still fires after gating"

    # ...and the config comment model is `#`, applied in both directions.
    d="$(fresh_dir)"
    command printf '%s\n' '# password = "realsecret123"' >"$d/commented.ini"
    list="$(make_list "$d/l" "$d/commented.ini")"
    assert_silent "$SK_SEC" "$list" hardcoded-secret \
        "security: a # comment in .ini stays silent"

    # The remaining six config extensions share ONE dispatch arm with .yml/.ini,
    # so a fixture per extension is what stops a future edit from dropping or
    # misspelling one silently — the arm would still cover the two that are
    # tested. Caught in review.
    for _cfg_ext in yaml cfg conf toml properties env; do
        d="$(fresh_dir)"
        command printf '%s\n' 'password = "realsecret123"' >"$d/app.$_cfg_ext"
        list="$(make_list "$d/l" "$d/app.$_cfg_ext")"
        assert_fires "$SK_SEC" "$list" hardcoded-secret "Possible hardcoded credential" \
            "security: a credential in .$_cfg_ext fires (config arm covers all eight)"
    done
    unset _cfg_ext

    # MAINSTREAM C-FAMILY. Verified against origin/main: both of these fired
    # before this branch, so omitting them from the lexical model would have been
    # a silent coverage regression rather than a deliberate narrowing.
    d="$(fresh_dir)"
    command printf '%s\n' '$password = "realsecret123";' >"$d/conf.php"
    list="$(make_list "$d/l" "$d/conf.php")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "Possible hardcoded credential" \
        "security: a credential in .php still fires after gating"

    d="$(fresh_dir)"
    command printf '%s\n' 'MD5(buf);' >"$d/hash.c"
    list="$(make_list "$d/l" "$d/hash.c")"
    assert_fires "$SK_SEC" "$list" insecure-crypto "Weak hash algorithm" \
        "security: weak crypto in .c still fires after gating"

    d="$(fresh_dir)"
    command printf '%s\n' '// MD5(buf) in a comment' >"$d/comment.c"
    list="$(make_list "$d/l" "$d/comment.c")"
    assert_silent "$SK_SEC" "$list" insecure-crypto \
        "security: a // comment in .c stays silent"

    # EXTENSIONLESS FILES, dispatched by BASENAME. An extension-keyed table
    # cannot reach these at all, so without the basename fallback a Dockerfile
    # loses every lexical-dependent detector. Verified against origin/main: the
    # ENV line below fired there and went silent on this branch.
    #
    # This is the one that a 52-EXTENSION probe could not have found — an
    # extensionless file has no extension to probe, so the sweep that caught the
    # config/C-family/long-tail regressions was blind to it by construction.
    d="$(fresh_dir)"
    command printf '%s\n' 'ENV PASSWORD="realsecret123"' >"$d/Dockerfile"
    list="$(make_list "$d/l" "$d/Dockerfile")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "Possible hardcoded credential" \
        "security: a credential in an extensionless Dockerfile fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'PASSWORD = "realsecret123"' >"$d/Makefile"
    list="$(make_list "$d/l" "$d/Makefile")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "Possible hardcoded credential" \
        "security: a credential in an extensionless Makefile fires"

    # ...and the basename family's comment model is `#`, so a commented line
    # stays silent. Without this the arm could resolve the language and then
    # apply no model at all, which is the defect one layer down.
    d="$(fresh_dir)"
    command printf '%s\n' '# PASSWORD = "realsecret123"' >"$d/Dockerfile"
    list="$(make_list "$d/l" "$d/Dockerfile")"
    assert_silent "$SK_SEC" "$list" hardcoded-secret \
        "security: a # comment in a Dockerfile stays silent"

    # SUFFIXED VARIANTS. `Dockerfile.prod` has extension `prod` — a WRONG key
    # rather than an empty one, so it defeats extension dispatch the same way a
    # dotfile does. An earlier draft asserted this should stay SILENT, reasoning
    # that the suffix "names a different artifact"; that was wrong (a
    # Dockerfile.prod is a Dockerfile) and inconsistent with `.env.local`, which
    # the same commit matched by prefix for exactly the convention argument.
    # Measured: it fired on main. The assertion is inverted rather than deleted,
    # so the corrected rule is pinned rather than merely un-pinned.
    for _variant in Dockerfile.prod Dockerfile.dev Makefile.include; do
        d="$(fresh_dir)"
        command printf '%s\n' 'ENV PASSWORD="realsecret123"' >"$d/$_variant"
        list="$(make_list "$d/l" "$d/$_variant")"
        assert_fires "$SK_SEC" "$list" hardcoded-secret "Possible hardcoded credential" \
            "security: a credential in $_variant fires (suffix is a variant, not a new artifact)"
    done
    unset _variant

    # DOTFILES. A leading-dot name defeats extension keying in a SUBTLER way
    # than an extensionless one: it produces a WRONG key rather than an empty
    # one (`.npmrc` -> ext `npmrc`, `.env.local` -> ext `local`). Measured
    # against origin/main: all three of these fired there and went silent here.
    # `.netrc` and `.npmrc` exist to hold credentials.
    for _dot in .npmrc .netrc .env.local; do
        d="$(fresh_dir)"
        command printf '%s\n' 'password = "realsecret123"' >"$d/$_dot"
        list="$(make_list "$d/l" "$d/$_dot")"
        assert_fires "$SK_SEC" "$list" hardcoded-secret "Possible hardcoded credential" \
            "security: a credential in $_dot fires"
    done
    unset _dot

    # ...and their comment model is `#`.
    d="$(fresh_dir)"
    command printf '%s\n' '# password = "realsecret123"' >"$d/.npmrc"
    list="$(make_list "$d/l" "$d/.npmrc")"
    assert_silent "$SK_SEC" "$list" hardcoded-secret \
        "security: a # comment in .npmrc stays silent"

    # BOUNDARY: SKIP_GLOBS runs BEFORE the language resolver, so `.env.example`
    # stays skipped even though `.env.*` now resolves. Pinned because the new
    # prefix arm is exactly what could have re-enabled it.
    d="$(fresh_dir)"
    command printf '%s\n' 'password = "realsecret123"' >"$d/.env.example"
    list="$(make_list "$d/l" "$d/.env.example")"
    assert_silent "$SK_SEC" "$list" hardcoded-secret \
        "security: .env.example is still skipped (SKIP_GLOBS precedes the resolver)"

    # SHEBANG DISPATCH (#858). The fifth shape, and the only one not closable by
    # a longer table: the set of extensionless script names (`run`, `deploy`,
    # `entrypoint`, `bootstrap`) is unbounded, so the file's own `#!` line is the
    # evidence. Before this, every such script silently lost the two
    # lexical-dependent detectors — measured: both fired on main pre-gating.
    #
    # One fixture PER INTERPRETER FAMILY rather than one for the block. They
    # share a dispatch structure, so a fixture per family is what stops a future
    # edit from dropping or misspelling one arm while the tested siblings keep
    # this block green — the same argument the config-extension loop above makes.
    while read -r _name _bang; do
        [ -n "$_name" ] || continue
        d="$(fresh_dir)"
        command printf '#!%s\npassword = "realsecret123"\n' "$_bang" >"$d/$_name"
        list="$(make_list "$d/l" "$d/$_name")"
        assert_fires "$SK_SEC" "$list" hardcoded-secret "Possible hardcoded credential" \
            "security: a credential in an extensionless '#!$_bang' script fires"
    done <<'SHEBANGS'
deploy /usr/bin/env bash
run-sh /usr/bin/env sh
bootstrap /usr/bin/env dash
entrypoint /usr/bin/env zsh
pyscript /usr/bin/env python3
rbscript /usr/bin/env ruby
plscript /usr/bin/env perl
nodescript /usr/bin/env node
SHEBANGS
    unset _name _bang

    # The DIRECT-PATH spelling (`#!/bin/sh`) is a different resolver branch from
    # the `env` spelling above — there the interpreter is argv[0] itself rather
    # than the second token. The `lint-allow-path` marker is the #443 gate's own
    # documented exemption: this path is fixture DATA written into a scratch
    # file, never a tool this suite invokes.
    d="$(fresh_dir)"
    command printf '#!/bin/sh\npassword = "realsecret123"\n' >"$d/directsh" # lint-allow-path: shebang fixture data written to a scratch file, never executed
    list="$(make_list "$d/l" "$d/directsh")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "Possible hardcoded credential" \
        "security: a direct-path shebang (interpreter as argv0) resolves"

    # A VERSION SUFFIX is stripped, and `env -S` is unwrapped. Both are ordinary
    # spellings in the wild, and each is a distinct branch of the resolver.
    d="$(fresh_dir)"
    command printf '#!/usr/bin/env python3.11\npassword = "realsecret123"\n' >"$d/versioned"
    list="$(make_list "$d/l" "$d/versioned")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "Possible hardcoded credential" \
        "security: a versioned interpreter (python3.11) resolves"

    d="$(fresh_dir)"
    command printf '#!/usr/bin/env -S perl5 -w\npassword = "realsecret123"\n' >"$d/envdash"
    list="$(make_list "$d/l" "$d/envdash")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "Possible hardcoded credential" \
        "security: env -S with an option resolves the real interpreter"

    # ...and the RESOLVED language's comment model is applied — which is the half
    # that proves the shebang resolved to a real model rather than to some
    # default. Both directions: the `#` family and the `//` family, since a
    # shebang can select either.
    d="$(fresh_dir)"
    command printf '#!/usr/bin/env bash\n# password = "realsecret123"\n' >"$d/commented"
    list="$(make_list "$d/l" "$d/commented")"
    assert_silent "$SK_SEC" "$list" hardcoded-secret \
        "security: a # comment in a bash-shebang script stays silent"

    d="$(fresh_dir)"
    command printf '#!/usr/bin/env node\n// password = "realsecret123"\n' >"$d/nodecomment"
    list="$(make_list "$d/l" "$d/nodecomment")"
    assert_silent "$SK_SEC" "$list" hardcoded-secret \
        "security: a // comment in a node-shebang script stays silent"

    # ...and a FOREIGN marker under the same shebang must NOT suppress, or the
    # arm has degenerated into "suppress everything" — the same trap the
    # comment-family loop below guards against.
    d="$(fresh_dir)"
    command printf '#!/usr/bin/env bash\n// password = "realsecret123"\n' >"$d/foreignmark"
    list="$(make_list "$d/l" "$d/foreignmark")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "Possible hardcoded credential" \
        "security: // is NOT a comment in a bash-shebang script"

    # A GLOB-SHAPED interpreter must not pathname-expand. The bash half splits
    # the shebang line with an unquoted `$first`, which word-splits (wanted) AND
    # pathname-expands (not wanted) — so `#!/usr/bin/env *sh` evaluated from a
    # directory containing `zsh` resolved to zsh in bash while python resolved
    # nothing. A CWD-dependent parity divergence, and the shared fixture tree
    # would only expose it if it happened to hold a matching name. The fixture
    # runs FROM the directory holding the decoy, which is what arms the bug.
    # NOTE the cd is NOT wrapped in a subshell: assert_silent tallies into shell
    # variables, and a subshell discards them — the assertion then "passes" no
    # matter what. Measured: the first draft of this fixture survived removing
    # `set -f` from patterns.sh for exactly that reason. cd back explicitly.
    d="$(fresh_dir)"
    command touch "$d/zsh"
    command printf '#!/usr/bin/env *sh\npassword = "realsecret123"\n' >"$d/globbang"
    list="$(make_list "$d/l" "$d/globbang")"
    _prevpwd="$PWD"
    cd "$d" || return 1
    assert_silent "$SK_SEC" "$list" hardcoded-secret \
        "security: a glob-shaped interpreter does not pathname-expand"
    cd "$_prevpwd" || return 1
    unset _prevpwd

    # A CRLF-TERMINATED shebang resolves. `read` splits on IFS (space/tab/
    # newline) and a lone CR is none of those, so the token was `bash<CR>` and
    # matched no arm — while patterns.py's text-mode readline() strips it and
    # resolved fine. Measured: python FIRED and bash stayed SILENT on this exact
    # file, a security false negative on the runtime that is PRIMARY on base
    # macOS. Found by the pre-PR review, not by the original fixture set.
    # Both branches are covered: env-delegated and direct-path.
    d="$(fresh_dir)"
    command printf '#!/usr/bin/env bash\r\npassword = "realsecret123"\r\n' >"$d/crlfscript"
    list="$(make_list "$d/l" "$d/crlfscript")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "Possible hardcoded credential" \
        "security: a CRLF-terminated env shebang resolves"

    d="$(fresh_dir)"
    command printf '#!/bin/sh\r\npassword = "realsecret123"\r\n' >"$d/crlfdirect" # lint-allow-path: shebang fixture data written to a scratch file, never executed
    list="$(make_list "$d/l" "$d/crlfdirect")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "Possible hardcoded credential" \
        "security: a CRLF-terminated direct-path shebang resolves"

    # CRLF *combined with* a version suffix, which pins the ORDER of the two
    # strips. The CR strip runs BEFORE the version-suffix loop, so `python3<CR>`
    # must lose the CR first and the `3` second; reverse them and the CR blocks
    # the digit strip, leaving `python3<CR>` unmatched. Neither the un-versioned
    # CRLF fixtures above nor the LF-versioned one below can catch that reorder —
    # only the combination can.
    d="$(fresh_dir)"
    command printf '#!/usr/bin/env python3\r\npassword = "realsecret123"\n' >"$d/verscrlf"
    list="$(make_list "$d/l" "$d/verscrlf")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "Possible hardcoded credential" \
        "security: a CRLF shebang with a version suffix resolves (strip order)"

    # ...and a bare `#!` with ONLY a CR must still resolve to nothing rather than
    # to a CR-named interpreter.
    d="$(fresh_dir)"
    command printf '#!\r\npassword = "realsecret123"\n' >"$d/barecrlf"
    list="$(make_list "$d/l" "$d/barecrlf")"
    assert_silent "$SK_SEC" "$list" hardcoded-secret \
        "security: a bare #! with only a CR stays unresolved"

    # THE OTHER lexical-dependent detector. The issue names TWO detectors the
    # unresolved state silently loses — credential-assignment AND insecure-crypto
    # — and every fixture above asserts only the first, so the second was
    # restored but never pinned. Both directions, since the comment model is what
    # makes this detector gated at all.
    d="$(fresh_dir)"
    command printf '#!/usr/bin/env bash\ndigest = md5(payload)\n' >"$d/cryptoscript"
    list="$(make_list "$d/l" "$d/cryptoscript")"
    assert_fires "$SK_SEC" "$list" insecure-crypto "Weak hash algorithm" \
        "security: insecure-crypto is restored in a shebang-resolved script"

    d="$(fresh_dir)"
    command printf '#!/usr/bin/env bash\n# digest = md5(payload)\n' >"$d/cryptocomment"
    list="$(make_list "$d/l" "$d/cryptocomment")"
    assert_silent "$SK_SEC" "$list" insecure-crypto \
        "security: commented crypto in a shebang-resolved script stays silent"

    # THE 512-BYTE READ CAP, pinned at the boundary where it is OBSERVABLE.
    #
    # Both runtimes cap the shebang read (python `readline(_SHEBANG_MAX)`, bash
    # `head -c 512`) so a newline-free binary at an extensionless path is not
    # slurped whole — measured, an uncapped `read` pulled 20,000,020 bytes into
    # a shell variable.
    #
    # A large-blob fixture CANNOT pin that: an uncapped read yields the same
    # findings, just slower, so the assertion passes either way. Verified — the
    # first draft of this case was exactly that tautology and survived reverting
    # the cap. The observable input is instead a shebang whose RECOGNIZED
    # interpreter sits just PAST the cap: capped, both runtimes truncate it away
    # and stay silent; uncapped, bash resolves `bash` and fires while python
    # (still capped) does not — a parity break. That is what this pins.
    d="$(fresh_dir)"
    {
        command printf '#!/usr/bin/env -S'
        _i=0
        while [ "$_i" -lt 180 ]; do
            command printf ' -i'
            _i=$((_i + 1))
        done
        command printf ' bash\npassword = "realsecret123"\n'
    } >"$d/pastcap"
    unset _i
    list="$(make_list "$d/l" "$d/pastcap")"
    assert_silent "$SK_SEC" "$list" hardcoded-secret \
        "security: an interpreter past the 512-byte read cap does not resolve"

    # AN UNREADABLE extensionless file must not crash the resolver. Both halves
    # swallow the read failure (python `except OSError`, bash `2>/dev/null ||
    # true`) and fall through to the unresolved state; the existing
    # test_security_unreadable case covers an unreadable file with an EXTENSION,
    # which never reaches this arm. Skipped when running as root, where chmod 000
    # does not actually deny a read.
    if [ "$(id -u)" -ne 0 ]; then
        d="$(fresh_dir)"
        command printf '#!/usr/bin/env bash\npassword = "realsecret123"\n' >"$d/noread"
        command chmod 000 "$d/noread"
        list="$(make_list "$d/l" "$d/noread")"
        assert_silent "$SK_SEC" "$list" hardcoded-secret \
            "security: an unreadable extensionless file is skipped, not crashed"
        command chmod 644 "$d/noread"
    fi

    # THE NO-SHEBANG DECISION (#858 AC3), pinned rather than left as prose. An
    # extensionless file with no `#!` stays `—` deliberately: no tabled name and
    # no shebang is no evidence of a language, and defaulting to `sh` would apply
    # a `#` model to arbitrary data files — the language-blind false positive ADR
    # 0002 exists to remove. An UNRECOGNIZED interpreter resolves the same way.
    d="$(fresh_dir)"
    command printf '%s\n' 'password = "realsecret123"' >"$d/run"
    list="$(make_list "$d/l" "$d/run")"
    assert_silent "$SK_SEC" "$list" hardcoded-secret \
        "security: an extensionless file with NO shebang stays unresolved"

    d="$(fresh_dir)"
    command printf '#!/usr/bin/env cobol\npassword = "realsecret123"\n' >"$d/unknownbang"
    list="$(make_list "$d/l" "$d/unknownbang")"
    assert_silent "$SK_SEC" "$list" hardcoded-secret \
        "security: an unrecognized interpreter stays unresolved"

    # A bare `#!` with no interpreter at all must not crash or resolve.
    d="$(fresh_dir)"
    command printf '#!\npassword = "realsecret123"\n' >"$d/barebang"
    list="$(make_list "$d/l" "$d/barebang")"
    assert_silent "$SK_SEC" "$list" hardcoded-secret \
        "security: a bare #! with no interpreter stays unresolved"

    # The lexical-INDEPENDENT detectors still run on an unresolved file, so a
    # real leaked key fires there regardless. Without this the two assertions
    # above are consistent with the scanner having skipped the file ENTIRELY,
    # which is a different and much worse behavior than leaving it `—`.
    d="$(fresh_dir)"
    command printf 'aws = "%s"\n' "$AKIA_TOK" >"$d/nobang-key"
    list="$(make_list "$d/l" "$d/nobang-key")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "AWS access key pattern" \
        "security: a literal secret still fires in an unresolved extensionless file"

    # A DOTTED DIRECTORY must not defeat the read. `ext` is derived from the
    # whole path, so `.github/deploy` yields ext `github/deploy` — a non-empty
    # WRONG key. Gating the read on `not ext` would skip exactly the scripts this
    # shape exists to reach, and because BOTH runtimes would agree, the parity
    # gate could not have caught it (#684). Found by probe, not by review.
    d="$(fresh_dir)"
    command mkdir -p "$d/.github"
    command printf '#!/usr/bin/env bash\npassword = "realsecret123"\n' >"$d/.github/deploy"
    list="$(make_list "$d/l" "$d/.github/deploy")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "Possible hardcoded credential" \
        "security: a shebang script under a DOTTED directory still resolves"

    # A tabled BASENAME still wins over the shebang — the read is the last
    # resort, not the first. A Dockerfile whose first line is a bash shebang must
    # still resolve as a Dockerfile (both are `#`, so the observable is ORDER:
    # this passes only if shape 2 returned before the read).
    d="$(fresh_dir)"
    command printf '#!/usr/bin/env node\n# PASSWORD = "realsecret123"\n' >"$d/Dockerfile"
    list="$(make_list "$d/l" "$d/Dockerfile")"
    assert_silent "$SK_SEC" "$list" hardcoded-secret \
        "security: a tabled basename beats the shebang (order: name before content)"

    # THE COMMENT-FAMILY TABLE, both directions per family. Three review cycles
    # each found one more language group that had lost coverage to the gating
    # (config, then C-family, then this set) — instances of one structural
    # problem, so the table is now organised by MARKER and this loop tests the
    # property rather than the instances.
    #
    # Each row: an extension, ITS marker (must suppress), and a FOREIGN marker
    # (must NOT). The foreign half is what stops a family from degenerating into
    # "suppress everything", which would silently re-create the false-clean this
    # whole phase exists to remove.
    while read -r _ext _own _foreign; do
        [ -n "$_ext" ] || continue
        d="$(fresh_dir)"
        command printf '%s digest = md5(x)\n' "$_own" >"$d/own.$_ext"
        list="$(make_list "$d/l" "$d/own.$_ext")"
        assert_silent "$SK_SEC" "$list" insecure-crypto \
            "security: .$_ext own comment marker '$_own' suppresses"

        d="$(fresh_dir)"
        command printf '%s digest = md5(x)\n' "$_foreign" >"$d/foreign.$_ext"
        list="$(make_list "$d/l" "$d/foreign.$_ext")"
        assert_fires "$SK_SEC" "$list" insecure-crypto "Weak hash algorithm" \
            "security: .$_ext foreign marker '$_foreign' is NOT a comment"
    done <<'COMMENT_FAMILIES'
lua -- //
sql -- //
hs -- //
pl # //
tf # //
ps1 # //
erl % //
clj ; //
vb ' //
vue <!-- --
pas { --
dart // --
COMMENT_FAMILIES
    unset _ext _own _foreign

    # JSON has NO comment syntax, so its model must be a NEVER-matching pattern.
    # An EMPTY one would be catastrophic in the bash runtime specifically: the
    # consumers pipe through `grep -vE "$file_comment_re"`, an empty ERE matches
    # every line, and `-v` would then suppress the entire file — turning "this
    # language has no comments" into "this language has no findings". A .json
    # carrying a literal secret is the input that catches it.
    # The fixture must use a LEXICAL-DEPENDENT detector. A literal-secret row
    # (AWS/GitHub/Stripe) proves nothing here: those never consult the comment
    # model, so they keep firing even with the pattern broken — measured, the
    # first draft of this fixture passed under the mutation. insecure-crypto IS
    # gated, so it goes silent exactly when the model misbehaves.
    d="$(fresh_dir)"
    command printf '%s\n' '  "hash": "MD5(payload)"' >"$d/creds.json"
    list="$(make_list "$d/l" "$d/creds.json")"
    assert_fires "$SK_SEC" "$list" insecure-crypto "Weak hash algorithm" \
        "security: a gated .json finding fires (its no-comment model suppresses nothing)"
}

# ============================================================================
# check-security — injection-risk (per-language SQL)
# ============================================================================
test_security_injection() {
    local d list

    # Python f-string SQL.
    d="$(fresh_dir)"
    command printf '%s\n' 'q = f"SELECT * FROM t WHERE id={i}"' >"$d/q.py"
    list="$(make_list "$d/l" "$d/q.py")"
    assert_fires "$SK_SEC" "$list" injection-risk "SQL in f-string" \
        "security: Python SQL f-string fires"

    # JS/TS template-literal SQL.
    d="$(fresh_dir)"
    command printf '%s\n' 'const q = `SELECT * FROM t WHERE x=${v}`;' >"$d/q.ts"
    list="$(make_list "$d/l" "$d/q.ts")"
    assert_fires "$SK_SEC" "$list" injection-risk "SQL in template literal" \
        "security: JS/TS SQL template literal fires"

    # Ruby string-interpolation SQL.
    d="$(fresh_dir)"
    command printf '%s\n' 'sql = "SELECT * FROM t WHERE id=#{id}"' >"$d/q.rb"
    list="$(make_list "$d/l" "$d/q.rb")"
    assert_fires "$SK_SEC" "$list" injection-risk "SQL with string interpolation" \
        "security: Ruby SQL interpolation fires"

    # SQL string concatenation (all languages).
    d="$(fresh_dir)"
    command printf '%s\n' 'q = "SELECT a FROM t" + tail' >"$d/c.py"
    list="$(make_list "$d/l" "$d/c.py")"
    assert_fires "$SK_SEC" "$list" injection-risk "SQL string concatenation" \
        "security: SQL string concatenation fires"

    # A parameterized query is NOT an injection risk.
    d="$(fresh_dir)"
    command printf '%s\n' 'cur.execute("SELECT * FROM t WHERE id=%s", (i,))' >"$d/safe.py"
    list="$(make_list "$d/l" "$d/safe.py")"
    assert_silent "$SK_SEC" "$list" injection-risk \
        "security: a parameterized query stays silent"

    # Rust SQL idioms (#838). format!/write! interpolation and push_str onto a
    # String are how Rust spells the same unsanitized concatenation the arms
    # above catch. Both emitted zero rows before this phase — .rs reached no
    # injection-risk arm at all.
    d="$(fresh_dir)"
    command printf '%s\n' 'let q = format!("SELECT * FROM t WHERE id={}", id);' >"$d/q.rs"
    list="$(make_list "$d/l" "$d/q.rs")"
    assert_fires "$SK_SEC" "$list" injection-risk "SQL in format! interpolation" \
        "security: Rust format! SQL interpolation fires"

    # write!/writeln! take the Write DESTINATION first and the format string
    # SECOND, so they need their own pattern — folded into one alternation with
    # format! their branches are dead, because no valid call has its format
    # string in argument one. Caught in review; this fixture is the one input
    # that distinguishes the two spellings.
    d="$(fresh_dir)"
    command printf '%s\n' 'write!(f, "SELECT * FROM t WHERE id={}", id);' >"$d/w.rs"
    list="$(make_list "$d/l" "$d/w.rs")"
    assert_fires "$SK_SEC" "$list" injection-risk "SQL in write! interpolation" \
        "security: Rust write! SQL interpolation fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'writeln!(out, "INSERT INTO t VALUES ({})", v);' >"$d/wl.rs"
    list="$(make_list "$d/l" "$d/wl.rs")"
    assert_fires "$SK_SEC" "$list" injection-risk "SQL in write! interpolation" \
        "security: Rust writeln! SQL interpolation fires"

    # BOUNDARY: the destination expression may itself contain a comma. Skipping
    # it with a comma-free class (`[^,]+`) stops at the FIRST comma and never
    # reaches the format string — a silent false negative. Caught in review;
    # this is the input on which `[^,]+` and `.*` diverge.
    d="$(fresh_dir)"
    command printf '%s\n' 'write!(conn.buffer(a, b), "SELECT * FROM t WHERE id={}", id);' >"$d/wcomma.rs"
    list="$(make_list "$d/l" "$d/wcomma.rs")"
    assert_fires "$SK_SEC" "$list" injection-risk "SQL in write! interpolation" \
        "security: Rust write! with a comma in the destination still fires"

    # ...and a write! whose format string is not SQL stays silent, so the
    # widened `.*` did not turn the arm into a match-anything.
    d="$(fresh_dir)"
    command printf '%s\n' 'write!(f, "plain text {}", x);' >"$d/wplain.rs"
    list="$(make_list "$d/l" "$d/wplain.rs")"
    assert_silent "$SK_SEC" "$list" injection-risk \
        "security: a non-SQL write! stays silent"

    d="$(fresh_dir)"
    command printf '%s\n' 'q.push_str("SELECT * FROM t WHERE id=");' >"$d/p.rs"
    list="$(make_list "$d/l" "$d/p.rs")"
    assert_fires "$SK_SEC" "$list" injection-risk "SQL appended to String" \
        "security: Rust push_str SQL append fires"

    # A Rust parameterized query stays silent — the arm must key on the
    # interpolation hole, not merely on the SQL keyword.
    d="$(fresh_dir)"
    command printf '%s\n' 'let rows = client.query("SELECT * FROM t WHERE id=$1", &[&id]);' >"$d/safe.rs"
    list="$(make_list "$d/l" "$d/safe.rs")"
    assert_silent "$SK_SEC" "$list" injection-risk \
        "security: a Rust parameterized query stays silent"
}

# ============================================================================
# check-security — xss-risk (per-framework)
# ============================================================================
test_security_xss() {
    local d list
    # React dangerouslySetInnerHTML — fragmented so this gate is not self-flagged.
    local react="dangerously""SetInnerHTML"
    local vue="v-""html"
    local blade="{""!!"

    d="$(fresh_dir)"
    command printf '%s\n' "el.$react = {__html: raw};" >"$d/r.jsx"
    list="$(make_list "$d/l" "$d/r.jsx")"
    assert_fires "$SK_SEC" "$list" xss-risk "React raw HTML rendering" \
        "security: React dangerouslySetInnerHTML fires"

    d="$(fresh_dir)"
    command printf '%s\n' "<div $vue=\"userInput\"></div>" >"$d/v.html"
    list="$(make_list "$d/l" "$d/v.html")"
    assert_fires "$SK_SEC" "$list" xss-risk "Vue raw HTML directive" \
        "security: Vue v-html fires"

    d="$(fresh_dir)"
    command printf '%s\n' "{{ value|safe }}" >"$d/t.html"
    list="$(make_list "$d/l" "$d/t.html")"
    assert_fires "$SK_SEC" "$list" xss-risk "Template safe filter" \
        "security: Django/Jinja safe filter fires"

    d="$(fresh_dir)"
    command printf '%s\n' "$blade \$unescaped !!}" >"$d/b.blade.php"
    list="$(make_list "$d/l" "$d/b.blade.php")"
    assert_fires "$SK_SEC" "$list" xss-risk "Blade unescaped output" \
        "security: Blade {!! !!} fires"
}

# ============================================================================
# check-security — insecure-crypto (comment-skip boundary)
# ============================================================================
test_security_crypto() {
    local d list

    # md5()/sha1() and ECB fire on real code lines.
    d="$(fresh_dir)"
    command printf '%s\n' 'digest = md5(payload)' >"$d/h.py"
    list="$(make_list "$d/l" "$d/h.py")"
    assert_fires "$SK_SEC" "$list" insecure-crypto "Weak hash algorithm" \
        "security: md5() weak hash fires"

    d="$(fresh_dir)"
    command printf '%s\n' "cipher = OpenSSL::Cipher.new('AES-128-ECB')" >"$d/e.rb"
    list="$(make_list "$d/l" "$d/e.rb")"
    assert_fires "$SK_SEC" "$list" insecure-crypto "ECB mode encryption" \
        "security: ECB mode fires"

    # BOUNDARY: a comment line mentioning md5/ECB is skipped (is_comment).
    #
    # Each marker sits in a file of the language where it ACTUALLY opens a
    # comment (#838). This fixture used to put a `//` line in a `.py` file and
    # expect silence — which only held because the scanner applied ONE hardcoded
    # C-family model to every file. Under the per-language model of ADR 0002 § 3
    # `//` is not a Python comment, so that spelling now (correctly) fires and
    # the fixture had to be split rather than the detector loosened.
    d="$(fresh_dir)"
    command printf '%s\n' '# md5(commented) must be skipped' >"$d/c.py"
    list="$(make_list "$d/l" "$d/c.py")"
    assert_silent "$SK_SEC" "$list" insecure-crypto \
        "security: a # comment in .py stays silent (comment-skip boundary)"

    d="$(fresh_dir)"
    command printf '%s\n' '// ECB in a comment must be skipped' >"$d/c.rs"
    list="$(make_list "$d/l" "$d/c.rs")"
    assert_silent "$SK_SEC" "$list" insecure-crypto \
        "security: a // comment in .rs stays silent (comment-skip boundary)"

    # THE OTHER DIRECTION (#838/#837): `//` is NOT a comment in Python, so a line
    # that only LOOKED skippable under the old C-family model must now fire.
    # Without this the split above could be satisfied by a detector that skips
    # every marker in every language — the old bug, spelled differently.
    d="$(fresh_dir)"
    command printf '%s\n' '// ECB is not a Python comment' >"$d/n.py"
    list="$(make_list "$d/l" "$d/n.py")"
    assert_fires "$SK_SEC" "$list" insecure-crypto "ECB mode encryption" \
        "security: a // line in .py is NOT a comment and fires"

    # A language with NO lexical model in this scanner is not scanned by a
    # lexical-dependent detector at all (ADR 0002 § 1, the `—` state; silent per
    # § 5). `--` is a SQL comment the old hardcoded model never knew, so this
    # line was emitted as a false positive before #838.
    d="$(fresh_dir)"
    command printf '%s\n' '-- md5(x) in a SQL comment' >"$d/q.sql"
    list="$(make_list "$d/l" "$d/q.sql")"
    assert_silent "$SK_SEC" "$list" insecure-crypto \
        "security: an unmodeled language is not scanned for insecure-crypto"
}

# ============================================================================
# check-security — unreadable file (scan_file OSError arm)
# ============================================================================
test_security_unreadable() {
    local d list
    d="$(fresh_dir)"
    command printf 'gh = "%s"\n' "$GHP_TOK" >"$d/nope.py"
    command chmod 000 "$d/nope.py"
    list="$(make_list "$d/l" "$d/nope.py")"
    # An unreadable file yields no rows (the per-file open() OSError arm) rather
    # than crashing. Root can read 000 files, so only assert the non-root case.
    if [ "$(command id -u)" -ne 0 ]; then
        assert_silent "$SK_SEC" "$list" hardcoded-secret \
            "security: an unreadable file is skipped, not crashed"
    else
        skip_test "security unreadable-file arm (running as root can read 0000)"
    fi
    command chmod 644 "$d/nope.py" 2>/dev/null || true
}

# ============================================================================
# check-code-health — tech-debt-marker + debug-statement + empty-handler
# ============================================================================
test_health_debt() {
    local d list
    d="$(fresh_dir)"
    command printf '%s\n' 'x = 1  # TODO: refactor this' >"$d/a.py"
    list="$(make_list "$d/l" "$d/a.py")"
    assert_fires "$SK_HEALTH" "$list" tech-debt-marker "Tech debt marker" \
        "health: a TODO marker fires"
}

test_health_debug() {
    local d list

    # Python print() fires...
    d="$(fresh_dir)"
    command printf '%s\n' 'print("hi")' >"$d/p.py"
    list="$(make_list "$d/l" "$d/p.py")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debug print statement" \
        "health: Python print() fires"

    # ...but print() that is a logging call is NOT a debug statement (negative).
    d="$(fresh_dir)"
    command printf '%s\n' 'logger.print("structured")' >"$d/log.py"
    list="$(make_list "$d/l" "$d/log.py")"
    assert_silent "$SK_HEALTH" "$list" debug-statement \
        "health: a logger.print() line stays silent (logging negative)"

    # Python debugger statement.
    d="$(fresh_dir)"
    command printf '%s\n' 'breakpoint()' >"$d/bp.py"
    list="$(make_list "$d/l" "$d/bp.py")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debugger statement" \
        "health: Python breakpoint() fires"

    # JS console + debugger.
    d="$(fresh_dir)"
    command printf '%s\n' 'console.log("x");' >"$d/c.js"
    list="$(make_list "$d/l" "$d/c.js")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Console debug statement" \
        "health: JS console.log fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'debugger;' >"$d/d.js"
    list="$(make_list "$d/l" "$d/d.js")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debugger keyword" \
        "health: JS debugger keyword fires"

    # Ruby debugger.
    d="$(fresh_dir)"
    command printf '%s\n' 'binding.pry' >"$d/r.rb"
    list="$(make_list "$d/l" "$d/r.rb")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Ruby debugger" \
        "health: Ruby binding.pry fires"

    # Go debug print.
    d="$(fresh_dir)"
    command printf '%s\n' 'fmt.Println("x")' >"$d/g.go"
    list="$(make_list "$d/l" "$d/g.go")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debug print statement" \
        "health: Go fmt.Println fires"

    # Java debug print.
    d="$(fresh_dir)"
    command printf '%s\n' 'System.out.println("x");' >"$d/J.java"
    list="$(make_list "$d/l" "$d/J.java")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debug print statement" \
        "health: Java System.out.println fires"

    # Rust print macros (#838) — the stdout family, so `stdout_is_output` can
    # exempt them. Both spellings asserted independently: the arm is one regex
    # with an optional `e` prefix and an optional `ln` suffix, so a composite
    # fixture would stay green with either half broken.
    d="$(fresh_dir)"
    command printf '%s\n' 'println!("x");' >"$d/p.rs"
    list="$(make_list "$d/l" "$d/p.rs")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debug print statement" \
        "health: Rust println! fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'eprintln!("x");' >"$d/ep.rs"
    list="$(make_list "$d/l" "$d/ep.rs")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debug print statement" \
        "health: Rust eprintln! fires"

    # Rust dbg! — the DEBUGGER family, never exempted (#680 AC3). Its distinct
    # label is what pins that it landed in the right family: a dbg! misfiled
    # under the print family would still emit a debug-statement row, so only the
    # label distinguishes the two.
    d="$(fresh_dir)"
    command printf '%s\n' 'dbg!(value);' >"$d/dg.rs"
    list="$(make_list "$d/l" "$d/dg.rs")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Rust debug macro" \
        "health: Rust dbg! fires in the debugger family"

    # Swift print family (#839). Both spellings asserted independently — one
    # regex with an alternation, so a composite fixture stays green with either
    # half broken.
    d="$(fresh_dir)"
    command printf '%s\n' 'print("x")' >"$d/p.swift"
    list="$(make_list "$d/l" "$d/p.swift")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debug print statement" \
        "health: Swift print() fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'debugPrint(x)' >"$d/dp.swift"
    list="$(make_list "$d/l" "$d/dp.swift")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debug print statement" \
        "health: Swift debugPrint() fires"

    # BOUNDARY: Swift has NO debugger arm and that `—` cell is deliberate (a
    # breakpoint is an lldb/Xcode action, not a source token). Asserting the
    # ABSENCE needs a line that would fire if someone added a careless arm —
    # `breakpoint()` is a real Swift stdlib call AND the exact literal the
    # PYTHON debugger arm matches, so this pins that .swift does not leak into
    # it. Without a fixture the empty column is unfalsifiable.
    d="$(fresh_dir)"
    command printf '%s\n' 'breakpoint()' >"$d/bp.swift"
    list="$(make_list "$d/l" "$d/bp.swift")"
    assert_silent "$SK_HEALTH" "$list" debug-statement \
        "health: Swift breakpoint() does NOT fire (no debugger arm; py arm must not leak)"

    # BOUNDARY: a debug print inside a TEST file is suppressed (not test_file only
    # applies debug scanning to non-test files).
    d="$(fresh_dir)"
    command printf '%s\n' 'print("hi")' >"$d/test_mod.py"
    list="$(make_list "$d/l" "$d/test_mod.py")"
    assert_silent "$SK_HEALTH" "$list" debug-statement \
        "health: a print() inside a test file is suppressed (is_test_file boundary)"
}

test_health_empty_handler() {
    local d list

    # Python empty except (pass).
    d="$(fresh_dir)"
    command printf '%s\n' 'try:' '    risky()' 'except Exception:' '    pass' >"$d/e.py"
    list="$(make_list "$d/l" "$d/e.py")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Empty except block" \
        "health: Python empty except (pass) fires"

    # ...but an except with a real body stays silent.
    d="$(fresh_dir)"
    command printf '%s\n' 'try:' '    risky()' 'except Exception:' '    log(e)' >"$d/ok.py"
    list="$(make_list "$d/l" "$d/ok.py")"
    assert_silent "$SK_HEALTH" "$list" empty-handler \
        "health: a handled except stays silent"

    # JS empty catch.
    d="$(fresh_dir)"
    command printf '%s\n' 'try { risky(); } catch (e) {}' >"$d/c.js"
    list="$(make_list "$d/l" "$d/c.js")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Empty catch block" \
        "health: JS empty catch fires"

    # Ruby empty rescue.
    d="$(fresh_dir)"
    command printf '%s\n' 'begin' '  risky' 'rescue' 'end' >"$d/r.rb"
    list="$(make_list "$d/l" "$d/r.rb")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Empty rescue block" \
        "health: Ruby empty rescue fires"

    # Go swallowed error.
    d="$(fresh_dir)"
    command printf '%s\n' 'if err != nil {}' >"$d/g.go"
    list="$(make_list "$d/l" "$d/g.go")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Swallowed error" \
        "health: Go swallowed error fires"

    # Rust empty Err arm (#838), both body spellings asserted independently —
    # one regex with an alternation, so a composite fixture would stay green
    # with either half broken.
    d="$(fresh_dir)"
    command printf '%s\n' 'match r { Err(_) => {}, Ok(v) => use_it(v) }' >"$d/m.rs"
    list="$(make_list "$d/l" "$d/m.rs")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Empty Err match arm" \
        "health: Rust empty Err(_) => {} match arm fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'match r { Err(_) => (), Ok(v) => use_it(v) }' >"$d/u.rs"
    list="$(make_list "$d/l" "$d/u.rs")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Empty Err match arm" \
        "health: Rust empty Err(_) => () match arm fires"

    # BOUNDARY: a HANDLED Err arm stays silent.
    d="$(fresh_dir)"
    command printf '%s\n' 'match r { Err(e) => log(e), Ok(v) => use_it(v) }' >"$d/h.rs"
    list="$(make_list "$d/l" "$d/h.rs")"
    assert_silent "$SK_HEALTH" "$list" empty-handler \
        "health: Rust handled Err arm stays silent"

    # BOUNDARY: `let _ = fallible();` is NOT implemented (see the note in
    # patterns.py) — it is a deliberate idiom far more often than a swallow, and
    # this scanner has no certainty tier low enough to carry it. Pinned so that
    # adding it later is a conscious decision with this fixture to update, not an
    # accident.
    d="$(fresh_dir)"
    command printf '%s\n' 'let _ = write!(buf, "{}", x);' >"$d/k.rs"
    list="$(make_list "$d/l" "$d/k.rs")"
    assert_silent "$SK_HEALTH" "$list" empty-handler \
        "health: Rust let _ = discard is deliberately not flagged at HIGH"

    # Swift empty catch (#839) — the motivating false negative of #622. Swift's
    # `catch` takes NO parenthesized parameter, so the JS/Java arm above
    # (`catch\s*\([^)]*\)\s*\{\s*\}`) can NEVER match it; before this arm a
    # Swift `catch { }` emitted zero rows. Each of the three catch spellings is
    # asserted independently: they are one regex with an optional middle group,
    # so a composite fixture would stay green with the group broken.
    d="$(fresh_dir)"
    command printf '%s\n' 'do { try risky() } catch { }' >"$d/c.swift"
    list="$(make_list "$d/l" "$d/c.swift")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Empty catch block" \
        "health: Swift bare empty catch fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'do { try risky() } catch let e { }' >"$d/b.swift"
    list="$(make_list "$d/l" "$d/b.swift")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Empty catch block" \
        "health: Swift bound empty catch (catch let e) fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'do { try risky() } catch is FooError { }' >"$d/p.swift"
    list="$(make_list "$d/l" "$d/p.swift")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Empty catch block" \
        "health: Swift typed empty catch (catch is FooError) fires"

    # BOUNDARY: a Swift catch with a real body stays silent. This is what the
    # `[^{}]*` brace exclusion buys — without it the match runs past the
    # handler's opening brace and finds a later `{}` on the same line.
    d="$(fresh_dir)"
    command printf '%s\n' 'do { try risky() } catch { handle(error) }' >"$d/h.swift"
    list="$(make_list "$d/l" "$d/h.swift")"
    assert_silent "$SK_HEALTH" "$list" empty-handler \
        "health: Swift handled catch stays silent"

    # BOUNDARY: the same line plus a trailing empty closure. The handler is
    # non-empty, so this must STAY SILENT — it is the specific input that fires
    # if the brace exclusion is ever widened to `.*`, and neither fixture above
    # would notice that change.
    d="$(fresh_dir)"
    command printf '%s\n' 'do { try risky() } catch { handle() }; let noop = { }' >"$d/w.swift"
    list="$(make_list "$d/l" "$d/w.swift")"
    assert_silent "$SK_HEALTH" "$list" empty-handler \
        "health: Swift handled catch + later empty closure stays silent"

    # BOUNDARY: WORD BOUNDARY, BOTH SIDES. The python arm spells this
    # `\bcatch\b`; `\b` is a GNU extension BSD grep reads as a LITERAL, so the
    # bash arm must write both boundaries long-hand. Each side is asserted
    # separately because each was a real, separately-measured py/sh divergence —
    # and the leading-side fixture alone did NOT catch the trailing-side bug.
    #
    # An identifier ENDING in "catch" (leading boundary):
    d="$(fresh_dir)"
    command printf '%s\n' 'mycatch { }' >"$d/n.swift"
    list="$(make_list "$d/l" "$d/n.swift")"
    assert_silent "$SK_HEALTH" "$list" empty-handler \
        "health: Swift identifier ending in 'catch' is not a catch (leading boundary)"

    # An identifier STARTING with "catch" (trailing boundary). This direction
    # shipped UNTESTED behind the fixture above and was a live parity break:
    # bash fired on all three of these, python on none. Three spellings, since
    # the missing guard was on the character class rather than on any one name.
    d="$(fresh_dir)"
    command printf '%s\n' 'catches { }' >"$d/s.swift"
    list="$(make_list "$d/l" "$d/s.swift")"
    assert_silent "$SK_HEALTH" "$list" empty-handler \
        "health: Swift 'catches { }' is not a catch (trailing boundary)"

    d="$(fresh_dir)"
    command printf '%s\n' 'catcher { }' >"$d/r.swift"
    list="$(make_list "$d/l" "$d/r.swift")"
    assert_silent "$SK_HEALTH" "$list" empty-handler \
        "health: Swift 'catcher { }' is not a catch (trailing boundary)"

    d="$(fresh_dir)"
    command printf '%s\n' 'catchAllErrors { }' >"$d/a.swift"
    list="$(make_list "$d/l" "$d/a.swift")"
    assert_silent "$SK_HEALTH" "$list" empty-handler \
        "health: Swift 'catchAllErrors { }' is not a catch (trailing boundary)"

    # ...but the brace-adjacent form IS a catch and must still fire. This is the
    # case that fails if the trailing boundary is written as a CONSUMING
    # character class (ERE has no lookahead): the only thing following `catch`
    # here is the brace itself, so consuming it leaves nothing for `\{` to match
    # and the line goes silent in bash while python still fires. Found by
    # re-measuring after the first boundary fix rather than assuming it complete.
    d="$(fresh_dir)"
    command printf '%s\n' 'do { try risky() } catch{ }' >"$d/adj.swift"
    list="$(make_list "$d/l" "$d/adj.swift")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Empty catch block" \
        "health: Swift brace-adjacent 'catch{ }' still fires (boundary must not consume)"

    d="$(fresh_dir)"
    command printf '%s\n' 'do { try risky() } catch {}' >"$d/e2.swift"
    list="$(make_list "$d/l" "$d/e2.swift")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Empty catch block" \
        "health: Swift 'catch {}' (no inner space) fires"
}

test_health_test_file_and_skip() {
    local d list

    # is_test_file segment anchoring: tests/helper.py IS a test → debug suppressed.
    d="$(fresh_dir)"
    command mkdir -p "$d/tests"
    command printf '%s\n' 'print("dbg")' >"$d/tests/helper.py"
    list="$(make_list "$d/l" "$d/tests/helper.py")"
    assert_silent "$SK_HEALTH" "$list" debug-statement \
        "health: print() under a tests/ segment is suppressed"

    # ...but contest.py is NOT a test file (segment-anchored, not substring) → fires.
    d="$(fresh_dir)"
    command printf '%s\n' 'print("dbg")' >"$d/contest.py"
    list="$(make_list "$d/l" "$d/contest.py")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debug print statement" \
        "health: contest.py is NOT a test file (segment anchoring negative)"

    # test_*.py basename arm → test file.
    d="$(fresh_dir)"
    command printf '%s\n' 'print("dbg")' >"$d/test_widget.py"
    list="$(make_list "$d/l" "$d/test_widget.py")"
    assert_silent "$SK_HEALTH" "$list" debug-statement \
        "health: test_widget.py basename is a test file"

    # SKIP_GLOBS: a *.md carrying a TODO is skipped wholesale.
    d="$(fresh_dir)"
    command printf '%s\n' '# TODO: doc marker' >"$d/notes.md"
    list="$(make_list "$d/l" "$d/notes.md")"
    assert_silent "$SK_HEALTH" "$list" tech-debt-marker \
        "health: a TODO inside a *.md is skipped (SKIP_GLOBS)"
}

# ============================================================================
# check-code-health — declared `stdout_is_output` (#686)
# ============================================================================
#
# The declaration is read from `<repo-root>/.claude/pre-review.yml`, and the
# scanner finds that root with `git rev-parse --show-toplevel` at runtime. So
# these fixtures need a real git sandbox AND the scanner has to run FROM INSIDE
# it — the shared emit_rows driver does not cd, which would make every case here
# resolve THIS repo's config instead of the fixture's. Hence the local drivers.

# health_rows_in DIR IMPL LIST CAT — like emit_rows, but cd'd into DIR first.
# `command env`, not a hardcoded /usr/bin/env: CLAUDE.md bans absolute paths to
# core utilities (#443). The sibling emit_rows above predates that rule and still
# hardcodes one; new code should not add instances.
health_rows_in() {
    local dir="$1" impl="$2" list="$3" cat="$4"
    if [ "$impl" = py ]; then
        (cd "$dir" && command env python3 "$SK_HEALTH/patterns.py" "$list" 2>/dev/null)
    else
        (cd "$dir" && command env PATTERNS_FORCE_BASH=1 "$REAL_BASH" \
            "$SK_HEALTH/patterns.sh" "$list" 2>/dev/null)
    fi | command awk -F '\t' -v c="$cat" '$3 == c'
}

# assert_health_in DIR LIST CAT MODE NEEDLE MSG — assert in BOTH impls, from
# inside DIR. MODE is "fires" (rows contain NEEDLE) or "absent" (they do not).
# Both impls are checked because python is the PRIMARY runtime and bash the
# fallback: a fix landing in only one is the exact defect this pair invites.
assert_health_in() {
    local dir="$1" list="$2" cat="$3" mode="$4" needle="$5" msg="$6"
    local out
    out="$(health_rows_in "$dir" sh "$list" "$cat")"
    if [ "$mode" = fires ]; then
        assert_contains "$out" "$needle" "$msg (bash)"
    else
        assert_not_contains "$out" "$needle" "$msg (bash)"
    fi
    if [ "$HAVE_PY" -eq 1 ]; then
        out="$(health_rows_in "$dir" py "$list" "$cat")"
        if [ "$mode" = fires ]; then
            assert_contains "$out" "$needle" "$msg (python)"
        else
            assert_not_contains "$out" "$needle" "$msg (python)"
        fi
    fi
}

# stdout_sandbox VARNAME [CONFIG_LINE...] — a git sandbox holding a declared CLI
# file (cli.py: a print AND a breakpoint) plus an undeclared control
# (other.py: a print). Writes .claude/pre-review.yml only when CONFIG_LINEs are
# given, so the no-config case is the same fixture minus the declaration.
STDOUT_LIST=""
stdout_sandbox() {
    local __out="$1" dir=""
    shift
    dir="$(fresh_dir)"
    command git init -q "$dir" 2>/dev/null
    command mkdir -p "$dir/src"
    # cli.py carries BOTH families on purpose: the exemption must reach the
    # print and NOT the breakpoint, and one file proves both halves at once.
    command printf '%s\n' 'print("real output")' 'breakpoint()' >"$dir/src/cli.py"
    command printf '%s\n' 'print("debug leftover")' >"$dir/src/other.py"
    if [ "$#" -gt 0 ]; then
        command mkdir -p "$dir/.claude"
        command printf '%s\n' "$@" >"$dir/.claude/pre-review.yml"
    fi
    STDOUT_LIST="$(make_list "$dir/l" "$dir/src/cli.py" "$dir/src/other.py")"
    printf -v "$__out" '%s' "$dir"
}

# The bash dispatcher's SHAPE, mirroring the Python source-order assertion in
# validate-python-ports.sh (#687). Both are source-level for the same reason:
# every pattern in both families is `^\s*`-anchored, so no single line can match
# both, and no input exists for which the call order changes the emitted bytes.
# Behaviour cannot witness the order — only the source can.
#
# It also pins the exemption's SHAPE, which behaviour alone leaves ambiguous:
# the two calls must be SEPARATE statements. Written as one `if`, a declaration
# would suppress the debugger row too; written this way, no such control path
# exists. That is #680 AC3 enforced structurally rather than asserted in prose.
test_health_dispatch_order_and_shape() {
    local block
    # The dispatch block: from the debug-statement marker to the end of its `if`.
    block="$(command awk '/--- Category: debug-statement ---/,/^    fi$/' \
        "$SK_HEALTH/patterns.sh")"

    assert_not_empty "$block" "the bash debug-statement dispatch block was found"

    local print_ln dbg_ln
    print_ln="$(command printf '%s\n' "$block" | command grep -n 'scan_debug_prints "\$file"' | command head -1 | command cut -d: -f1)"
    dbg_ln="$(command printf '%s\n' "$block" | command grep -n 'scan_debugger_statements "\$file"' | command head -1 | command cut -d: -f1)"

    assert_not_empty "$print_ln" "the dispatcher calls scan_debug_prints"
    assert_not_empty "$dbg_ln" "the dispatcher calls scan_debugger_statements"
    assert_true "[ \"${print_ln:-0}\" -lt \"${dbg_ln:-0}\" ]" \
        "bash dispatch order is print-then-debugger, matching patterns.py (#686)"

    # The print call is guarded by the predicate; the debugger call is NOT.
    assert_contains "$block" 'matches_declared_stdout_pattern "$file" || scan_debug_prints "$file"' \
        "the print call is gated by the stdout declaration (#686)"
    assert_not_contains "$block" 'matches_declared_stdout_pattern "$file" || scan_debugger_statements' \
        "the debugger call is NOT gated by the declaration (#680 AC3)"
}

# The FAIL-CLOSED contract, forced (#686).
#
# patterns.py bounds each git call and treats a timeout like an OSError. Every
# other fixture here runs against a real, fast git, so the except-branch never
# executes — and "fails closed" was only a claim in a comment. This forces it
# with a stub `git` that sleeps well past _GIT_TIMEOUT_S.
#
# Three things must hold, and they are different failures:
#   - the scan COMPLETES (a hang would take the whole audit down),
#   - the declared file's print STILL fires — a call that could not answer must
#     not grant an exemption, or a broken git silently deletes findings,
#   - nothing is left in TMPDIR, covering the early-cleanup branch that runs
#     when git fails BEFORE atexit is registered.
#
# Python only: the bash twin deliberately has no bound (see its comment — the
# portable helper lives in another plugin), so there is no contract to test.
test_health_stdout_git_failure_fails_closed() {
    local d="" stub="" scratch="" out="" rc=0

    if [ "$HAVE_PY" -ne 1 ]; then
        skip_test "python3 unavailable (the bash fallback has no timeout to test)"
        return 0
    fi
    if ! command -v timeout >/dev/null 2>&1; then
        skip_test "timeout(1) unavailable to bound the TEST itself"
        return 0
    fi

    stdout_sandbox d "stdout_is_output:" "  - src/cli.py"

    # A git that never returns. PREPENDED to PATH so python3 itself still
    # resolves — replacing PATH outright would break the interpreter, not the
    # git call, and the case would pass for the wrong reason.
    stub="$(fresh_dir)"
    command printf '%s\n' '#!/usr/bin/env bash' 'sleep 60' >"$stub/git"
    command chmod +x "$stub/git"

    scratch="$(fresh_dir)"
    # Outer bound well above _GIT_TIMEOUT_S (5s) but far below the stub's 60s:
    # exit 124 here means the scanner did NOT honor its own timeout.
    # `timeout env ...`, not `timeout command env ...`: `command` is a shell
    # builtin, so timeout(1) would try to exec a binary named "command" and fail
    # before reaching python — the scan would emit nothing and the fail-closed
    # assertion would fail while the code was correct (which is what happened
    # writing this).
    out="$(cd "$d" && command timeout 30 env \
        PATH="$stub:$PATH" TMPDIR="$scratch" \
        python3 "$SK_HEALTH/patterns.py" "$STDOUT_LIST" 2>/dev/null)" || rc=$?

    assert_true "[ \"$rc\" -ne 124 ]" \
        "health: a hanging git does not wedge the scan — the timeout fires (#686)"
    assert_contains "$out" 'print("real output")' \
        "health: a git that cannot answer does NOT grant an exemption — fails CLOSED (#686)"
    assert_equals "" "$(command ls -A "$scratch" 2>/dev/null)" \
        "health: the early-failure path leaves no temp dir behind (#686)"

    # The case above hangs git for the WHOLE run, so _load_stdout_policy never
    # builds a match repo and the predicate returns at its empty-repo guard —
    # the timeout branch inside _matches_declared_stdout is never reached. That
    # makes the assertion above pass even with the branch flipped to fail OPEN
    # (verified by mutation), so it does not cover what its name suggests.
    #
    # This second stub lets the LOADER succeed and hangs only afterwards, by
    # counting invocations: rev-parse and init run for real, then check-ignore —
    # the third call, and the one made per file — hangs. Now the branch under
    # test is genuinely the one executing.
    local stub2="" scratch2="" out2="" rc2=0
    stub2="$(fresh_dir)"
    {
        command printf '%s\n' '#!/usr/bin/env bash'
        command printf '%s\n' 'n="$(cat "$COUNTER" 2>/dev/null || echo 0)"'
        command printf '%s\n' 'echo $((n + 1)) >"$COUNTER"'
        # Hang from the third call on — rev-parse and init are calls 1 and 2.
        command printf '%s\n' 'if [ "$n" -ge 2 ]; then sleep 60; fi'
        command printf '%s\n' 'exec "$REAL_GIT" "$@"'
    } >"$stub2/git"
    command chmod +x "$stub2/git"

    scratch2="$(fresh_dir)"
    out2="$(cd "$d" && command timeout 30 env \
        PATH="$stub2:$PATH" TMPDIR="$scratch2" \
        COUNTER="$stub2/n" REAL_GIT="$(command -v git)" \
        python3 "$SK_HEALTH/patterns.py" "$STDOUT_LIST" 2>/dev/null)" || rc2=$?

    assert_true "[ \"$rc2\" -ne 124 ]" \
        "health: a check-ignore that hangs does not wedge the scan (#686)"
    assert_contains "$out2" 'print("real output")' \
        "health: a TIMED-OUT check-ignore does not grant an exemption (#686)"
}

test_health_stdout_is_output() {
    local d=""

    # --- declared: the print is exempt ---
    # The needle is the print's EVIDENCE TEXT, not the filename: cli.py still
    # appears in this run via its breakpoint row (the next assertion), so
    # "cli.py is absent" could never hold and would fail whatever the code did.
    stdout_sandbox d "stdout_is_output:" "  - src/cli.py"
    assert_health_in "$d" "$STDOUT_LIST" debug-statement absent 'print("real output")' \
        "health: a declared file's print() is exempt (#686)"

    # --- AC3: the SAME declared file's breakpoint still fires ---
    # This is the boundary #680 AC3 asks for, and the reason the dispatcher uses
    # two statements rather than an if/else. Without this case, widening the
    # exemption to cover the debugger family would pass every other assertion.
    assert_health_in "$d" "$STDOUT_LIST" debug-statement fires "Debugger statement" \
        "health: a declared file's breakpoint() STILL fires (#680 AC3)"

    # --- control: an undeclared sibling in the same run is untouched ---
    # Proves the exemption is per-file, not a global off-switch. Keyed on the
    # control's own print evidence for the same reason as above.
    assert_health_in "$d" "$STDOUT_LIST" debug-statement fires 'print("debug leftover")' \
        "health: an UNDECLARED file's print() still fires (#686)"

    # --- no config at all: pre-#686 behaviour, exactly ---
    # The common path. If the predicate ever defaulted true, every repo without
    # a config would silently lose its print findings — so this is the case that
    # would catch it.
    local noconf=""
    stdout_sandbox noconf
    assert_health_in "$noconf" "$STDOUT_LIST" debug-statement fires 'print("real output")' \
        "health: with NO .claude/pre-review.yml, print() fires as before (#686)"

    # --- config present but key absent ---
    # A repo declaring some OTHER key must not accidentally enable the
    # exemption: the loader reads the file but finds no patterns.
    local otherkey=""
    stdout_sandbox otherkey "test_skip_patterns:" "  - vendor/**"
    assert_health_in "$otherkey" "$STDOUT_LIST" debug-statement fires 'print("real output")' \
        "health: a config without stdout_is_output leaves print() firing (#686)"

    # --- a GLOB, not just a literal path ---
    # SKILL.md documents these values as gitignore-style patterns and gives
    # `bin/*.js` as the worked example, but every case above declares an exact
    # path. Matching is delegated to `git check-ignore`, so a glob should work —
    # "should" being the point: a documented example nothing exercises is how
    # docs drift from behaviour.
    #
    # `src/*.py` matches BOTH fixture files, so this also shows the exemption
    # applying to a file never named literally.
    local globbed=""
    stdout_sandbox globbed "stdout_is_output:" "  - src/*.py"
    assert_health_in "$globbed" "$STDOUT_LIST" debug-statement absent 'print("real output")' \
        "health: a glob pattern exempts the file it matches (#686)"
    assert_health_in "$globbed" "$STDOUT_LIST" debug-statement absent 'print("debug leftover")' \
        "health: a glob exempts a file never named literally (#686)"
    # ...and the AC3 boundary holds under a glob too, not just a literal.
    assert_health_in "$globbed" "$STDOUT_LIST" debug-statement fires "Debugger statement" \
        "health: a glob-declared file's breakpoint() STILL fires (#680 AC3)"
}

# The temp match-repo must not leak. #680 added a repo to the reference impl
# without a cleanup branch and leaked one per run; the failure is silent (a
# stray /tmp dir, no error, no wrong output), so it needs a behavioural check
# rather than a code read.
#
# Each impl runs with TMPDIR pointed at a PRIVATE, EMPTY scratch dir, and the
# assertion is that the dir is empty afterwards. Two reasons that beats counting
# /tmp:
#
#   1. It is naming-agnostic. `mktemp -d` produces `tmp.XXXX` but Python's
#      `tempfile.mkdtemp()` produces `tmpXXXX` with NO dot, so a `tmp.*` glob
#      silently misses every Python leak — and Python is the PRIMARY runtime, so
#      the check would have covered only the fallback while claiming both.
#   2. Nothing else writes there, so a busy /tmp on the host cannot make it flap.
#
# Asserted per-impl rather than once at the end: a shared counter cannot say
# WHICH runtime leaked, and "one of the two leaked" is the report you least want
# at 2am.
test_health_stdout_repo_cleaned_up() {
    local d="" scratch=""

    stdout_sandbox d "stdout_is_output:" "  - src/cli.py"

    scratch="$(fresh_dir)"
    TMPDIR="$scratch" health_rows_in "$d" sh "$STDOUT_LIST" debug-statement >/dev/null
    assert_equals "" "$(command ls -A "$scratch" 2>/dev/null)" \
        "health: the bash impl leaves no temp match-repo behind (#686)"

    if [ "$HAVE_PY" -eq 1 ]; then
        scratch="$(fresh_dir)"
        TMPDIR="$scratch" health_rows_in "$d" py "$STDOUT_LIST" debug-statement >/dev/null
        assert_equals "" "$(command ls -A "$scratch" 2>/dev/null)" \
            "health: the python impl leaves no temp match-repo behind (#686)"
    fi
}

run_test test_security_secrets "check-security: AWS/GitHub/Stripe/PEM secrets + credential denylist + env.example skip"
run_test test_security_injection "check-security: py/js/rb SQL interpolation + concatenation + parameterized negative"
run_test test_security_xss "check-security: React/Vue/safe-filter/Blade XSS arms"
run_test test_security_crypto "check-security: md5/ECB fire, commented crypto skipped (comment boundary)"
run_test test_security_unreadable "check-security: an unreadable file is skipped, not crashed"
run_test test_health_debt "check-code-health: tech-debt marker"
run_test test_health_debug "check-code-health: py/js/rb/go/java/rs/swift debug arms + logger negative + test-file suppression"
run_test test_health_empty_handler "check-code-health: py/js/rb/go/rs/swift empty-handler arms + handled negative"
run_test test_health_test_file_and_skip "check-code-health: is_test_file segment anchoring + SKIP_GLOBS"
run_test test_health_dispatch_order_and_shape "check-code-health: bash dispatcher gates prints only, in print-then-debugger order (#686)"
run_test test_health_stdout_git_failure_fails_closed "check-code-health: a hanging git fails CLOSED and leaks nothing (#686)"
run_test test_health_stdout_is_output "check-code-health: stdout_is_output exempts prints only, keeps breakpoints (#686/#680 AC3)"
run_test test_health_stdout_repo_cleaned_up "check-code-health: the stdout match-repo is not leaked (#686)"

generate_report
