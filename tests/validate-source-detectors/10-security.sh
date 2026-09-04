# shellcheck shell=bash
# check-security detector fixtures — area fragment of validate-source-detectors
# (issue #859 split; gate introduced by #348).
#
# Covers hardcoded-secret, injection-risk, xss-risk, insecure-crypto, and the
# unreadable-file path. Each case drives a purpose-built fixture through BOTH
# impls (patterns.py primary, PATTERNS_FORCE_BASH=1 patterns.sh fallback) via the
# assert_fires / assert_silent drivers in tests/lib/source-detectors-sandbox.sh,
# asserting the SPECIFIC category emitted — and that a clean counter-fixture
# stays silent.
#
# Sourced, not executed. SK_SEC comes from the entry point.

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

# assert_row_count SKILLDIR LIST CAT N MSG — the category emits EXACTLY N rows in
# both impls. Distinct from assert_fires, which only proves at least one row
# contains a needle and so cannot catch a DOUBLE-fire. Lives in this fragment
# because no check-code-health case needs it (CLAUDE.md: the shared library must
# not accrete single-use code).
assert_row_count() {
    local skill="$1" list="$2" cat="$3" want="$4" msg="$5"
    local got
    got="$(emit_rows sh "$skill" "$list" "$cat" | command grep -c . || true)"
    assert_equals "$want" "$got" "$msg (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        got="$(emit_rows py "$skill" "$list" "$cat" | command grep -c . || true)"
        assert_equals "$want" "$got" "$msg (python)"
    fi
}

# ============================================================================
# check-security — OWASP detectors (#707)
# ============================================================================
# Every case is a PAIR: the unsafe spelling fires, and the safe spelling of the
# SAME operation stays silent. The negative half is what stops a detector from
# degenerating into "match the function name", which is the failure mode that
# makes a security scanner untrustworthy rather than merely noisy.
#
# Fixtures carry the REAL contiguous token (`verify=False`, `pickle.loads`),
# never an escaped form. A fixture written so it cannot self-match also cannot
# be matched by the detector, and would pass with AND without the fix.
test_security_command_injection() {
    local d list

    d="$(fresh_dir)"
    command printf '%s\n' 'subprocess.call(cmd, shell=True)' >"$d/a.py"
    list="$(make_list "$d/l" "$d/a.py")"
    assert_fires "$SK_SEC" "$list" command-injection "Subprocess with shell=True" \
        "security: subprocess shell=True fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'os.system("rm -rf " + target)' >"$d/b.py"
    list="$(make_list "$d/l" "$d/b.py")"
    assert_fires "$SK_SEC" "$list" command-injection "Shell command execution" \
        "security: os.system fires"

    # A DOTTED receiver still fires: python's `\bos\.` is satisfied by a
    # preceding dot, so `obj.os.system(...)` is a finding there. The bash port
    # first excluded a preceding dot and silently missed it. Found in review
    # cycle 1; this is the input on which the two boundary spellings diverge.
    d="$(fresh_dir)"
    command printf '%s\n' 'obj.os.system("x")' >"$d/dotted.py"
    list="$(make_list "$d/l" "$d/dotted.py")"
    assert_fires "$SK_SEC" "$list" command-injection "Shell command execution" \
        "security: a dotted receiver (obj.os.system) fires in both impls"

    d="$(fresh_dir)"
    command printf '%s\n' 'child_process.exec(userCmd);' >"$d/c.js"
    list="$(make_list "$d/l" "$d/c.js")"
    assert_fires "$SK_SEC" "$list" command-injection "Unsanitized child process exec" \
        "security: child_process.exec fires"

    # eval/exec of a NON-LITERAL is the defect...
    d="$(fresh_dir)"
    command printf '%s\n' 'v = eval(user_input)' >"$d/d.py"
    list="$(make_list "$d/l" "$d/d.py")"
    assert_fires "$SK_SEC" "$list" command-injection "Dynamic evaluation of a non-literal" \
        "security: eval of a non-literal fires"

    # ...while eval of a quoted literal is benign and must stay silent.
    d="$(fresh_dir)"
    command printf '%s\n' 'v = eval("1+1")' >"$d/e.py"
    list="$(make_list "$d/l" "$d/e.py")"
    assert_silent "$SK_SEC" "$list" command-injection \
        "security: eval of a string literal stays silent"

    # BOUNDARY: the eval/exec arm must not match the `exec` INSIDE
    # `child_process.exec(`, or that one line emits two findings. `\b` alone
    # does not exclude a preceding dot; the arm needs a boundary that refuses
    # one. Caught in development — this is the input that distinguishes them.
    d="$(fresh_dir)"
    command printf '%s\n' 'child_process.exec(userCmd);' >"$d/f.js"
    list="$(make_list "$d/l" "$d/f.js")"
    assert_row_count "$SK_SEC" "$list" command-injection 1 \
        "security: child_process.exec emits exactly one row, not two"

    # A commented-out dangerous call is not a finding (lexical-dependent).
    d="$(fresh_dir)"
    command printf '%s\n' '# subprocess.call(cmd, shell=True)' >"$d/g.py"
    list="$(make_list "$d/l" "$d/g.py")"
    assert_silent "$SK_SEC" "$list" command-injection \
        "security: a commented dangerous call stays silent"
}

