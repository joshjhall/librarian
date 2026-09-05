# shellcheck shell=bash
# check-security + check-code-health corpus — python coverage fixtures (issue #564 split).
#
# Builds the secret, injection, XSS and debug-marker fixtures across py/ts/go/html/rb (#348).
#
# Sourced by tests/coverage-python.sh, which creates WORKDIR and its EXIT trap
# BEFORE this file. This fragment only BUILDS FIXTURES and exports the path-list
# variables the driver section then feeds to each port under `coverage run`.
#
# NOTE: unlike the tests/ fragments, nothing here asserts — coverage-python.sh is
# a Codecov driver, not a test suite (it has zero run_test calls and is not wired
# into tests/run-all.sh). The behavioural gates for these same detectors live in
# tests/validate-{source,docs,loop,lifecycle,checker}-detectors.sh, and this
# corpus is kept in lockstep with them.

# The path-list / fixture-path variables below are the corpus's EXPORT surface:
# they are read by the driver loop in tests/coverage-python.sh, which sources
# this file. shellcheck analyses one file at a time and so cannot see those
# uses.
# shellcheck disable=SC2034  # consumed by the driver in tests/coverage-python.sh

# --- check-security + check-code-health corpus (#348) ------------------------
# check-security (84%) and check-code-health (68%) were the lowest-coverage
# non-docs ports because the generic corpus above never exercised their
# per-language / per-framework / boundary arms. These fixtures drive those
# branches under measurement, in lockstep with the behavioral assertions in
# tests/validate-source-detectors.sh (the #204 two-surface convention). Both
# ports are content-only (no git-rooting), so they run over SRC_LIST from
# WORKDIR. Boundary/negative arms (the credential denylist, the crypto
# comment-skip, the debug-in-test-file suppression, the is_test_file segment
# anchoring, the SKIP_GLOBS whole-file skip, the per-file OSError arm) are all
# represented so their lines execute; correctness is pinned by the gate.
SRCDIR="$FIXDIR/src"
mkdir -p "$SRCDIR/tests"

# Fake secret tokens, fragment-assembled so this SCRIPT holds no contiguous
# secret; the fixture on disk carries the full token.
SEC_AKIA="AKIA""0123456789ABCDEF"
SEC_GHP="ghp_""ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
SEC_STRIPE="sk_""live_""ABCDEFGHIJKLMNOPQRSTUV"
SEC_REACT="dangerously""SetInnerHTML"
SEC_VUE="v-""html"
SEC_BLADE="{""!!"

