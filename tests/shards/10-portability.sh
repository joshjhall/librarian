# shellcheck shell=bash
# The Shell-portability shard: one indivisible stage, and whatever fits beside
# it (#960, re-balanced #964).
#
# THIS SHARD IS SIZED BY ITS FLOOR, NOT BY A THEME. `Shell portability` cannot
# be subdivided and is essentially the whole leg, so it sets the matrix's LOWER
# BOUND: no arrangement of the three shards makes the suite finish sooner than
# that one stage. Every other stage in the leg costs 0-1s (eight of them: the
# seven listed below plus `Shard partition`, which run-all.sh injects into every
# shard rather than a shard file declaring it).
#
# The bound is STRUCTURAL, not a specific number, and the two must not be mixed.
# In the post-move composition (run 34187725583) the stage was 335s of a 337s
# leg — the only same-composition stage/leg pairing measured so far. Two earlier
# samples, 364s (34166830481) and 357s (34165410091), predate the move and are
# NOT comparable as a share: that leg still carried the four gates #964 shifted
# out (+157s), so the stage was ~70% of a ~522s leg. Read across all three, the
# stage's own runtime varies ~8% on identical code. So the durable claim is "this
# stage is indivisible and dominates its leg", never "the floor is N seconds".
# Re-derive per run from its `[ok] Shell portability … (Ns)` line, and pair it
# only with a leg total from that same run.
#
# WHY THE OLDER 547s FIGURE IS NOT COMPARABLE: it came from the PRE-SHARDING
# serial run, all ~96 stages on one runner. The stage did not get faster, and
# nothing in #964 touched tests/lint-shell-portability.sh — the measurement
# context changed, not the code.
#
# "Lower bound" is also not "the slowest leg". Post-#964 the legs are close
# enough (337 / 350 / 260s in run 34187725583) that 20-golem finished last, and
# which one leads varies with runner speed. This shard is the one that CANNOT get
# faster; that is the property that matters here.
#
# #964 traded away the original grouping deliberately. This shard used to hold
# every language-level gate (shellcheck, ruff, typos, the bash<->python
# differential) because they share a theme and a toolchain — a real and readable
# rationale, but it had this shard at 522s against 376s and 175s, which made the
# theme cost ~157s of wall clock on every CI run. The four gates that left
# (differential 88s, shellcheck 52s, python-port 11s, bounded_run 6s) are now in
# 30-scanners, tagged there as balance-motivated so nobody reunites them by
# theme without re-measuring. Measured after the move (run 34187725583): the
# three legs are 337 / 350 / 260s, within ~90s of each other instead of ~347s,
# and CI wall clock went 542s -> 370s.
#
# SO: prefer 30-scanners for a new gate unless it genuinely needs to sit beside
# Shell portability. Either way measure all three sums within one run first. From
# run 34187725583 (337 / 350 / 260s): only 13s separates the top two legs, so a
# stage even that small changes which one finishes last, while 30-scanners sits
# 77s below this leg and 90s below 20-golem — that gap is its headroom before it
# becomes the leg that decides the matrix.
#
# SOURCED by tests/run-all.sh (and by tests/validate-shards.sh with a stub
# run_stage), never executed — hence no shebang. Sourcing with a stub run_stage
# is what lets the partition be checked WITHOUT running the suite: the stub
# records each label instead of dispatching it. There is deliberately no
# second spelling of the label to keep in sync — one call site per stage.
#
# Add a stage HERE, not in run-all.sh — and add it to exactly one shard.

run_stage "Action pin format" bash "$SCRIPT_DIR/lint-action-pins.sh"
# merge-gate composition (#947). Sits beside the action-pin gate because it is
# the other structural reader of .github/workflows/ci.yml, not because it is
# about portability. merge-gate is the single required branch-protection check,
# so nothing else in the suite notices if bsd-probe falls back out of its
# `needs:` — every shard would stay green while the gate stopped gating.
run_stage "merge-gate composition" bash "$SCRIPT_DIR/validate-merge-gate.sh"
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
