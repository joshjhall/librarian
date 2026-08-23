# shellcheck shell=bash
# Rust segmenter — check-decomposition detector tests (issue #760 split).
#
# The fn-family seam and `#[cfg(test)]` region exclusion, plus the #727 arms:
# impl clustering by type, full item coverage (macro_rules/unsafe/const/extern/
# static/type), the linear-time impl match (ReDoS guard), and the module-scoped
# mid-file test region.
#
# Sourced by tests/validate-decomposition-detectors.sh, which defines PY / SH /
# REAL_BASH and sources tests/lib/decomposition-sandbox.sh (the emit_rows /
# assert_fires / assert_silent / fresh_dir / list_of drivers) BEFORE this file.
# This fragment only DEFINES test functions; the entry point dispatches them
# from its explicit ordered run_fragment_test list.

# ============================================================================
# Rust segmenter
# ============================================================================
test_seam_rust() {
    local d f list
    d="$(fresh_dir)"
    f="$d/parser.rs"
    command cat >"$f" <<'EOF'
pub fn main_entry(input: &str) -> Result<Doc> {
    let e = parse_entry(input)?;
    Ok(Doc::from(e))
}

pub fn parse_entry(s: &str) -> Result<Entry> {
    Ok(Entry { h: parse_header(s)? })
}

fn parse_header(s: &str) -> Result<Header> {
    let mut out = Header::default();
    for line in s.lines() { out.push(line); }
    Ok(out)
}

fn parse_body(s: &str) -> Result<Body> {
    Ok(Body::default())
}

#[cfg(test)]
mod tests {
    #[test]
    fn t() { assert!(true); }
}
EOF
    list="$(list_of "$f")"

    assert_fires "$list" decomposition-seam "seam 6-20: fn parse_* family (3 units," \
        "rust: parse_* seam span and family"
    assert_fires "$list" decomposition-seam "> $d/parser/parse.rs" \
        "rust: seam proposes a concrete target module"
    # #[cfg(test)] to EOF is excluded — the rule that used to be prose in two agents.
    assert_fires "$list" file-length "5 test-excluded" \
        "rust: #[cfg(test)] region excluded from production LOC"

    # A STANDALONE top-level `#[test]` attribute (no `mod tests` wrapper) is a
    # THIRD, distinct mechanism: the attribute line sets a pending flag that
    # marks the NEXT unit as test code. The fixture above never reaches it —
    # its #[test] sits indented inside a #[cfg(test)] block, which the
    # whole-file region marker already excluded to EOF. Valid Rust, own branch,
    # so it needs its own fixture.
    f="$d/standalone.rs"
    command cat >"$f" <<'EOF'
pub fn main_entry(s: &str) -> String {
    parse_a(s)
}

fn parse_a(s: &str) -> String {
    s.to_string()
}

#[test]
fn helper_one() {
    assert!(true);
}
EOF
    list="$(list_of "$f")"
    assert_fires "$list" file-length "3 test-excluded" \
        "rust: a standalone top-level #[test] attribute excludes the next unit"
    # Control: the two production fns are still counted, so the assertion above
    # cannot pass by the file being excluded wholesale.
    assert_fires "$list" file-length "2 top-level units" \
        "rust: the standalone-#[test] file still counts its production units"
}