# Python source: secrets (all 4 header arms + generic credential), denylist
# negatives, f-string SQL + concatenation, md5 real vs commented, print() vs
# logger negative, breakpoint, empty except (pass) vs handled.
{
    printf 'aws = "%s"\n' "$SEC_AKIA"
    printf 'gh = "%s"\n' "$SEC_GHP"
    printf 'stripe = "%s"\n' "$SEC_STRIPE"
    printf '%s\n' '-----BEGIN RSA PRIVATE KEY-----'
    printf '%s\n' 'password = "hunter2hunter2"'
    printf '%s\n' 'placeholder = "changeme_placeholder"'
    # #860 multi-match arms: a placeholder no longer suppresses a real credential
    # sharing its line, and the key-enumerating evidence path runs for a line
    # carrying two real secrets.
    printf '%s\n' 'password = "changeme"; api_key = "realsecretvalue123"'
    printf '%s\n' 'api_key = "firstrealsecret1"; auth_token = "secondrealsecret2"'
    printf '%s\n' 'from_env = os.environ["API_KEY"]'
    printf '%s\n' 'q = f"SELECT * FROM t WHERE id={i}"'
    printf '%s\n' 'c = "SELECT a FROM t" + tail'
    printf '%s\n' 'digest = md5(payload)'
    printf '%s\n' '# md5(commented) is skipped by the comment guard'
    printf '%s\n' 'print("debug marker")'
    printf '%s\n' 'logger.print("structured")'
    printf '%s\n' 'breakpoint()'
    printf '%s\n' 'x = 1  # TODO: refactor'
    printf '%s\n' 'try:'
    printf '%s\n' '    risky()'
    printf '%s\n' 'except Exception:'
    printf '%s\n' '    pass'
    # OWASP arms (#707): each new detector's POSITIVE branch, plus the two
    # negative branches that are real code paths rather than mere non-matches —
    # the safe-loader exclusion and the eval-of-a-literal guard both execute
    # additional lines. Correctness is pinned by validate-source-detectors.sh;
    # these exist so the branches run under measurement (#204 two-surface).
    printf '%s\n' 'subprocess.call(cmd, shell=True)'
    printf '%s\n' 'os.system("rm -rf " + target)'
    printf '%s\n' 'data = pickle.loads(blob)'
    printf '%s\n' 'cfg = yaml.load(stream)'
    printf '%s\n' 'safe = yaml.safe_load(stream)'
    printf '%s\n' 'tok = random.random() + salt'
    printf '%s\n' 'good = secrets.token_hex(32)'
    printf '%s\n' 'r = requests.get(url, verify=False)'
    printf '%s\n' 'payload = jwt.decode(t, verify=False)'
    printf '%s\n' 'p = etree.XMLParser(resolve_entities=True)'
    printf '%s\n' 'v = eval(user_input)'
    printf '%s\n' 'lit = eval("1+1")'
} >"$SRCDIR/app.py"

# TS source: template-literal SQL, console/debugger, empty catch.
{
    printf '%s\n' 'const q = `SELECT * FROM t WHERE x=${v}`;'
    printf '%s\n' 'console.log("debug");'
    printf '%s\n' 'debugger;'
    printf '%s\n' 'try { risky(); } catch (e) {}'
    printf '%s\n' 'child_process.exec(userCmd);'
    printf '%s\n' 'const sessionKey = Math.random().toString(36);'
    printf '%s\n' 'const jitter = Math.random() * 100;'
    printf '%s\n' 'res.header("Access-Control-Allow-Origin: *");'
    printf '%s\n' 'const opts = {rejectUnauthorized: false};'
    # Remaining alternation arms (review cycle 1): each is its own
    # severity-bearing arm in thresholds.yml, so each needs to execute here.
    printf '%s\n' "const header = {'alg': 'none'};"
    printf '%s\n' 'app.use(cors({origin: true, credentials: true}));'
    printf '%s\n' 'const sessionToken = rand();'
    printf '%s\n' 'const jitter2 = Math.random() * 100; // monkey testing'
} >"$SRCDIR/app.ts"

# Ruby source: interpolation SQL, ECB, binding.pry, empty rescue.
{
    printf '%s\n' 'sql = "SELECT * FROM t WHERE id=#{id}"'
    printf '%s\n' "cipher = OpenSSL::Cipher.new('AES-128-ECB')"
    printf '%s\n' 'binding.pry'
    printf '%s\n' 'begin'
    printf '%s\n' '  risky'
    printf '%s\n' 'rescue'
    printf '%s\n' 'end'
} >"$SRCDIR/app.rb"

# Go source: fmt.Println debug (own line so the ^\s* anchor matches), swallowed
# error.
{
    printf '%s\n' 'package main'
    printf '%s\n' 'func F() {'
    printf '%s\n' '    fmt.Println("x")'
    printf '%s\n' '}'
    printf '%s\n' 'func G() { if err != nil {} }'
} >"$SRCDIR/app.go"

# Java source: System.out.println debug (own line), empty catch.
{
    printf '%s\n' 'class C {'
    printf '%s\n' '  void f() {'
    printf '%s\n' '    System.out.println("x");'
    printf '%s\n' '  }'
    printf '%s\n' '  void g() { try { risky(); } catch (E e) {} }'
    printf '%s\n' '}'
} >"$SRCDIR/App.java"