test_security_deserialization() {
    local d list

    d="$(fresh_dir)"
    command printf '%s\n' 'data = pickle.loads(blob)' >"$d/a.py"
    list="$(make_list "$d/l" "$d/a.py")"
    assert_fires "$SK_SEC" "$list" insecure-deserialization "Unsafe deserialization" \
        "security: pickle.loads fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'cfg = yaml.load(stream)' >"$d/b.py"
    list="$(make_list "$d/l" "$d/b.py")"
    assert_fires "$SK_SEC" "$list" insecure-deserialization "Unsafe deserialization" \
        "security: bare yaml.load fires"

    # The two safe spellings of the SAME call. Both must stay silent, and they
    # exercise different halves of the exclusion (safe_load vs Loader=).
    d="$(fresh_dir)"
    command printf '%s\n' 'cfg = yaml.safe_load(stream)' >"$d/c.py"
    list="$(make_list "$d/l" "$d/c.py")"
    assert_silent "$SK_SEC" "$list" insecure-deserialization \
        "security: yaml.safe_load stays silent"

    d="$(fresh_dir)"
    command printf '%s\n' 'cfg = yaml.load(stream, Loader=yaml.SafeLoader)' >"$d/d.py"
    list="$(make_list "$d/l" "$d/d.py")"
    assert_silent "$SK_SEC" "$list" insecure-deserialization \
        "security: yaml.load with an explicit safe Loader stays silent"

    d="$(fresh_dir)"
    command printf '%s\n' '$obj = unserialize($input);' >"$d/e.php"
    list="$(make_list "$d/l" "$d/e.php")"
    assert_fires "$SK_SEC" "$list" insecure-deserialization "Unsafe deserialization" \
        "security: PHP unserialize fires"

    # The REMAINING alternation arms. thresholds.yml names each one as its own
    # severity-bearing arm (marshal_load, java_readobject, ...), so an untested
    # arm is an unpinned severity claim — and, as review cycle 1 showed for
    # key/iv and alg:none, an untested arm is exactly where a py/sh divergence
    # hides. One fixture per arm.
    d="$(fresh_dir)"
    command printf '%s\n' 'obj = Marshal.load(data)' >"$d/m.rb"
    list="$(make_list "$d/l" "$d/m.rb")"
    assert_fires "$SK_SEC" "$list" insecure-deserialization "Unsafe deserialization" \
        "security: Ruby Marshal.load fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'Object o = in.readObject();' >"$d/r.java"
    list="$(make_list "$d/l" "$d/r.java")"
    assert_fires "$SK_SEC" "$list" insecure-deserialization "Unsafe deserialization" \
        "security: Java readObject fires"
}