# ============================================================================
# Rust segmenter — impl clustering, item coverage (#727)
# ============================================================================
# `impl Trait for Type` captures the TYPE, not the trait. Capturing the trait
# scattered one type across as many families as it had impls, so a type with
# Display + Debug + its inherent impl looked like three unrelated things.
#
# The IMPL-AS-ONE-UNIT decision is asserted here too (see UNIT_RE["rs"] for the
# reasoning): the fixture's impl blocks carry indented methods that must NOT be
# counted, which the unit total pins.
test_rust_impl_clustering() {
    local d f list
    d="$(fresh_dir)"
    f="$d/render.rs"
    command cat >"$f" <<'EOF'
pub struct Widget {
    id: u32,
}

impl Widget {
    pub fn new() -> Self {
        Widget { id: 0 }
    }
    pub fn id(&self) -> u32 {
        self.id
    }
}

impl Display for Widget {
    fn fmt(&self, f: &mut Formatter) -> Result {
        write!(f, "{}", self.id)
    }
}

impl Debug for Widget {
    fn fmt(&self, f: &mut Formatter) -> Result {
        write!(f, "{:?}", self.id)
    }
}
EOF
    list="$(list_of "$f")"

    # All four items are family `widget` — the struct and its three impls. Under
    # the pre-#727 trait capture these were widget/display/debug, so a 4-unit
    # family is only reachable with the type-capturing arm.
    assert_fires "$list" decomposition-seam "fn widget_* family (4 units," \
        "rust: impl Trait for Type clusters under the TYPE, not the trait" \
        DECOMP_SEAM_MIN_UNITS=4
    # impl is ONE unit: the six indented `fn`s inside these blocks are not
    # units. 4 is struct + 3 impls; method-level segmentation would give 10.
    assert_fires "$list" file-length "4 top-level units" \
        "rust: an impl block is one unit — its methods are not segmented"

    # NESTED generic bounds. A `<[^>]*>` generic group stops at the first `>`,
    # so `impl<T: Into<String>> Foo<T>` failed the match outright and the impl
    # went INVISIBLE — the very defect this arm fixes, reappearing on the
    # commonest form of generic impl ([[fix-reintroduces-its-own-failure]]).
    # Every impl below carries a nested bound, so a regression to the
    # single-level class drops the family and this case fails.
    f="$d/generic.rs"
    command cat >"$f" <<'EOF'
impl<T: Into<String>> Gadget<T> {
    pub fn new(v: T) -> Self {
        Gadget { v }
    }
}

impl<T: Iterator<Item = u32>> Display for Gadget<T> {
    fn fmt(&self, f: &mut Formatter) -> Result {
        write!(f, "g")
    }
}

impl<T: A<B<C>>> Debug for Gadget<T> {
    fn fmt(&self, f: &mut Formatter) -> Result {
        write!(f, "d")
    }
}
EOF
    list="$(list_of "$f")"
    assert_fires "$list" decomposition-seam "fn gadget_* family (3 units," \
        "rust: impl with NESTED generic bounds is still segmented, named by type"

    # BORROW MARKERS before the type. `impl Trait for &mut Foo` captured the
    # keyword `mut` — a keyword as the family name and as a god-module
    # "concern" in human-read evidence, the same wrong-finding class
    # RESERVED_UNIT_NAME exists to prevent for Swift. All five impls below
    # belong to one type, so they form a single family only if `&`, `&mut` and
    # `&'a mut` are all consumed.
    f="$d/borrow.rs"
    command cat >"$f" <<'EOF'
impl Display for Holder {
    fn fmt(&self) -> R {
        w()
    }
}

impl Debug for &mut Holder {
    fn fmt(&self) -> R {
        w()
    }
}

impl Clone for &Holder {
    fn clone(&self) -> Self {
        c()
    }
}

impl<'a> Render for &'a mut Holder {
    fn render(&self) -> R {
        r()
    }
}

impl Serialize for dyn Holder {
    fn encode(&self) -> R {
        e()
    }
}

impl Deserialize for &mut dyn Holder {
    fn de(&self) -> R {
        d()
    }
}

impl Convert for crate::inner::Holder {
    fn conv(&self) -> R {
        c()
    }
}

impl Holder {
    pub fn new() -> Self {
        Holder {}
    }
}
EOF
    list="$(list_of "$f")"
    # Eight impls, ONE family. Every marker between `for` and the type must be
    # consumed for that to hold: `&`, `&mut`, `&'a mut`, `dyn`, `&mut dyn`, and
    # a qualified path. Each was captured as the NAME at some point — `mut`,
    # `dyn` and `crate` respectively — which is a keyword as the seam family and
    # as a god-module "concern" in evidence a human reads. A family of 8 is
    # unreachable if any one of them regresses.
    assert_fires "$list" decomposition-seam "fn holder_* family (8 units," \
        "rust: &, mut, dyn and path prefixes are consumed, never captured" \
        DECOMP_SEAM_MIN_UNITS=8
}

