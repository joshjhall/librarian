// orchestrate — workflow.js pure-helper tests (issue #564 split).
//
// Pure-helper coverage for the orchestrate workflow.js harness.
//
// Covers safeRef / field / setsIntersect (shared byte-identically with
// rebase-agent, so both sources are tested here), safeWorktreePath (#268,
// #269), setsOverlapCount, composeTracks (#178, #462), planRefill (#199),
// buildTrainOrder (#272), and rebaseSkipRemainder (#263).
//
// Extracted verbatim from tests/validate-workflow-helpers.mjs. Assertions are
// collect-all (they record, never throw), so a failure here does not mask any
// sibling area — see tests/lib/mjs-assert.mjs.

import { ok, eq, throws } from "../lib/mjs-assert.mjs";
import { extractHelpers, ORCH, REBASE } from "../lib/extract-helpers.mjs";

export function run() {
  // =============================================================================
  // orchestrate / rebase-agent — safeRef / field / setsIntersect
  // (safeRef + field are byte-identical across both harnesses; test each source.)
  // =============================================================================
  for (const path of [ORCH, REBASE]) {
    const { safeRef, field } = extractHelpers(path, ["safeRef", "field"]);

    eq(
      safeRef("feature/issue-78-foo.bar", "ref"),
      "feature/issue-78-foo.bar",
      `safeRef (${path}): passes a clean path/ref through unchanged`,
    );
    throws(() => safeRef("a b", "ref"), `safeRef (${path}): rejects whitespace`);
    throws(() => safeRef("a\nb", "ref"), `safeRef (${path}): rejects newlines`);
    throws(() => safeRef("", "ref"), `safeRef (${path}): rejects empty string`);
    throws(() => safeRef("a".repeat(256), "ref"), `safeRef (${path}): rejects >255 chars`);
    throws(() => safeRef(42, "ref"), `safeRef (${path}): rejects non-strings`);
    throws(() => safeRef("a;rm -rf", "ref"), `safeRef (${path}): rejects shell metachars`);
    // #269 — the allowlist charset alone admits path-shaped attacks. Reject
    // traversal, absolute paths, leading-dash (option injection), and a `.` cwd
    // segment; keep legit repo-relative paths and dotfile segments (.github/…).
    throws(() => safeRef("../x", "ref"), `safeRef (${path}): rejects a leading \`..\` segment`);
    throws(() => safeRef("a/../b", "ref"), `safeRef (${path}): rejects an interior \`..\` segment`);
    throws(() => safeRef("/etc/x", "ref"), `safeRef (${path}): rejects an absolute path`);
    throws(() => safeRef("--force", "ref"), `safeRef (${path}): rejects a leading-dash (option) value`);
    throws(() => safeRef("./x", "ref"), `safeRef (${path}): rejects a leading \`.\` segment`);
    throws(() => safeRef("a/./b", "ref"), `safeRef (${path}): rejects an interior \`.\` segment`);
    eq(
      safeRef(".github/workflows/ci.yml", "ref"),
      ".github/workflows/ci.yml",
      `safeRef (${path}): passes a legit dotfile segment (not a \`.\`/\`..\` segment)`,
    );
    eq(
      safeRef("src/a.b/c-d_e.ts", "ref"),
      "src/a.b/c-d_e.ts",
      `safeRef (${path}): passes a legit repo-relative path`,
    );

    eq(
      field("branch", "main"),
      "<branch>main</branch>",
      `field (${path}): wraps value in <tag>…</tag>`,
    );
  }

  // =============================================================================
  // orchestrate — safeWorktreePath (#268, #269)
  // safeRef now rejects `..` traversal too (#269), so the two agree on that. The
  // remaining distinction is absolute paths: `git worktree list` yields an
  // absolute checkout dir, so safeWorktreePath tolerates a leading `/` while
  // safeRef rejects it. Only defined in the orchestrate harness.
  // =============================================================================
  {
    const { safeWorktreePath, safeRef } = extractHelpers(ORCH, [
      "safeWorktreePath",
      "safeRef",
    ]);

    eq(
      safeWorktreePath(".worktrees/issue-268", "worktree"),
      ".worktrees/issue-268",
      "safeWorktreePath: passes a clean repo-relative path through unchanged",
    );
    eq(
      safeWorktreePath("/home/vscode/repo/.worktrees/issue-268", "worktree"),
      "/home/vscode/repo/.worktrees/issue-268",
      "safeWorktreePath: passes a clean absolute path through unchanged (git worktree list yields absolute)",
    );
    // The regression guard: the traversal blind spot safeRef does NOT catch.
    throws(
      () => safeWorktreePath(".worktrees/../etc/passwd", "worktree"),
      "safeWorktreePath: rejects a `..` path segment (traversal)",
    );
    throws(
      () => safeWorktreePath("../escape", "worktree"),
      "safeWorktreePath: rejects a leading `..` segment",
    );
    // safeRef agrees on traversal now (#269): the same `..` string it once let
    // through is rejected by both.
    throws(
      () => safeRef(".worktrees/../etc/passwd", "ref"),
      "safeRef: rejects the `..` traversal too (#269)",
    );
    // The remaining foil: safeWorktreePath tolerates an absolute worktree path
    // (git worktree list yields one) that safeRef rejects as a leading `/`.
    throws(
      () => safeRef("/home/vscode/repo/.worktrees/issue-268", "ref"),
      "safeRef: (foil) rejects the absolute path safeWorktreePath accepts",
    );
    throws(() => safeWorktreePath("", "worktree"), "safeWorktreePath: rejects empty string");
    throws(
      () => safeWorktreePath("a".repeat(256), "worktree"),
      "safeWorktreePath: rejects >255 chars",
    );
    throws(() => safeWorktreePath(42, "worktree"), "safeWorktreePath: rejects non-strings");
    throws(
      () => safeWorktreePath(null, "worktree"),
      "safeWorktreePath: rejects null (missing worktree)",
    );
    throws(
      () => safeWorktreePath("a b/c", "worktree"),
      "safeWorktreePath: rejects whitespace",
    );
    throws(
      () => safeWorktreePath("a;rm -rf/b", "worktree"),
      "safeWorktreePath: rejects shell metachars",
    );
    throws(
      () => safeWorktreePath("a/<b>/c", "worktree"),
      "safeWorktreePath: rejects angle brackets (field() delimiter safety)",
    );
    // #269 — safeWorktreePath shares safeRef's leading-`-` (option-injection) and
    // `.`/`..`-segment rejection; only the leading-`/` (absolute) case diverges.
    throws(
      () => safeWorktreePath("--force", "worktree"),
      "safeWorktreePath: rejects a leading-dash (option) value like safeRef",
    );
    throws(
      () => safeWorktreePath("-rf/x", "worktree"),
      "safeWorktreePath: rejects a leading-dash path segment",
    );
    throws(
      () => safeWorktreePath("./x", "worktree"),
      "safeWorktreePath: rejects a leading `.` segment",
    );
    throws(
      () => safeWorktreePath("a/./b", "worktree"),
      "safeWorktreePath: rejects an interior `.` segment",
    );
    // The unique boundary: an ABSOLUTE path (tolerated) that ALSO contains a `..`
    // segment must still be rejected — the leading-`/` allowance and the traversal
    // rejection compose, they don't cancel.
    throws(
      () => safeWorktreePath("/home/vscode/repo/.worktrees/../../etc/passwd", "worktree"),
      "safeWorktreePath: rejects traversal even inside an absolute path",
    );
  }

  {
    const { setsIntersect } = extractHelpers(ORCH, ["setsIntersect"]);
    ok(
      setsIntersect(new Set(["a", "b"]), new Set(["b", "c"])),
      "setsIntersect: true when sets share an element",
    );
    ok(
      !setsIntersect(new Set(["a"]), new Set(["b", "c"])),
      "setsIntersect: false when sets are disjoint",
    );
    ok(
      setsIntersect(new Set(["only"]), new Set(["x", "y", "only", "z"])),
      "setsIntersect: finds the shared element regardless of which set is smaller",
    );
    ok(
      !setsIntersect(new Set(), new Set(["a"])),
      "setsIntersect: false when one set is empty",
    );
  }

  // =============================================================================
  // orchestrate — setsOverlapCount (magnitude of shared paths; tracks mode)
  // =============================================================================
  {
    const { setsOverlapCount } = extractHelpers(ORCH, ["setsOverlapCount"]);
    eq(
      setsOverlapCount(new Set(["a"]), new Set(["b", "c"])),
      0,
      "setsOverlapCount: 0 when sets are disjoint",
    );
    eq(
      setsOverlapCount(new Set(["a", "b"]), new Set(["b", "c"])),
      1,
      "setsOverlapCount: 1 when exactly one path is shared",
    );
    eq(
      setsOverlapCount(new Set(["a", "b", "c"]), new Set(["a", "b", "c", "d"])),
      3,
      "setsOverlapCount: counts every shared path",
    );
    eq(
      setsOverlapCount(new Set(), new Set(["a"])),
      0,
      "setsOverlapCount: 0 when one set is empty",
    );
    eq(
      setsOverlapCount(new Set(["only"]), new Set(["x", "y", "only", "z"])),
      1,
      "setsOverlapCount: finds the shared path regardless of which set is smaller",
    );
  }

  // =============================================================================
  // orchestrate — composeTracks (pure track-composition partition; issue #178)
  // =============================================================================
  {
    const { composeTracks } = extractHelpers(ORCH, ["composeTracks"]);

    // Two disjoint clusters of files → two independent lanes, no cross-track
    // overlap. Overlapping issues co-locate; the two clusters spread across lanes.
    const backlog = [
      { issue: 1, files: ["a.js", "b.js"] },
      { issue: 2, files: ["x.js", "y.js"] },
      { issue: 3, files: ["b.js", "c.js"] }, // overlaps #1 (b.js)
      { issue: 4, files: ["y.js", "z.js"] }, // overlaps #2 (y.js)
    ];
    const r = composeTracks(backlog, { trackCount: 2, trackSize: 5 });

    eq(r.tracks.length, 2, "composeTracks: honors trackCount (2 lanes)");
    eq(
      r.cross_track_overlap,
      0,
      "composeTracks: disjoint clusters land in separate lanes (0 cross-track overlap)",
    );
    // #1 and #3 share b.js → same lane; #2 and #4 share y.js → same lane.
    const laneOf = (n) =>
      r.tracks.findIndex((t) => t.issues.includes(n));
    ok(
      laneOf(1) === laneOf(3),
      "composeTracks: overlapping issues (#1,#3) co-locate in one lane",
    );
    ok(
      laneOf(2) === laneOf(4),
      "composeTracks: overlapping issues (#2,#4) co-locate in one lane",
    );
    ok(
      laneOf(1) !== laneOf(2),
      "composeTracks: the two disjoint clusters occupy different lanes",
    );
    // Within-lane order preserves priority (issue #1 before #3 in its lane).
    const lane1 = r.tracks[laneOf(1)].issues;
    ok(
      lane1.indexOf(1) < lane1.indexOf(3),
      "composeTracks: within-lane order preserves backlog priority",
    );

    // trackCount default is 3, trackSize default is 5; clamped out-of-range inputs.
    const rDefault = composeTracks(
      [
        { issue: 10, files: ["p"] },
        { issue: 11, files: ["q"] },
        { issue: 12, files: ["r"] },
      ],
      {},
    );
    eq(rDefault.tracks.length, 3, "composeTracks: default trackCount is 3");
    const rClamp = composeTracks(backlog, { trackCount: 99, trackSize: 99 });
    ok(
      rClamp.tracks.length <= 4,
      "composeTracks: trackCount clamps to <= 4",
    );

    // Overflow: more disjoint issues than trackCount x trackSize → deferred.
    const many = [];
    for (let i = 1; i <= 8; i++) many.push({ issue: i, files: [`f${i}`] });
    const rOverflow = composeTracks(many, { trackCount: 2, trackSize: 3 });
    const placed = rOverflow.tracks.reduce((n, t) => n + t.issues.length, 0);
    eq(placed, 6, "composeTracks: fills 2 lanes x 3 = 6 issues");
    eq(
      rOverflow.deferred.length,
      2,
      "composeTracks: issues past capacity are deferred",
    );
    for (const t of rOverflow.tracks) {
      ok(
        t.issues.length <= 3,
        "composeTracks: no lane exceeds trackSize",
      );
    }

    // Determinism: identical input → byte-identical output (no Date.now/Math.random).
    eq(
      JSON.stringify(composeTracks(backlog, { trackCount: 2, trackSize: 5 })),
      JSON.stringify(composeTracks(backlog, { trackCount: 2, trackSize: 5 })),
      "composeTracks: deterministic — same input yields identical output",
    );

    // Defensive parse: malformed entries dropped, non-array backlog → empty.
    const rMalformed = composeTracks(
      [{ issue: 5, files: ["a"] }, null, { files: ["b"] }, { issue: "x" }],
      {},
    );
    eq(
      rMalformed.tracks.reduce((n, t) => n + t.issues.length, 0),
      1,
      "composeTracks: drops entries with no integer issue number",
    );
    eq(
      composeTracks(null, {}).tracks.length,
      0,
      "composeTracks: non-array backlog yields no tracks",
    );
  }

  // =============================================================================
  // orchestrate — composeTracks dependency-aware composition (issue #462)
  //   Build order first (co-locate + topo-order dependency clusters), file-overlap
  //   among peers second.
  // =============================================================================
  {
    const { composeTracks } = extractHelpers(ORCH, ["composeTracks"]);
    const laneOfIn = (r, n) => r.tracks.findIndex((t) => t.issues.includes(n));

    // (a) The issue's live repro: #22 (a harness) Depends on #19/#20/#21 — with
    // ZERO shared files (a semantic dep the file-overlap graph can't see). The
    // deps must co-locate with #22 in ONE lane, ahead of it, in topo order, and
    // #22 must not be a track head.
    const repro = [
      { issue: 25, files: ["a.js"] },
      { issue: 19, files: ["brief.json"] },
      { issue: 21, files: ["verifier.md"] },
      { issue: 20, files: ["tailor.md"] },
      { issue: 23, files: ["b.js"] },
      { issue: 22, files: ["harness.js"], deps: [19, 20, 21] },
      { issue: 24, files: ["c.js"] },
      { issue: 13, files: ["d.js"] },
      { issue: 17, files: ["e.js"] },
      { issue: 16, files: ["f.js"] },
      { issue: 18, files: ["g.js"] },
    ];
    const rr = composeTracks(repro, { trackCount: 3, trackSize: 5 });
    const L = laneOfIn(rr, 22);
    ok(
      L === laneOfIn(rr, 19) &&
        L === laneOfIn(rr, 20) &&
        L === laneOfIn(rr, 21),
      "composeTracks(deps): #22 and its deps #19/#20/#21 co-locate in one lane",
    );
    const rlane = rr.tracks[L].issues;
    ok(
      rlane.indexOf(19) < rlane.indexOf(22) &&
        rlane.indexOf(20) < rlane.indexOf(22) &&
        rlane.indexOf(21) < rlane.indexOf(22),
      "composeTracks(deps): all deps land AHEAD of the dependent #22",
    );
    ok(
      rr.tracks.every((t) => t.issues[0] !== 22),
      "composeTracks(deps): dependent #22 is never a track head",
    );
    ok(
      rr.rationale.some((s) => /dependency cluster/.test(s)),
      "composeTracks(deps): rationale notes the co-located dependency cluster",
    );

    // (b) A simple chain #3->#2->#1 whose members would otherwise scatter across
    // disjoint (zero-overlap) lanes must be co-located, deepest dependency first.
    const chain = [
      { issue: 3, files: ["c"], deps: [2] },
      { issue: 2, files: ["b"], deps: [1] },
      { issue: 1, files: ["a"] },
    ];
    const rc = composeTracks(chain, { trackCount: 3, trackSize: 5 });
    eq(rc.tracks.length, 1, "composeTracks(deps): a 3-issue chain forms one lane");
    eq(
      JSON.stringify(rc.tracks[0].issues),
      JSON.stringify([1, 2, 3]),
      "composeTracks(deps): chain ordered deepest-dependency-first (#1,#2,#3)",
    );

    // (c) A dependency CYCLE (#5->#6->#5) is reported and does NOT loop; both
    // members still land (priority order), no crash.
    const cyc = [
      { issue: 5, files: ["x"], deps: [6] },
      { issue: 6, files: ["y"], deps: [5] },
    ];
    const rcyc = composeTracks(cyc, { trackCount: 3, trackSize: 5 });
    ok(
      rcyc.rationale.some((s) => /cycle/i.test(s)),
      "composeTracks(deps): dependency cycle reported in rationale",
    );
    eq(
      rcyc.tracks.reduce((n, t) => n + t.issues.length, 0),
      2,
      "composeTracks(deps): cycle members still placed (no drop, no loop)",
    );
    ok(
      laneOfIn(rcyc, 5) === laneOfIn(rcyc, 6),
      "composeTracks(deps): cycle members co-locate in one lane",
    );
    // A cycle-dropped edge must NOT appear in deps_honored (it was not honored —
    // topoOrderCluster fell back to priority order). At most one of the two
    // reciprocal edges can be honored, and only if it matches the placed order.
    {
      const cLane = rcyc.tracks[laneOfIn(rcyc, 5)];
      const honored = cLane.deps_honored || [];
      ok(
        !(honored.includes("#5->#6") && honored.includes("#6->#5")),
        "composeTracks(deps): a cycle never reports both reciprocal edges as honored",
      );
      const cpos = cLane.issues;
      ok(
        honored.every((e) => {
          const [d, n] = e.slice(1).split("->#").map(Number);
          return cpos.indexOf(d) < cpos.indexOf(n);
        }),
        "composeTracks(deps): every deps_honored edge matches the actual placed order",
      );
    }

    // (d) A dep pointing OUTSIDE the backlog (closed / out-of-scope) forms no
    // edge, is noted, and does not block placement.
    const outdep = [
      { issue: 7, files: ["p"], deps: [999] },
      { issue: 8, files: ["q"] },
    ];
    const rout = composeTracks(outdep, { trackCount: 3, trackSize: 5 });
    ok(
      rout.rationale.some((s) => /outside backlog/.test(s) && /999/.test(s)),
      "composeTracks(deps): out-of-backlog dep ref surfaced in rationale",
    );
    eq(
      rout.tracks.reduce((n, t) => n + t.issues.length, 0),
      2,
      "composeTracks(deps): out-of-backlog dep does not drop the issue",
    );

    // (e) A cluster LARGER than trackSize splits: the topo-prefix (dependencies)
    // lands, the dependent tail defers. Chain #1<-#2<-#3<-#4 with trackSize 3.
    const big = [
      { issue: 1, files: ["a"] },
      { issue: 2, files: ["b"], deps: [1] },
      { issue: 3, files: ["c"], deps: [2] },
      { issue: 4, files: ["d"], deps: [3] },
    ];
    const rbig = composeTracks(big, { trackCount: 3, trackSize: 3 });
    eq(
      JSON.stringify(rbig.tracks[0].issues),
      JSON.stringify([1, 2, 3]),
      "composeTracks(deps): oversized cluster places topo-prefix up to trackSize",
    );
    eq(
      JSON.stringify(rbig.deferred),
      JSON.stringify([4]),
      "composeTracks(deps): oversized cluster defers the dependent tail (#4)",
    );
    ok(
      rbig.rationale.some((s) => /exceeds trackSize/.test(s)),
      "composeTracks(deps): oversized-cluster split noted in rationale",
    );

    // (f) Backward-compat: absent deps → byte-identical to the pre-dependency
    // greedy. Same backlog with and without an all-empty deps field must match,
    // and a self-referential dep is dropped (forms no cluster).
    const plain = [
      { issue: 1, files: ["a.js", "b.js"] },
      { issue: 2, files: ["x.js", "y.js"] },
      { issue: 3, files: ["b.js", "c.js"] },
      { issue: 4, files: ["y.js", "z.js"] },
    ];
    const withEmpty = plain.map((c) => ({ ...c, deps: [] }));
    eq(
      JSON.stringify(composeTracks(plain, { trackCount: 2, trackSize: 5 }).tracks),
      JSON.stringify(
        composeTracks(withEmpty, { trackCount: 2, trackSize: 5 }).tracks,
      ),
      "composeTracks(deps): empty deps yields identical tracks to no deps",
    );
    const selfDep = composeTracks(
      [{ issue: 1, files: ["a"], deps: [1] }],
      { trackCount: 2, trackSize: 5 },
    );
    eq(
      selfDep.tracks[0].issues.length,
      1,
      "composeTracks(deps): a self-referential dep is dropped (no self-cluster loop)",
    );

    // (g) deps_honored: a lane with an in-lane dependency edge carries the
    // structured `#dep->#dependent` list (schema tracks.schema.json); a lane
    // without one omits the field entirely.
    const gLane = rr.tracks[L];
    ok(
      Array.isArray(gLane.deps_honored) &&
        gLane.deps_honored.includes("#19->#22") &&
        gLane.deps_honored.includes("#20->#22") &&
        gLane.deps_honored.includes("#21->#22"),
      "composeTracks(deps): deps_honored lists the in-lane build-order edges",
    );
    ok(
      rr.tracks.every(
        (t) => t === gLane || !("deps_honored" in t),
      ),
      "composeTracks(deps): a lane with no in-lane dep edge omits deps_honored",
    );
    // Chain #1<-#2<-#3 in one lane → two edges, in placement order.
    eq(
      JSON.stringify(rc.tracks[0].deps_honored),
      JSON.stringify(["#1->#2", "#2->#3"]),
      "composeTracks(deps): deps_honored reflects the chain edges in order",
    );

    // (h) Oversized-cluster split into a PARTIALLY-FILLED lane (room < trackSize).
    // With trackCount 1 forcing everything into one lane and trackSize 3, a
    // leading singleton #9 occupies a slot, then chain #1<-#2<-#3 must split with
    // the boundary accounting for #9 already present.
    const partial = [
      { issue: 9, files: ["shared"] },
      { issue: 1, files: ["shared"] },
      { issue: 2, files: ["shared"], deps: [1] },
      { issue: 3, files: ["shared"], deps: [2] },
    ];
    const rpart = composeTracks(partial, { trackCount: 1, trackSize: 3 });
    eq(
      JSON.stringify(rpart.tracks[0].issues),
      JSON.stringify([9, 1, 2]),
      "composeTracks(deps): split boundary accounts for a partially-filled lane",
    );
    eq(
      JSON.stringify(rpart.deferred),
      JSON.stringify([3]),
      "composeTracks(deps): tail past a partially-filled lane's room is deferred",
    );

    // (i) Malformed deps entries (float, string, negative, non-array) are dropped
    // by the Number.isInteger filter; only the valid integer forms a cluster edge.
    const malformedDeps = composeTracks(
      [
        { issue: 30, files: ["m"] },
        { issue: 31, files: ["n"], deps: [30, 1.5, "30", -2] },
      ],
      { trackCount: 3, trackSize: 5 },
    );
    ok(
      laneOfIn(malformedDeps, 30) === laneOfIn(malformedDeps, 31),
      "composeTracks(deps): valid integer dep still forms a cluster amid malformed entries",
    );
    const mdLane = malformedDeps.tracks[laneOfIn(malformedDeps, 31)];
    eq(
      JSON.stringify(mdLane.deps_honored),
      JSON.stringify(["#30->#31"]),
      "composeTracks(deps): malformed dep entries (float/string/negative) dropped, only #30 edge kept",
    );
    eq(
      composeTracks(
        [{ issue: 40, files: ["z"], deps: null }],
        { trackCount: 2, trackSize: 5 },
      ).tracks[0].issues.length,
      1,
      "composeTracks(deps): non-array deps is tolerated (treated as no deps)",
    );

    // (j) Duplicate deps entries are de-duplicated: a repeated in-backlog dep
    // yields a single deps_honored edge; a repeated out-of-backlog ref appears
    // once in the rationale.
    const dupDeps = composeTracks(
      [
        { issue: 50, files: ["u"] },
        { issue: 51, files: ["v"], deps: [50, 50, 999, 999] },
      ],
      { trackCount: 3, trackSize: 5 },
    );
    const dupLane = dupDeps.tracks[laneOfIn(dupDeps, 51)];
    eq(
      JSON.stringify(dupLane.deps_honored),
      JSON.stringify(["#50->#51"]),
      "composeTracks(deps): duplicate in-backlog dep yields a single honored edge",
    );
    eq(
      dupDeps.rationale.filter((s) => /#51->#999/.test(s)).length,
      1,
      "composeTracks(deps): duplicate out-of-backlog dep noted once",
    );
    ok(
      !dupDeps.rationale.some((s) => /#51->#999, #51->#999/.test(s)),
      "composeTracks(deps): out-of-backlog rationale is not duplicated",
    );
  }

  // =============================================================================
  // orchestrate — planRefill (pool pick planner: global + lane-aware; issue #199)
  // =============================================================================
  {
    const { planRefill } = extractHelpers(ORCH, ["planRefill"]);

    // Build a candidate { issue, files:Set } the way runPool normalizes backlog.
    const cand = (issue, files = []) => ({ issue, files: new Set(files) });
    const lane = (l, queue) => ({
      lane: l,
      queue: queue.map(([issue, files]) => cand(issue, files)),
    });

    // --- Global fallback (no lanes) reproduces the pre-#199 behavior. -----------
    {
      const r = planRefill({
        freeSlots: 2,
        accepting: "accepting",
        inflightFiles: new Set(["z.js"]),
        candidates: [cand(1, ["a.js"]), cand(2, ["z.js"]), cand(3, ["b.js"])],
        lanes: [],
        laneSlots: [],
      });
      eq(JSON.stringify(r.picks), JSON.stringify([1, 3]), "planRefill: global picks first two non-colliding in priority order");
      eq(r.held.length, 1, "planRefill: the in-flight collision is held");
      eq(r.held[0].issue, 2, "planRefill: #2 (collides with in-flight z.js) is the held one");
      eq(r.held_slots, 0, "planRefill: both slots filled → no held slots");
    }

    // Draining/paused refills nothing but reports the free slots as held.
    {
      const r = planRefill({
        freeSlots: 3, accepting: "draining", inflightFiles: new Set(),
        candidates: [cand(1, ["a"])], lanes: [], laneSlots: [],
      });
      eq(r.picks.length, 0, "planRefill: draining refills nothing");
      eq(r.held_slots, 3, "planRefill: draining reports all free slots as held");
    }

    // No-file candidates are always dispatchable (never collide).
    {
      const r = planRefill({
        freeSlots: 2, accepting: "accepting", inflightFiles: new Set(["a"]),
        candidates: [cand(1, ["a"]), cand(2, [])], lanes: [], laneSlots: [],
      });
      ok(r.picks.includes(2), "planRefill: a no-file candidate is dispatchable despite in-flight files");
      ok(!r.picks.includes(1), "planRefill: the colliding candidate is still held");
    }

    // --- Lane-aware: a freed lane slot pulls THAT lane's head, not global. ------
    {
      const r = planRefill({
        freeSlots: 1,
        accepting: "accepting",
        inflightFiles: new Set(),
        // Global priority would pick #9 first, but the freed slot belongs to lane 0.
        candidates: [cand(9, ["g.js"])],
        lanes: [lane(0, [[1, ["a.js"]], [2, ["a2.js"]]]), lane(1, [[5, ["b.js"]]])],
        laneSlots: [0],
      });
      eq(JSON.stringify(r.picks), JSON.stringify([1]), "planRefill: freed lane-0 slot pulls lane 0's head (#1), not global #9");
    }

    // Duplicate LIVE-lane index (issue #264): a lane serves at most ONE head per
    // sweep — two golems on one serial track at once would break the invariant the
    // lane pass exists to preserve. The deduped second slot flows to the global
    // fallback rather than pulling lane 0's #2 or being silently lost.
    {
      const r = planRefill({
        freeSlots: 2, accepting: "accepting", inflightFiles: new Set(),
        candidates: [cand(9, ["g.js"])],
        lanes: [lane(0, [[1, ["a.js"]], [2, ["b.js"]], [3, ["c.js"]]])],
        laneSlots: [0, 0],
      });
      eq(JSON.stringify(r.picks), JSON.stringify([1, 9]), "planRefill: duplicate lane-0 slots pick #1 once; second slot flows to global #9 (serial invariant)");
      ok(!r.picks.includes(2), "planRefill: does NOT dispatch lane 0's 2nd head in the same sweep");
      eq(r.held_slots, 0, "planRefill: the deduped slot is not lost — global fills it");
    }

    // Same duplicate, but no global candidate to absorb the freed slot: the second
    // slot is simply left idle (reported as held_slots), never a second lane head.
    {
      const r = planRefill({
        freeSlots: 2, accepting: "accepting", inflightFiles: new Set(),
        candidates: [],
        lanes: [lane(0, [[1, ["a.js"]], [2, ["b.js"]]])],
        laneSlots: [0, 0],
      });
      eq(JSON.stringify(r.picks), JSON.stringify([1]), "planRefill: duplicate lane-0 with no global backfill picks #1 only");
      eq(r.held_slots, 1, "planRefill: the unfilled deduped slot is surfaced as idle");
    }

    // Over-long laneSlots (issue #264): more entries than freeSlots must not
    // produce more picks+holds than freeSlots. One free slot, three colliding
    // lanes — only the first slot is consumed (held), the rest are clamped out.
    {
      const r = planRefill({
        freeSlots: 1,
        accepting: "accepting",
        inflightFiles: new Set(["a.js", "b.js", "c.js"]),
        candidates: [],
        lanes: [
          lane(0, [[1, ["a.js"]]]),
          lane(1, [[2, ["b.js"]]]),
          lane(2, [[3, ["c.js"]]]),
        ],
        laneSlots: [0, 1, 2],
      });
      eq(r.held.length, 1, "planRefill: over-long laneSlots holds at most freeSlots lanes (not 3)");
      ok(r.picks.length + r.held.length <= 1, "planRefill: picks+holds never exceed freeSlots");
      eq(r.held[0].issue, 1, "planRefill: only the first freed slot's lane head is processed");
    }

    // Duplicate lane where the FIRST occurrence HOLDS (issue #264): the head is
    // dequeued and held, the lane is marked seen, so the duplicate's slot must
    // flow to global — never pull the lane's now-exposed 2nd issue in this sweep.
    {
      const r = planRefill({
        freeSlots: 2,
        accepting: "accepting",
        inflightFiles: new Set(["a.js"]), // collides with lane 0's head #1
        candidates: [cand(9, ["g.js"])], // disjoint global work available
        lanes: [lane(0, [[1, ["a.js"]], [2, ["b.js"]]])],
        laneSlots: [0, 0],
      });
      eq(r.held.length, 1, "planRefill: duplicate-hold — exactly one lane-0 head is held");
      eq(r.held[0].issue, 1, "planRefill: duplicate-hold — the held head is lane 0's #1");
      eq(JSON.stringify(r.picks), JSON.stringify([9]), "planRefill: duplicate-hold — the deduped slot flows to global #9");
      ok(!r.picks.includes(2), "planRefill: duplicate-hold — does NOT pull lane 0's exposed 2nd issue");
    }

    // --- Exhausted lane falls back to the global pick for that slot. ------------
    {
      const r = planRefill({
        freeSlots: 1, accepting: "accepting", inflightFiles: new Set(),
        candidates: [cand(7, ["g.js"])],
        lanes: [lane(0, [])], // lane 0's queue is empty (track exhausted)
        laneSlots: [0],
      });
      eq(JSON.stringify(r.picks), JSON.stringify([7]), "planRefill: an exhausted lane slot falls back to the global pick (#7)");
    }
    // An unknown lane index is likewise treated as exhausted → global fallback.
    {
      const r = planRefill({
        freeSlots: 1, accepting: "accepting", inflightFiles: new Set(),
        candidates: [cand(7, ["g.js"])], lanes: [lane(0, [[1, ["a"]]])], laneSlots: [5],
      });
      eq(JSON.stringify(r.picks), JSON.stringify([7]), "planRefill: an unknown freed-lane index falls back to global");
    }
    // Repeated exhausted/unknown index (issue #264): seenLanes only guards LIVE
    // lanes, so [9, 9] with lane 9 absent lets BOTH freed slots reach global —
    // the dedup must not swallow a slot that never made a lane pick.
    {
      const r = planRefill({
        freeSlots: 2, accepting: "accepting", inflightFiles: new Set(),
        candidates: [cand(7, ["g7.js"]), cand(8, ["g8.js"])],
        lanes: [lane(0, [[1, ["a"]]])], // lane 9 does not exist
        laneSlots: [9, 9],
      });
      eq(JSON.stringify(r.picks), JSON.stringify([7, 8]), "planRefill: repeated unknown lane index — both freed slots flow to global");
    }

    // --- Serial hold: a colliding lane head HOLDS its slot (no skip / no steal).
    {
      const r = planRefill({
        freeSlots: 1,
        accepting: "accepting",
        inflightFiles: new Set(["a.js"]), // collides with lane 0's head
        candidates: [cand(9, ["free.js"])], // global work IS available and disjoint
        lanes: [lane(0, [[1, ["a.js"]], [2, ["b.js"]]])],
        laneSlots: [0],
      });
      eq(r.picks.length, 0, "planRefill: a colliding lane head does not dispatch");
      ok(!r.picks.includes(2), "planRefill: serial invariant — does NOT skip to the lane's 2nd issue");
      ok(!r.picks.includes(9), "planRefill: serial invariant — does NOT steal global work for a held lane slot");
      eq(r.held[0].issue, 1, "planRefill: the held lane head is reported");
      eq(r.held_slots, 1, "planRefill: the held lane slot is counted");
    }

    // --- Mixed: one live lane + one exhausted lane; global fills the rest. ------
    {
      const r = planRefill({
        freeSlots: 3,
        accepting: "accepting",
        inflightFiles: new Set(),
        candidates: [cand(8, ["g8.js"]), cand(9, ["g9.js"])],
        lanes: [lane(0, [[1, ["a.js"]]]), lane(1, [])],
        laneSlots: [0, 1], // lane 0 lives (→ #1), lane 1 exhausted (→ global)
      });
      ok(r.picks.includes(1), "planRefill: live lane 0 contributes its head #1");
      ok(r.picks.includes(8), "planRefill: exhausted lane 1's slot + spare go to global (#8)");
      eq(r.picks.length, 3, "planRefill: all three slots filled (1 lane + 2 global)");
      // Lane pick and global picks never collide (shared claimed set).
      eq(new Set(r.picks).size, 3, "planRefill: no duplicate picks across passes");
    }

    // --- Determinism: identical input → identical output. -----------------------
    {
      const build = () => ({
        freeSlots: 2, accepting: "accepting", inflightFiles: new Set(["z"]),
        candidates: [cand(1, ["a"]), cand(2, ["z"]), cand(3, ["b"])],
        lanes: [lane(0, [[4, ["c"]]])], laneSlots: [0],
      });
      eq(
        JSON.stringify(planRefill(build())),
        JSON.stringify(planRefill(build())),
        "planRefill: deterministic — same input yields identical output",
      );
    }
  }

  // =============================================================================
  // orchestrate — buildTrainOrder (pure merge-order graph; issue #272)
  // The graph/wave computation was extracted from runTrain's async body so the
  // merge-sequencing correctness — the whole point of the train — is unit-tested.
  // It only ever receives RESOLVED PRs ({ pr, files }); a PR whose files could not
  // be fetched is routed to train.unresolved by runTrain and never reaches here,
  // which is the fail-closed fix (an unknown file set must NOT become wave 0).
  // =============================================================================
  {
    const { buildTrainOrder } = extractHelpers(ORCH, ["buildTrainOrder"]);

    // Two disjoint PRs → both independent, land together in a single wave.
    {
      const t = buildTrainOrder([
        { pr: 1, files: ["a.js"] },
        { pr: 2, files: ["b.js"] },
      ]);
      eq(JSON.stringify(t.independents), JSON.stringify([1, 2]), "buildTrainOrder: disjoint PRs are both independent");
      eq(t.chains.length, 0, "buildTrainOrder: no chains when nothing overlaps");
      eq(JSON.stringify(t.waves), JSON.stringify([[1, 2]]), "buildTrainOrder: disjoint PRs share one wave");
      eq(JSON.stringify(t.order), JSON.stringify([1, 2]), "buildTrainOrder: linear order lists both independents");
    }

    // Two PRs sharing a file → one chain of length 2; wave 0 = head, wave 1 = link.
    {
      const t = buildTrainOrder([
        { pr: 1, files: ["shared.js", "a.js"] },
        { pr: 2, files: ["shared.js", "b.js"] },
      ]);
      eq(t.independents.length, 0, "buildTrainOrder: overlapping PRs are not independent");
      eq(JSON.stringify(t.chains), JSON.stringify([[1, 2]]), "buildTrainOrder: overlapping PRs form one ordered chain");
      eq(JSON.stringify(t.waves), JSON.stringify([[1], [2]]), "buildTrainOrder: chain head is wave 0, link is wave 1");
      eq(JSON.stringify(t.order), JSON.stringify([1, 2]), "buildTrainOrder: chain laid out in sequence in the linear order");
    }

    // Mixed: an independent PR + a 2-PR chain. Wave 0 = independent + chain head.
    {
      const t = buildTrainOrder([
        { pr: 1, files: ["x.js"] }, // independent
        { pr: 2, files: ["c.js"] }, // chain with #3
        { pr: 3, files: ["c.js"] },
      ]);
      eq(JSON.stringify(t.independents), JSON.stringify([1]), "buildTrainOrder: the disjoint PR is independent");
      eq(JSON.stringify(t.chains), JSON.stringify([[2, 3]]), "buildTrainOrder: the overlapping pair is the chain");
      eq(JSON.stringify(t.waves), JSON.stringify([[1, 2], [3]]), "buildTrainOrder: wave 0 = independent + chain head, wave 1 = link");
    }

    // Fail-closed contract (#272): the helper receives ONLY resolved PRs, so an
    // empty resolved set (every PR unresolved) yields empty everything — the
    // unresolved PRs are surfaced by runTrain's partition, never as wave 0 here.
    {
      const t = buildTrainOrder([]);
      eq(JSON.stringify(t.independents), JSON.stringify([]), "buildTrainOrder: no resolved PRs → no independents (unknown PRs never enter wave 0)");
      eq(JSON.stringify(t.chains), JSON.stringify([]), "buildTrainOrder: no resolved PRs → no chains");
      eq(JSON.stringify(t.waves), JSON.stringify([]), "buildTrainOrder: no resolved PRs → no waves");
      eq(JSON.stringify(t.order), JSON.stringify([]), "buildTrainOrder: no resolved PRs → empty order");
    }

    // Determinism: identical input → byte-identical output (no Date.now/Math.random).
    {
      const build = () => [
        { pr: 3, files: ["c.js"] },
        { pr: 1, files: ["a.js", "c.js"] },
        { pr: 2, files: ["b.js"] },
      ];
      eq(
        JSON.stringify(buildTrainOrder(build())),
        JSON.stringify(buildTrainOrder(build())),
        "buildTrainOrder: deterministic — same input yields identical output",
      );
    }
  }

  // =============================================================================
  // orchestrate — rebaseSkipRemainder (pure early-exit accounting; issue #263)
  // The Rebase loop in runPollSweep stops early on the budget floor or the
  // MAX_REBASES cap; this helper reports which behind-base PRs were never
  // attempted (queue remainder past `i`) and why. Extracted from the async body
  // so the off-by-one the accounting depends on — `i` is the first un-attempted
  // PR for BOTH exits — is unit-tested.
  // =============================================================================
  {
    const { rebaseSkipRemainder } = extractHelpers(ORCH, ["rebaseSkipRemainder"]);
    const q = [{ number: 1 }, { number: 2 }, { number: 3 }];

    // (a) budget exit with PRs remaining → remainder tagged 'budget exhausted',
    //     no cap log (the loop already logged the budget stop).
    {
      const r = rebaseSkipRemainder(q, 1, true, 2);
      eq(
        JSON.stringify(r.skipped),
        JSON.stringify([{ pr: 2, reason: "budget exhausted" }, { pr: 3, reason: "budget exhausted" }]),
        "rebaseSkipRemainder: budget exit tags the remainder 'budget exhausted'",
      );
      eq(r.capLog, null, "rebaseSkipRemainder: budget exit emits no cap log (loop already logged)");
    }

    // (b) max-rebases-cap exit with PRs remaining → remainder tagged
    //     'max-rebases cap' and a cap log line is returned to emit.
    {
      const r = rebaseSkipRemainder(q, 2, false, 2);
      eq(
        JSON.stringify(r.skipped),
        JSON.stringify([{ pr: 3, reason: "max-rebases cap" }]),
        "rebaseSkipRemainder: cap exit tags the remainder 'max-rebases cap'",
      );
      eq(
        r.capLog,
        "rebase sweep hit max-rebases cap (2) — 1 behind-base PR(s) not attempted",
        "rebaseSkipRemainder: cap exit returns a log line with the cap and count",
      );
    }

    // (c) queue fully drained (i === queue.length) → empty remainder, no log,
    //     for either exit flag.
    {
      const r = rebaseSkipRemainder(q, 3, false, 3);
      eq(JSON.stringify(r.skipped), JSON.stringify([]), "rebaseSkipRemainder: drained queue → empty remainder");
      eq(r.capLog, null, "rebaseSkipRemainder: drained queue → no cap log");
      const rb = rebaseSkipRemainder(q, 3, true, 3);
      eq(JSON.stringify(rb.skipped), JSON.stringify([]), "rebaseSkipRemainder: drained queue → empty remainder (budget flag)");
    }

    // (d) cap hit on the very last item (i past the end after the final i++) →
    //     empty remainder, guarding the off-by-one the inline comment calls out.
    {
      const r = rebaseSkipRemainder(q, q.length, false, 3);
      eq(JSON.stringify(r.skipped), JSON.stringify([]), "rebaseSkipRemainder: cap on last item → nothing left un-attempted");
      eq(r.capLog, null, "rebaseSkipRemainder: cap on last item → no cap log (nothing skipped)");
    }

    // (e) cap of 0 over a non-empty queue → the loop body never runs (i === 0),
    //     so the entire queue is the 'max-rebases cap' remainder.
    {
      const r = rebaseSkipRemainder(q, 0, false, 0);
      eq(
        JSON.stringify(r.skipped),
        JSON.stringify([
          { pr: 1, reason: "max-rebases cap" },
          { pr: 2, reason: "max-rebases cap" },
          { pr: 3, reason: "max-rebases cap" },
        ]),
        "rebaseSkipRemainder: maxRebases 0 → whole queue is the cap remainder",
      );
      eq(
        r.capLog,
        "rebase sweep hit max-rebases cap (0) — 3 behind-base PR(s) not attempted",
        "rebaseSkipRemainder: maxRebases 0 → cap log reports the full queue length",
      );
    }
  }
}
