---
name: prescan-bash-python-equivalence
description: How bash/python pre-scan equivalence is tested and the truncation/locale gotcha
metadata:
  node_type: memory
  type: project
  originSessionId: 1ac0f375-23a6-4d60-93e2-6e59f911c353
  modified: 2026-08-01T04:13:40.340Z
---

The pre-scan tools ship bash + python impls that must be byte-identical. Two
gates enforce this: `tests/validate-python-ports.sh` (contract + one shared
fixture) and `tests/validate-prescan-differential.sh` (PR #187 — diffs bash vs
python over the WHOLE repo tree + a per-category/language fixture library; the
thorough one). Any byte difference fails.

**Evidence truncation is CHARACTER-based, not byte-based** (decided in #187).
bash `printf '%.Ns'` truncates by bytes and can split a UTF-8 char; python
`str[:N]` truncates by chars. All 14 tools + `pre-review-gates.sh` use a
`truncate_chars` bash helper that slices `${s:0:N}` under a detected UTF-8 locale
(`C.UTF-8`/`en_US.UTF-8`), with a byte-wise `printf` fallback if no UTF-8 locale
exists. The 4 awk emitters (loop-make-it-right deep-nesting,
loop-make-it-documented) emit the raw line as a trailing field and let the bash
helper truncate — awk's `%.Ns`/`substr` are byte-based even under a UTF-8 locale
(and the env's awk is mawk/busybox: `length()` counts bytes).

**Gotcha:** if the runtime has NO UTF-8 locale, bash falls back to byte-trunc
while python stays char-based → the differential gate would flag a divergence
that is environmental, not a code bug. Ubuntu CI + macOS both ship C.UTF-8 /
en_US.UTF-8, so this is not hit in practice — but keep it in mind before
"fixing" a differential failure that only reproduces on an exotic locale.

Also fixed in #187: check-docs-examples aborted mid-scan under `set -euo
pipefail` when a code-block line's `grep` found no match (a `$()` non-zero killed
the whole scan, silently dropping later findings). Guarded with `|| true`.