# The `Trait for` clause must match in LINEAR time. With `.*[ \t]+for`, a run of
# N spaces after `impl` can be partitioned between `.*` and `[ \t]+` in O(N) ways
# at each of O(N) offsets, and Python's engine tries all of them before failing:
# measured 0.25 s at N=1000, 1.9 s at N=2000, 14.5 s at N=4000 — cubic. That is
# reachable by a stray line of trailing whitespace in any scanned .rs file, not
# only by a crafted one, and these scanners run over arbitrary trees.
#
# A WALL-CLOCK assertion, deliberately: the defect is not a wrong answer that a
# value assertion could catch — both the fast and slow patterns return the same
# (non-)match. Only the time differs. The bound is loose (10s) because CI timing
# is noisy; the fixed pattern does this in well under a second, and the
# regression it guards took 14s at a SMALLER N than the fixture uses.
test_rust_impl_matches_in_linear_time() {
    local d f list rc
    d="$(fresh_dir)"
    f="$d/pathological.rs"
    {
        command printf 'pub fn real_unit() -> u32 {\n    1\n}\n'
        # 8000 spaces after `impl`, then a non-identifier so the match fails.
        command printf 'impl '
        command awk 'BEGIN { for (i = 0; i < 8000; i++) printf " " }'
        command printf '!\n'
    } >"$f"
    list="$(list_of "$f")"

    rc=0
    command timeout 10 /usr/bin/env \
        DECOMP_LOC_WARN=5 DECOMP_LOC_HIGH=400 \
        python3 "$PY" "$list" >/dev/null 2>&1 || rc=$?
    assert_exit 0 "$rc" \
        "rust: a long whitespace run after impl does not blow up the matcher (python)"

    rc=0
    command timeout 10 /usr/bin/env \
        PATTERNS_FORCE_BASH=1 DECOMP_LOC_WARN=5 DECOMP_LOC_HIGH=400 \
        "$REAL_BASH" "$SH" "$list" >/dev/null 2>&1 || rc=$?
    assert_exit 0 "$rc" \
        "rust: the same line does not blow up the awk fallback"
}

# Item kinds the prefix alternation missed entirely before #727. Each was
# INVISIBLE, so it inflated the preceding unit's span and deflated the count.
test_rust_item_coverage() {
    local d f list
    d="$(fresh_dir)"
    f="$d/items.rs"
    command cat >"$f" <<'EOF'
macro_rules! shout {
    ($e:expr) => {
        println!("{}", $e)
    };
}

unsafe fn raw_poke(p: *mut u8) {
    *p = 1;
}

const fn compile_time() -> u32 {
    7
}

extern "C" fn ffi_entry(v: u32) -> u32 {
    v + 1
}

pub const MAX_SIZE: u32 = 512;

static REGISTRY: u32 = 0;

type Handle = u32;

extern crate serde;

pub async fn fetch_it(u: &str) -> String {
    String::from(u)
}
EOF
    list="$(list_of "$f")"
    # Nine items, each previously invisible except the async fn. Any arm that
    # stops matching drops the count below 9. `extern crate` is its own arm:
    # the modifier alternation recognizes `extern` only as a PREFIX to a
    # keyword item, and `crate` is not one, so a bare `extern crate serde;`
    # matched nothing and was absorbed into the preceding unit's span.
    assert_fires "$list" file-length "9 top-level units" \
        "rust: macro_rules/unsafe/const/extern fn, const, static, type all segment"

    # A COUNT alone cannot catch a MISNAMING. An arm that still matches but
    # captures the wrong identifier — `macro_rules!` taking the `!`, or
    # `extern "C" fn` taking `"C"` instead of `ffi_entry` — leaves the count at
    # 8 and a count-only test green (verified by mutation: truncating the
    # macro_rules capture to one character failed zero cases). The seam row is
    # the only output that carries a captured NAME, so the fixture below gives
    # each item kind a shared `item_*` stem: the family name can only form if
    # every arm captured its identifier correctly.
    f="$d/named.rs"
    command cat >"$f" <<'EOF'
macro_rules! item_shout {
    ($e:expr) => {
        println!("{}", $e)
    };
}

unsafe fn item_poke(p: *mut u8) {
    *p = 1;
}

const fn item_compile() -> u32 {
    7
}

extern "C" fn item_ffi(v: u32) -> u32 {
    v + 1
}

static ITEM_REGISTRY: u32 = 0;

type ItemHandle = u32;

extern crate item_serde;

pub struct ItemPlain {
    a: u32,
}

pub enum ItemChoice {
    A,
}

pub trait ItemBehavior {
    fn go(&self);
}

pub union ItemRaw {
    a: u32,
}

mod item_inner {
    pub fn hidden() {}
}

pub(crate) fn item_scoped() -> u32 {
    1
}

pub(in crate::deep) fn item_restricted() -> u32 {
    2
}
EOF
    list="$(list_of "$f")"
    # Twelve units share the `item` family only if each arm captured the real
    # identifier. Under the mutation above the macro contributes `i`, the
    # family drops to 11, and this assertion fails. `extern crate` is included
    # because its name is the arm most easily captured as the literal `crate`;
    # struct/enum/trait/union/mod cover the bare-keyword alternative, whose
    # capture group was renumbered by this issue's rewrite and which no other
    # fixture exercised as a standalone top-level header.
    # Fourteen units, one family. The last two are visibility forms:
    # `pub(crate)` always worked, but `pub(in crate::deep)` made the whole
    # modifier alternative fail and the item went INVISIBLE — this issue's own
    # defect class, so the pair is here rather than only the broken one.
    assert_fires "$list" decomposition-seam "fn item_* family (14 units," \
        "rust: every item arm captures its real identifier, not a stray token" \
        DECOMP_SEAM_MIN_UNITS=14
}