# HTML: Vue v-html + Django safe filter + Blade unescaped (xss arms).
{
    printf '%s\n' "<div $SEC_VUE=\"userInput\"></div>"
    printf '%s\n' "{{ value|safe }}"
    printf '%s\n' "$SEC_BLADE \$raw !!}"
} >"$SRCDIR/view.html"

# JSX: React dangerouslySetInnerHTML (xss arm).
printf '%s\n' "el.$SEC_REACT = {__html: raw};" >"$SRCDIR/comp.jsx"

# A test file: check-code-health must SUPPRESS debug statements here (is_test_file
# boundary) — the print() below must NOT be flagged as a debug statement, driving
# the `if not test_file:` false arm and the is_test_file segment/basename arms.
printf '%s\n' 'print("in a test file")' >"$SRCDIR/tests/test_helper.py"

# contest.py: NOT a test file (segment anchoring negative) — print() DOES fire,
# driving the is_test_file segment arms' non-matching path.
printf '%s\n' 'print("not a test")' >"$SRCDIR/contest.py"

# Top-level basename test-file arms (no tests/ segment): test_*.py drives the
# `fnmatch(base, "test_*.*")` arm; widget_test.py drives the `*_test.*` arm.
printf '%s\n' 'print("dbg")' >"$SRCDIR/test_widget.py"
printf '%s\n' 'print("dbg")' >"$SRCDIR/widget_test.py"

# An except block with NO following non-blank line drives the
# _first_nonblank_after empty-string return (the except is the last content).
{
    printf '%s\n' 'try:'
    printf '%s\n' '    risky()'
    printf '%s\n' 'except Exception:'
} >"$SRCDIR/trailing_except.py"

# SKIP_GLOBS: a *.env.example carrying a secret (check-security skip) and a *.md
# carrying a TODO (check-code-health skip) drive the whole-file skip arms.
printf 'stripe = "%s"\n' "$SEC_STRIPE" >"$SRCDIR/secrets.env.example"
printf '%s\n' '# TODO: doc marker' >"$SRCDIR/notes.md"

# A JSON config drives the #860 quoted-key arm: the credential regex must accept
# a closing quote on the key (`"api_key":`), which no other corpus file exercises
# — every source fixture above uses a BARE key. json is a modeled language whose
# comment pattern never matches, so the lexical gate lets the detector run.
printf '%s\n' '{"password": "changeme", "api_key": "realsecretvalue123"}' \
    >"$SRCDIR/config.json"

# An unreadable source file drives the per-file open() OSError arm in both ports.
SRC_UNREAD="$SRCDIR/unreadable.py"
printf 'gh = "%s"\n' "$SEC_GHP" >"$SRC_UNREAD"
chmod 000 "$SRC_UNREAD" 2>/dev/null || true

SRC_LIST="$WORKDIR/src-list.txt"
: >"$SRC_LIST"
for f in "$SRCDIR"/app.py "$SRCDIR"/app.ts "$SRCDIR"/app.rb "$SRCDIR"/app.go \
    "$SRCDIR"/App.java "$SRCDIR"/view.html "$SRCDIR"/comp.jsx \
    "$SRCDIR"/tests/test_helper.py "$SRCDIR"/contest.py \
    "$SRCDIR"/test_widget.py "$SRCDIR"/widget_test.py \
    "$SRCDIR"/trailing_except.py \
    "$SRCDIR"/config.json \
    "$SRCDIR"/secrets.env.example "$SRCDIR"/notes.md "$SRC_UNREAD"; do
    printf '%s\n' "$f" >>"$SRC_LIST"
done
# A blank line drives the main() empty-path `if not path: continue` arm.
printf '\n' >>"$SRC_LIST"

# A file-list PATH that itself does not exist drives the main()
# file-list-not-found (OSError) arm — the list file is absent, not its contents.
SRC_NOFILE_LIST="$WORKDIR/src-nonexistent-list-XYZ.txt"