test_security_weak_randomness() {
    local d list

    # The security-context word is what makes it a finding...
    d="$(fresh_dir)"
    command printf '%s\n' 'tok = random.random() + salt' >"$d/a.py"
    list="$(make_list "$d/l" "$d/a.py")"
    assert_fires "$SK_SEC" "$list" weak-randomness "Non-CSPRNG" \
        "security: random.random() for a salt fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'const sessionKey = Math.random().toString(36);' >"$d/b.js"
    list="$(make_list "$d/l" "$d/b.js")"
    assert_fires "$SK_SEC" "$list" weak-randomness "Non-CSPRNG" \
        "security: Math.random() for a session key fires"

    # ...and without it, the same function is ordinary code. This negative is
    # the whole justification for the HIGH tier: an unguarded arm would fire on
    # every Math.random() in the tree.
    d="$(fresh_dir)"
    command printf '%s\n' 'const jitter = Math.random() * 100;' >"$d/c.js"
    list="$(make_list "$d/l" "$d/c.js")"
    assert_silent "$SK_SEC" "$list" weak-randomness \
        "security: Math.random() with no security context stays silent"

    # A CSPRNG is the fix, and must not be flagged for mentioning a token.
    d="$(fresh_dir)"
    command printf '%s\n' 'tok = secrets.token_hex(32)' >"$d/d.py"
    list="$(make_list "$d/l" "$d/d.py")"
    assert_silent "$SK_SEC" "$list" weak-randomness \
        "security: secrets.token_hex stays silent"

    # BOUNDARY (review cycle 1): the context words `key` and `iv` are bounded in
    # the python impl (\bkey\b, iv\b). The bash port first shipped them as bare
    # substrings, so `monkey`, `arrival` and `ivory` each fired a false
    # weak-randomness row in the FALLBACK ONLY — a py/sh divergence invisible to
    # a same-output parity check that never feeds it such a line. POSIX ERE has
    # no \b, so the portable spelling is the consuming class already used by
    # CMD_OS_SYSTEM_PATTERN in the same file.
    d="$(fresh_dir)"
    {
        command printf '%s\n' 'const jitter = Math.random() * 100; // monkey testing'
        command printf '%s\n' 'const arrival = Math.random();'
        command printf '%s\n' 'let ivoryColor = Math.random();'
    } >"$d/sub.js"
    list="$(make_list "$d/l" "$d/sub.js")"
    assert_silent "$SK_SEC" "$list" weak-randomness \
        "security: key/iv INSIDE another word (monkey/arrival/ivory) stays silent"

    # ...and the bounded words themselves still fire, so the boundary did not
    # simply disable the arm.
    d="$(fresh_dir)"
    command printf '%s\n' 'const iv = Math.random();' >"$d/iv.js"
    list="$(make_list "$d/l" "$d/iv.js")"
    assert_fires "$SK_SEC" "$list" weak-randomness "Non-CSPRNG" \
        "security: a standalone iv still fires (boundary did not kill the arm)"

    # THE BOUNDARY IS ASYMMETRIC, AND DELIBERATELY SO (review cycle 2). Python
    # spells it `iv\b` — TRAILING boundary only — so an initialization vector
    # named `cipher_iv` / `aes_iv` / `cipherIv` IS a security context, while
    # `ivory` (iv followed by `o`) is not. A symmetric class rejects both, which
    # is what the first pass at this fix shipped: it swapped a false POSITIVE
    # for a false NEGATIVE on the idiomatic `_iv` suffix, in the fallback only.
    # These fixtures pin the asymmetry so a later tidy-up cannot re-symmetrize
    # it. (`key` IS doubly bounded in python — `\bkey\b` — hence monkeyKey
    # below stays silent. The two words differ on purpose.)
    d="$(fresh_dir)"
    {
        command printf '%s\n' 'const cipher_iv = Math.random();'
        command printf '%s\n' 'const aes_iv = Math.random();'
        command printf '%s\n' 'const cipherIv = Math.random();'
    } >"$d/ivsuf.js"
    list="$(make_list "$d/l" "$d/ivsuf.js")"
    assert_row_count "$SK_SEC" "$list" weak-randomness 3 \
        "security: _iv/Iv-suffixed identifiers all fire (asymmetric trailing boundary)"

    d="$(fresh_dir)"
    command printf '%s\n' 'const monkeyKey = Math.random() * 100;' >"$d/mk.js"
    list="$(make_list "$d/l" "$d/mk.js")"
    assert_silent "$SK_SEC" "$list" weak-randomness \
        "security: key INSIDE a word (monkeyKey) stays silent — key is doubly bounded"

    # The third alternation arm, C-style rand(), previously unexercised.
    d="$(fresh_dir)"
    command printf '%s\n' 'const sessionToken = rand();' >"$d/c.js"
    list="$(make_list "$d/l" "$d/c.js")"
    assert_fires "$SK_SEC" "$list" weak-randomness "Non-CSPRNG" \
        "security: bare rand() with a security context fires"
}