# The #[cfg(test)] region had TWO independent defects (#727), fixtured
# separately because they fail through different code paths.
test_rust_midfile_test_region() {
    local d f list
    d="$(fresh_dir)"

    # (1) A mid-file marker excluded to EOF, swallowing every production unit
    # that followed. Here `beta` and `gamma` sit AFTER the test module.
    f="$d/midfile.rs"
    command cat >"$f" <<'EOF'
pub fn alpha() -> u32 {
    1
}

#[cfg(test)]
mod tests {
    #[test]
    fn t_one() {
        assert!(true);
    }
}

pub fn beta() -> u32 {
    2
}

pub fn gamma() -> u32 {
    3
}
EOF
    list="$(list_of "$f")"
    # Only the test module is excluded (lines 5-12, its span), not the 7 lines
    # after it. Pre-fix this read 15 — the marker to EOF.
    assert_fires "$list" file-length "8 test-excluded" \
        "rust: a mid-file #[cfg(test)] excludes only its own module, not to EOF"
    # The three production fns all survive. Pre-fix this read 1.
    assert_fires "$list" file-length "3 top-level units" \
        "rust: production units after a mid-file test module are still counted"

    # (2) An INDENTED #[test] inside `mod tests` set the pending-test flag,
    # which then marked the next TOP-LEVEL unit as test code. Distinct from (1):
    # this one mis-marks a UNIT rather than over-extending the region. The
    # fixture uses #[cfg(test)] on the module (so the region rule is in play)
    # and asserts the following production fn is not swallowed.
    f="$d/pending.rs"
    command cat >"$f" <<'EOF'
#[cfg(test)]
mod tests {
    #[test]
    fn inner_one() {}
    #[test]
    fn inner_two() {}
}

pub fn survivor() -> u32 {
    41
}

pub fn survivor_two() -> u32 {
    42
}
EOF
    list="$(list_of "$f")"
    assert_fires "$list" file-length "2 top-level units" \
        "rust: an indented #[test] does not mark the next top-level unit as test"

    # (3) A NESTED `#[cfg(test)] mod tests` — indented inside an outer `mod` —
    # must not engage the whole-file REGION path at all. The marker is not a
    # unit header (units are column-zero anchored), so the bounded stop from (1)
    # could not find the module it introduces and latched onto whatever
    # top-level unit followed, excluding everything in between: 11 of 16 lines
    # and a production fn swallowed whole. Distinct from (2), which mis-marks a
    # UNIT via the attribute flag; this one mis-sizes a REGION. A nested test
    # module is already excluded per-unit through its enclosing unit's span.
    f="$d/nested.rs"
    command cat >"$f" <<'EOF'
mod outer {
    #[cfg(test)]
    mod tests {
        #[test]
        fn t() {}
    }
}

pub fn after_a() -> u32 {
    1
}

pub fn after_b() -> u32 {
    2
}
EOF
    list="$(list_of "$f")"
    # Nothing is region-excluded: the only marker is indented. All three
    # top-level units survive. Pre-fix this read 11 test-excluded and dropped
    # after_a entirely.
    assert_fires "$list" file-length "0 test-excluded" \
        "rust: a NESTED #[cfg(test)] does not open a whole-file test region"
    assert_fires "$list" file-length "3 top-level units" \
        "rust: production units after a nested test module are still counted"
}
