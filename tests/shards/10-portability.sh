# shellcheck shell=bash
# The Shell-portability shard: one indivisible stage, and whatever fits beside
# it (#960, re-balanced #964).
#
# THIS SHARD IS SIZED BY ITS FLOOR, NOT BY A THEME. `Shell portability` is 364s
# and cannot be subdivided, so it is the matrix's critical path: no arrangement
# of the other two shards can make the suite finish sooner than this one stage.
# Everything else here is small enough to ride along without raising that floor.
#
# #964 traded away the original grouping deliberately. This shard used to hold
# every language-level gate (shellcheck, ruff, typos, the bash<->python
# differential) because they share a theme and a toolchain — a real and readable
# rationale, but it had this shard at 522s against 376s and 175s, which made the
# theme cost ~157s of wall clock on every CI run. The four gates that left
# (differential 88s, shellcheck 52s, python-port 11s, bounded_run 6s) are now in
# 30-scanners, tagged there as balance-motivated so nobody reunites them by
# theme without re-measuring.
#
# SO: adding a stage here raises the critical path ~1:1, unlike the other two
# shards which still have slack. Measure before adding, and prefer 30-scanners
# unless the gate genuinely needs to sit beside Shell portability.
#
# SOURCED by tests/run-all.sh (and by tests/validate-shards.sh with a stub
# run_stage), never executed — hence no shebang. Sourcing with a stub run_stage
# is what lets the partition be checked WITHOUT running the suite: the stub
# records each label instead of dispatching it. There is deliberately no
# second spelling of the label to keep in sync — one call site per stage.
#
# Add a stage HERE, not in run-all.sh — and add it to exactly one shard.

run_stage "Action pin format" bash "$SCRIPT_DIR/lint-action-pins.sh"
run_stage "Shell portability (bash 3.2 clean)" bash "$SCRIPT_DIR/lint-shell-portability.sh"
# Regex-dialect probe (#684). Here it asserts only the POSIX baseline — the
# spellings #679 migrated TO — which must hold on every host; its word-boundary
# rows are informational and never fail. The answer it exists to produce comes
# from the macos-latest `bsd-probe` job in ci.yml, since this host is GNU. Run
# locally too so the probe cannot rot unnoticed between macOS runs.
run_stage "Regex dialect probe (POSIX baseline)" bash "$SCRIPT_DIR/probe-bsd-regex.sh"
# ...and the probe's own reporting logic. Running the probe above exercises only
# its SUPPORTED/require-pass paths on a GNU host; this forces the UNSUPPORTED,
# ERROR and require-FAIL branches, which are the ones carrying the signal.
run_stage "Regex-probe reporting integrity" bash "$SCRIPT_DIR/validate-regex-probe.sh"
run_stage "Source-level category-slug parity" bash "$SCRIPT_DIR/validate-scanner-category-parity.sh"
run_stage "Python lint + format (ruff)" bash "$SCRIPT_DIR/lint-python.sh"
run_stage "Spell check (typos)" bash "$SCRIPT_DIR/lint-typos.sh"
run_stage "bounded-run.sh copy sync" bash "$SCRIPT_DIR/lint-bounded-run-sync.sh"
