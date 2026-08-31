# shellcheck shell=bash
# check-lifecycle corpus — python coverage fixtures (issue #564 split).
#
# Builds unreaped subprocesses, terminate-without-kill, unclosed handles and unpaired listeners (#435).
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

# --- check-lifecycle corpus (#435) ------------------------------------------
# The lifecycle port's per-language arms (swift/py/js/go subprocess-spawn,
# terminate, unclosed-handle, unpaired-listener) never execute under the generic
# corpus. These fixtures drive those branches under measurement, in lockstep with
# the behavioral assertions in tests/validate-lifecycle-detectors.sh (the #204
# two-surface convention). The port is content-only (no git-rooting), so it runs
# over LIFE_LIST from WORKDIR. Boundary/negative arms (the wholesale test-file
# skip, the SKIP_GLOBS whole-file skip, the per-file OSError, the empty-token
# skip) are all represented so their lines execute; correctness is pinned by the
# gate.
LIFEDIR="$FIXDIR/lifecycle"
mkdir -p "$LIFEDIR/tests"

# Swift: Process() spawn, .terminate(), FileHandle() handle, addObserver +
# scheduledTimer listeners.
{
    printf '%s\n' 'let task = Process()'
    printf '%s\n' 'task.terminate()'
    printf '%s\n' 'let fh = FileHandle(forReadingAtPath: p)'
    printf '%s\n' 'NotificationCenter.default.addObserver(self, selector: s)'
    printf '%s\n' 'let t = Timer.scheduledTimer(withTimeInterval: 1)'
} >"$LIFEDIR/capture.swift"

# Python: subprocess.Popen + bare Popen, .terminate(), assignment open() (fires),
# scoped with-open (silent boundary), plus a >80-char multibyte open() line so
# emit()'s EVIDENCE_CAP truncation + the bash char-vs-byte slice (#17) execute.
{
    printf '%s\n' 'proc = subprocess.Popen(["ls"])'
    printf '%s\n' 'p2 = Popen(cmd)'
    printf '%s\n' 'proc.terminate()'
    printf '%s\n' 'f = open("x.txt")'
    printf '%s\n' 'with open("y.txt") as g:'
    printf '%s\n' '    pass'
    printf 'h = open("%s")\n' "$(printf '%0.s—' $(seq 1 60))"
} >"$LIFEDIR/runner.py"

# JS/TS: spawn/execFile, .terminate(), fs.openSync handle, addEventListener +
# setInterval + .on listeners.
{
    printf '%s\n' 'const child = spawn("ls", args)'
    printf '%s\n' 'const r = execFile("cat", [f])'
    printf '%s\n' 'const e = exec("ls -la", cb)'
    printf '%s\n' 'child.terminate()'
    printf '%s\n' 'const s = fs.openSync(path, "r")'
    printf '%s\n' 'el.addEventListener("click", h)'
    printf '%s\n' 'const iv = setInterval(tick, 1000)'
    printf '%s\n' 'emitter.on("data", cb)'
} >"$LIFEDIR/worker.js"

# Go: exec.Command spawn, os.Interrupt, os.Open + os.Create handles.
{
    printf '%s\n' 'package main'
    printf '%s\n' 'cmd := exec.Command("ls")'
    printf '%s\n' 'signal.Notify(c, os.Interrupt)'
    printf '%s\n' 'f, err := os.Open("x.txt")'
    printf '%s\n' 'g, err := os.Create("y.txt")'
} >"$LIFEDIR/proc.go"

# A test file: check-lifecycle must SUPPRESS the whole file (wholesale skip) —
# the Process() below must NOT fire, driving the is_test_file early return.
printf '%s\n' 'let task = Process()' >"$LIFEDIR/tests/helper.swift"

# contest.swift: NOT a test file (segment anchoring negative) — Process() DOES
# fire, driving the is_test_file segment arms' non-matching path.
printf '%s\n' 'let task = Process()' >"$LIFEDIR/contest.swift"

# A test_*-named DIRECTORY holding real source (#836): the name arms are matched
# against the BASENAME, so `production.py` does NOT match and the file IS
# scanned. Drives the basename-slice branch of is_test_file with a path whose
# DIRECTORY would match were the arm path-crossing — the input the whole-repo
# differential gate cannot supply, since this repo contains no such directory.
mkdir -p "$LIFEDIR/test_helpers"
printf '%s\n' 'proc = subprocess.Popen(["ls"])' >"$LIFEDIR/test_helpers/production.py"

# SKIP_GLOBS: a *.md carrying a spawn-shaped line drives the whole-file skip arm.
printf '%s\n' 'Example: `let task = Process()`' >"$LIFEDIR/notes.md"

# An unreadable source file drives the per-file open() OSError arm.
LIFE_UNREAD="$LIFEDIR/unreadable.py"
printf '%s\n' 'proc = subprocess.Popen(["ls"])' >"$LIFE_UNREAD"
chmod 000 "$LIFE_UNREAD" 2>/dev/null || true

LIFE_LIST="$WORKDIR/lifecycle-list.txt"
: >"$LIFE_LIST"
for f in "$LIFEDIR"/capture.swift "$LIFEDIR"/runner.py "$LIFEDIR"/worker.js \
    "$LIFEDIR"/proc.go "$LIFEDIR"/tests/helper.swift "$LIFEDIR"/contest.swift \
    "$LIFEDIR"/test_helpers/production.py \
    "$LIFEDIR"/notes.md "$LIFE_UNREAD"; do
    printf '%s\n' "$f" >>"$LIFE_LIST"
done
# A blank line drives the main() empty-path `if not path: continue` arm.
printf '\n' >>"$LIFE_LIST"

# A file-list PATH that itself does not exist drives the file-list-not-found arm.
LIFE_NOFILE_LIST="$WORKDIR/lifecycle-nonexistent-list-XYZ.txt"