test_security_tls_cors_jwt_xxe() {
    local d list

    d="$(fresh_dir)"
    command printf '%s\n' 'r = requests.get(url, verify=False)' >"$d/a.py"
    list="$(make_list "$d/l" "$d/a.py")"
    assert_fires "$SK_SEC" "$list" tls-verification-disabled "TLS certificate verification disabled" \
        "security: requests verify=False fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'const opts = {rejectUnauthorized: false};' >"$d/b.js"
    list="$(make_list "$d/l" "$d/b.js")"
    assert_fires "$SK_SEC" "$list" tls-verification-disabled "TLS certificate verification disabled" \
        "security: Node rejectUnauthorized:false fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'r = requests.get(url, verify=True)' >"$d/c.py"
    list="$(make_list "$d/l" "$d/c.py")"
    assert_silent "$SK_SEC" "$list" tls-verification-disabled \
        "security: verify=True stays silent"

    d="$(fresh_dir)"
    command printf '%s\n' 'res.header("Access-Control-Allow-Origin: *");' >"$d/d.js"
    list="$(make_list "$d/l" "$d/d.js")"
    assert_fires "$SK_SEC" "$list" permissive-cors "Permissive CORS policy" \
        "security: wildcard CORS origin fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'payload = jwt.decode(t, verify=False)' >"$d/e.py"
    list="$(make_list "$d/l" "$d/e.py")"
    assert_fires "$SK_SEC" "$list" jwt-unverified "JWT signature not verified" \
        "security: jwt.decode without verification fires"

    # DISAMBIGUATION: `verify=False` on a jwt.decode line is a SIGNATURE defect,
    # not a TLS one. Without the exclusion the line emitted two findings and the
    # TLS one named the wrong defect. Assert the TLS arm is silent here — the
    # jwt-unverified assertion above already pins that the line is still caught.
    d="$(fresh_dir)"
    command printf '%s\n' 'payload = jwt.decode(t, verify=False)' >"$d/f.py"
    list="$(make_list "$d/l" "$d/f.py")"
    assert_silent "$SK_SEC" "$list" tls-verification-disabled \
        "security: a JWT verify=False is not reported as a TLS finding"

    d="$(fresh_dir)"
    command printf '%s\n' 'payload = jwt.decode(t, key, algorithms=["RS256"])' >"$d/g.py"
    list="$(make_list "$d/l" "$d/g.py")"
    assert_silent "$SK_SEC" "$list" jwt-unverified \
        "security: a verified jwt.decode stays silent"

    # alg=none, the OTHER arm of jwt-unverified — and specifically the
    # SINGLE-QUOTED JS spelling. The bash port first accepted only a double
    # quote, so `{'alg': 'none'}` (idiomatic JS) was caught by python and MISSED
    # by the fallback: a false clean on the platform the fallback exists for,
    # on the highest-severity new detector. Found in review cycle 1.
    d="$(fresh_dir)"
    command printf '%s\n' "const header = {'alg': 'none'};" >"$d/algq.js"
    list="$(make_list "$d/l" "$d/algq.js")"
    assert_fires "$SK_SEC" "$list" jwt-unverified "JWT signature not verified" \
        "security: single-quoted alg:'none' fires (bash quote-class parity)"

    d="$(fresh_dir)"
    command printf '%s\n' 'const header = {"alg": "none"};' >"$d/algdq.js"
    list="$(make_list "$d/l" "$d/algdq.js")"
    assert_fires "$SK_SEC" "$list" jwt-unverified "JWT signature not verified" \
        "security: double-quoted alg:\"none\" fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'p = etree.XMLParser(resolve_entities=True)' >"$d/h.py"
    list="$(make_list "$d/l" "$d/h.py")"
    assert_fires "$SK_SEC" "$list" xxe-risk "XML parser with external entities enabled" \
        "security: XXE resolve_entities=True fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'p = etree.XMLParser(resolve_entities=False)' >"$d/i.py"
    list="$(make_list "$d/l" "$d/i.py")"
    assert_silent "$SK_SEC" "$list" xxe-risk \
        "security: resolve_entities=False stays silent"

    # The remaining TLS / CORS / XXE alternation arms — one fixture each, for
    # the reason given on the deserialization arms above.
    d="$(fresh_dir)"
    command printf '%s\n' 'cfg := &tls.Config{InsecureSkipVerify: true}' >"$d/g.go"
    list="$(make_list "$d/l" "$d/g.go")"
    assert_fires "$SK_SEC" "$list" tls-verification-disabled "TLS certificate verification disabled" \
        "security: Go InsecureSkipVerify fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'export NODE_TLS_REJECT_UNAUTHORIZED=0' >"$d/env.sh"
    list="$(make_list "$d/l" "$d/env.sh")"
    assert_fires "$SK_SEC" "$list" tls-verification-disabled "TLS certificate verification disabled" \
        "security: NODE_TLS_REJECT_UNAUTHORIZED=0 fires"

    # The reflected-origin CORS arm, which thresholds.yml rates HIGHER than the
    # wildcard arm (it trusts every caller WITH credentials).
    d="$(fresh_dir)"
    command printf '%s\n' 'app.use(cors({origin: true, credentials: true}));' >"$d/refl.js"
    list="$(make_list "$d/l" "$d/refl.js")"
    assert_fires "$SK_SEC" "$list" permissive-cors "Permissive CORS policy" \
        "security: reflected CORS origin:true fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'libxml_disable_entity_loader(false);' >"$d/x.php"
    list="$(make_list "$d/l" "$d/x.php")"
    assert_fires "$SK_SEC" "$list" xxe-risk "XML parser with external entities enabled" \
        "security: PHP libxml_disable_entity_loader(false) fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'f.setFeature(XMLConstants.FEATURE_SECURE_PROCESSING, false);' >"$d/x.java"
    list="$(make_list "$d/l" "$d/x.java")"
    assert_fires "$SK_SEC" "$list" xxe-risk "XML parser with external entities enabled" \
        "security: Java XMLConstants fires"
}
