# Read-granularity & truncation-marker tally — issue #786

**Status: OPEN — awaiting a post-merge window.** This file ships with the
guidance change ([#786](https://github.com/joshjhall/librarian/issues/786)) as
the instrument for its AC5 (before/after tool-result share). AC1–AC4 and AC6
are discharged in the PR itself; this tally exists because AC5 cannot be.

Tracked to closure by
[#1050](https://github.com/joshjhall/librarian/issues/1050), so the open row is
not silently treated as closed by #786's merge — the same pairing
[#771](https://github.com/joshjhall/librarian/issues/771) gave #768's tally.

**Figures here are NORMALIZED — percentages and ratios only.** See
[`token-baseline-tally-781.md`](token-baseline-tally-781.md) § Why no absolute
figures: this repo is public and committing fleet-wide request counts or dollar
totals would publish this org's LLM spend permanently.

## Why this could not be measured in the shipping PR

AC5 asks for "transcript tool-result share measured on a comparable session
via #781". The PR that adds guidance cannot contain its own effect — the
guidance has to be in agents' hands and running before there is an "after" — and
`BIFROST_URL` is unset in the authoring environment besides.

This is the same split [#785](https://github.com/joshjhall/librarian/issues/785)
took, and it is deliberate rather than a deferral of convenience. What that
issue's tally learned the hard way is recorded below, because it changes what
this one has to watch for.

## The lesson from #785, which this change is shaped by

Issue #785 shipped investigation-delegation guidance. Measured later under
[#797](https://github.com/joshjhall/librarian/issues/797), it had fired **zero**
times across 118 spawns in 13 sessions, against 49 inline investigations that
cleared its own break-even. The skill was reaching sessions — it appeared in 12
of 13 transcripts — so the gap was between _being read_ and _being acted on_.

[#978](https://github.com/joshjhall/librarian/issues/978) found the cause and
[#1034](https://github.com/joshjhall/librarian/issues/1034) fixed it: the rule
was **retrospective on both inputs**. `result_tokens x turns_resident` cannot be
evaluated before reading, because `turns_resident` counts turns that have not
happened yet and `result_tokens` does not exist until the read has already run
inline — which is the cost the rule was meant to avoid.

**So the first question for this tally is not "did the saving materialize" but
"did the guidance fire at all."** #786's rule was written to be evaluable at the
decision point for exactly this reason — "name the narrowest range that could
contain the answer" asks only what the agent already knows. Whether that is
enough is an empirical question this file answers, not an assumption.

## What is being measured

### AC5 — tool-result share, before vs after

```bash
# the share this change targets
plugins/workflow/scripts/token-attribute.sh debt \
  --since <BEFORE_START> --until <BEFORE_END>
plugins/workflow/scripts/token-attribute.sh bash-class \
  --since <BEFORE_START> --until <BEFORE_END>
```

**Always pass a window.** Without `--since`/`--until` the scan covers every
transcript under `~/.claude/projects`, so the emitted `window_start` is the
oldest transcript and joins against no gateway window at all. Use the same
boundaries given to `token-report.sh window`.

| row | baseline (#786, 24h, 2026-08-23) | after | verdict |
| --- | --- | --- | --- |
| tool results as share of transcript volume | 48% | _pending_ | _pending_ |
| Bash share of re-read debt | 76% | _pending_ | _pending_ |
| `sed` mean result chars | 2,458 | _pending_ | _pending_ |
| `cat` mean result chars | 1,809 | _pending_ | _pending_ |
| `TaskOutput` mean result chars | 7,776 | _pending_ | _pending_ |

### The confound, stated before any number is filled in

**#785 landed first, and it targets the same tokens by a different mechanism.**
The issue says so explicitly: *"whichever lands first will reduce the other's
measured headroom — do not sum their estimates, and re-measure the second one's
baseline after the first lands."*

The baseline column above is the **pre-#785** figure, taken from #786's own
filing. It is therefore **not** a valid "before" for this change on its own, and
must be re-taken on a window that already contains #785 before any after-figure
is compared to it. Two rows in one table that came from different trees is the
error this paragraph exists to prevent.

There is a second-order wrinkle worth noting: #785's own adoption was zero
until #1034, so a window opening before that fix contains #785's _guidance_
but not its _effect_. A valid baseline window opens after `31d0609`.

### The reading that is not a win

A fall in mean result chars is the intended effect, but it is not
self-evidently good. Two failure shapes produce the same number:

1. **Narrow reads that miss**, followed by a second and third widening read.
   Total volume can rise while the mean falls. Check call _count_ alongside the
   mean — `bash-class` reports both.
2. **Reads that do not happen at all.** The rule narrows reads; it does not
   skip them. An agent that answers from assumption instead of reading produces
   an excellent token profile and worse work. Not visible in any token metric
   — the same blind spot #785's tally flagged for recall.

## Row target

This tally closes when a post-`31d0609` window is available and the table above
is filled with matched before/after figures from windows that both contain #785.
Until then it stays open.

## AC2/AC3/AC6 — discharged in the PR, not here

Recorded for completeness, since a reader arriving at this file may expect all
six ACs:

- **AC2** (a ceiling marks truncation unmistakably; a test asserts the marker):
  `truncate_chars` now appends `…` when and only when it cuts, in 15 bash copies
  and 14 python peers; `tests/lint-truncation-markers.sh` asserts presence,
  conditionality, and that the check itself fires on a broken copy.
- **AC3** (byte-faithful paths exempt, and the exemption tested): the review
  diff stays unclamped; the same gate pins it, deferring to the
  `*-BYTE-FAITHFUL-*` sentinel in
  `tests/workflow-helpers/ship-issue/04-tdz-and-diff.mjs` (#267).
- **AC4** (`TaskOutput` reviewed): all five call sites are harness poll loops
  that want a completion verdict, not a transcript; each now says so. The tool's
  own output size is harness-side and not capped from a plugin.
- **AC6** (a legitimately large read still gets it, marker absent): the
  conditional-marker case in the gate — an at-cap and a short value must both
  come back unmarked.

**A scope boundary this issue's title invites misreading.** The Bash tool's
result size is harness-side; a plugin cannot cap it. "Cap tool-result volume"
is therefore discharged as _guidance_ for the reads agents choose to make, plus
_loud marking_ on the ceilings this repo actually enforces. The 48%/76% figures
will move only if the guidance changes behavior — which is precisely what the
table above is for, and why the #785 lesson is recorded at the top.
