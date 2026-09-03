// prelude-generator area — bin/generate-prelude.mjs's pure exports (#586).
//
// tests/validate-prelude-sync.sh drives the generator end-to-end via `--check`
// against the real committed tree. That proves the happy path and the drift
// detection, but it can never reach the parser/splicer's ERROR branches: those
// fire only on malformed input, and the committed tree is by definition
// well-formed. Those branches are exactly what a future edit to
// plugins/lib/prelude.js or to a harness's banner markers is most likely to
// trip, and each one exists to fail LOUDLY rather than silently emit less than
// the caller asked for — a silent empty section would delete working code from
// every consumer.
//
// So this area imports the exports directly (which is why they are exported —
// importing the module runs no main(), by the `process.argv[1]` guard) and
// asserts each documented error actually throws on its corresponding fixture.
//
// Assertions here collect rather than throw (tests/lib/mjs-assert.mjs), so one
// bad case cannot mask its siblings.

// BANNER_START/BANNER_END are IMPORTED, never re-literalized. Hardcoding copies
// of constants the module exports is the same copy-drift this whole PR exists to
// eliminate: if the banner text changed, stale fixtures would make spliceRegion
// throw "no generated region" on input that no longer matches the real markers —
// a false failure that misdiagnoses the actual change.
import {
  BANNER_END,
  BANNER_START,
  readSections,
  renderRegion,
  spliceRegion,
} from "../../bin/generate-prelude.mjs";
import { ok, eq } from "../lib/mjs-assert.mjs";

// Assert a call throws AND that the message identifies the expected cause.
//
// The shared `throws()` deliberately ignores the message, which is too weak
// here: several of these fixtures are malformed in more than one way, so a
// bare throws() passes on a DIFFERENT error than the one under test. Measured —
// neutering the nested-marker guard left the nested fixture still throwing
// (`unterminated section`), and a bare throws() could not tell the difference,
// so the test passed with the guard disabled. Matching the message is what
// gives these assertions teeth.
//
// Records rather than throws, matching the collect-all contract of
// tests/lib/mjs-assert.mjs.
function throwsMatching(fn, pattern, msg) {
  let caught = null;
  try {
    fn();
  } catch (e) {
    caught = e;
  }
  if (caught === null) {
    ok(false, `${msg} — expected a throw, but none occurred`);
    return;
  }
  const text = caught && caught.message ? caught.message : String(caught);
  ok(pattern.test(text), `${msg} (got: ${text.split("\n")[0]})`);
}

// A well-formed two-section source, reused as the positive control. Every
// negative case below is a mutation of this shape, so a failure means the
// mutation was rejected — not that the fixture was malformed to begin with.
const GOOD = [
  "// header prose, outside any section",
  "// >>> prelude:alpha",
  "const A = 1",
  "// <<< prelude:alpha",
  "",
  "// >>> prelude:beta",
  "const B = 2",
  "// <<< prelude:beta",
  "",
].join("\n");

export function run() {
  // --- readSections: the positive control -----------------------------------
  const sections = readSections(GOOD);
  eq(sections.size, 2, "readSections: parses both sections");
  eq(sections.get("alpha"), "const A = 1", "readSections: section body excludes its markers");
  eq(sections.get("beta"), "const B = 2", "readSections: second section body is exact");
  ok(
    !sections.get("alpha").includes("header prose"),
    "readSections: text outside a section is not captured",
  );

  // --- readSections: every documented error branch ---------------------------
  // Each is a real failure mode of hand-editing the source, and each must throw
  // rather than yield a short/empty section that would silently shrink a copy.
  throwsMatching(
    () => readSections("// >>> prelude:alpha\nconst A = 1\n"),
    /unterminated section: alpha/,
    "readSections: an unterminated section throws",
  );
  throwsMatching(
    () => readSections("// >>> prelude:alpha\nx\n// <<< prelude:beta\n"),
    /mismatched section markers/,
    "readSections: mismatched open/close names throw",
  );
  throwsMatching(
    () => readSections("// >>> prelude:a\nx\n// <<< prelude:a\n// >>> prelude:a\ny\n// <<< prelude:a\n"),
    /duplicate section: a/,
    "readSections: a duplicate section name throws",
  );
  // CLOSED properly, so `nested` is the ONLY defect present. An unterminated
  // variant would throw `unterminated section` even with the nested-marker guard
  // disabled — measured, and the reason this fixture is shaped this way.
  throwsMatching(
    () => readSections("// >>> prelude:a\n// >>> prelude:b\nx\n// <<< prelude:b\n// <<< prelude:a\n"),
    /nested section marker: b inside a/,
    "readSections: a nested section marker throws",
  );
  throwsMatching(
    () => readSections("// <<< prelude:a\n"),
    /close marker with no open section: a/,
    "readSections: a close marker with no open section throws",
  );
  throwsMatching(
    () => readSections("const x = 1\n"),
    /no sections found/,
    "readSections: a source with no sections at all throws",
  );

  // --- renderRegion ----------------------------------------------------------
  const region = renderRegion(sections, ["alpha"]);
  ok(region.startsWith(BANNER_START), "renderRegion: emits the opening banner");
  ok(region.trimEnd().endsWith(BANNER_END), "renderRegion: emits the closing banner");
  ok(region.includes("const A = 1"), "renderRegion: carries the requested section body");
  ok(
    !region.includes("const B = 2"),
    "renderRegion: does NOT carry an unrequested section (per-consumer selection is real)",
  );

  // Order follows the REQUESTED names, not the source's declaration order — the
  // property that lets a consumer compose sections deliberately.
  const both = renderRegion(sections, ["beta", "alpha"]);
  ok(
    both.indexOf("const B = 2") < both.indexOf("const A = 1"),
    "renderRegion: emits sections in the order requested",
  );

  throwsMatching(
    () => renderRegion(sections, ["nope"]),
    /unknown prelude section\(s\): nope/,
    "renderRegion: an unknown section name throws rather than emitting nothing",
  );

  // --- spliceRegion ----------------------------------------------------------
  const START = BANNER_START;
  const END = BANNER_END;
  const host = `const before = 1\n${START}\nOLD BODY\n${END}\nconst after = 2\n`;

  const spliced = spliceRegion(host, `${START}\nNEW BODY\n${END}\n`, "fake.js");
  ok(spliced.includes("NEW BODY"), "spliceRegion: writes the new body");
  ok(!spliced.includes("OLD BODY"), "spliceRegion: removes the old body");
  ok(
    spliced.includes("const before = 1") && spliced.includes("const after = 2"),
    "spliceRegion: preserves the text on BOTH sides of the region",
  );
  // The surrounding bytes must be preserved exactly — a splice that ate or added
  // a newline would show up as a spurious diff on every regeneration.
  eq(
    spliced,
    `const before = 1\n${START}\nNEW BODY\n${END}\nconst after = 2\n`,
    "spliceRegion: result is byte-exact (no newline drift around the region)",
  );

  throwsMatching(
    () => spliceRegion("const x = 1\n", "R\n", "fake.js"),
    /no generated region in fake\.js/,
    "spliceRegion: a file with no region throws (placement is never guessed)",
  );
  throwsMatching(
    () => spliceRegion(`${END}\n${START}\n${END}\n`, "R\n", "fake.js"),
    /end marker precedes start marker/,
    "spliceRegion: an end marker before the start marker throws",
  );
  throwsMatching(
    () => spliceRegion(`${START}\n${END}\n${START}\n${END}\n`, "R\n", "fake.js"),
    /multiple generated regions/,
    "spliceRegion: two regions in one file throw (exactly one is required)",
  );
}
