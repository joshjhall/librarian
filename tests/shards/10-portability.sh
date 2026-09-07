# shellcheck shell=bash
# Portability, lint and cross-runtime parity stages (#960).
#
# Carries the suite's single largest stage: Shell portability, 547s of a
# 1299s serial run (42%). That stage is indivisible, so it sets the floor
# for the whole matrix and the other shards are balanced around it rather
# than against it. Grouped with the other language-level gates (shellcheck,
# ruff, typos, the bash<->python differential) because they share a theme
# and, usefully, the same toolchain.
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
run_stage "Python-port contract + bash parity" bash "$SCRIPT_DIR/validate-python-ports.sh"
run_stage "Pre-scan bash<->python differential" bash "$SCRIPT_DIR/validate-prescan-differential.sh"
run_stage "Source-level category-slug parity" bash "$SCRIPT_DIR/validate-scanner-category-parity.sh"
run_stage "Shellcheck (bundled shell scripts)" bash "$SCRIPT_DIR/lint-shellcheck.sh"
run_stage "Python lint + format (ruff)" bash "$SCRIPT_DIR/lint-python.sh"
run_stage "Spell check (typos)" bash "$SCRIPT_DIR/lint-typos.sh"
run_stage "bounded-run.sh copy sync" bash "$SCRIPT_DIR/lint-bounded-run-sync.sh"
