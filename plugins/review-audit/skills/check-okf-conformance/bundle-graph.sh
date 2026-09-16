#!/usr/bin/env bash
# bundle-graph.sh — slice B: bundle graph + health (#669).
#
# SOURCED, NOT EXECUTED. It is a fragment of patterns.sh, sourced by it, exactly
# as bundle_graph.py is imported by patterns.py. Running it standalone does
# nothing useful — it defines functions that read globals (`$TAB`, `$_here`) and
# call helpers (`emit`) its parent owns. It carries a shebang and the executable
# bit anyway, matching plugins/workflow/scripts/golem-status-signals.sh: the
# repo's bundled-script gates (tests/lint-skills-agents.sh) require both of every
# `.sh` under plugins/, and a sourced fragment is not exempt.
#
# WHY IT IS A SEPARATE FILE (#991). The python twin has always been split this
# way (patterns.py:58-66 seeds sys.path and imports this file's counterpart), so
# extracting the bash half restores symmetry rather than inventing a boundary —
# and it takes patterns.sh back under its production-LOC budget. The seam is the
# one the two runtimes already agree on: everything here is slice B, everything
# there is slice A plus the drive loop.
#
# THE SEAM IS BIDIRECTIONAL, which is why this is a sourced fragment and not a
# standalone tool. This file consumes `emit` and `$TAB` from patterns.sh, while
# patterns.sh's drive loop calls back into `read_index_names`, `is_index` and
# `scan_bundle` defined here. A module system would express that as two imports;
# bash expresses it as one source at the right point in the file.
#
# bash-3.2 clean and BSD-regex safe, same as its parent — no declare -A /
# mapfile / namerefs / ${v,,} / ;;&, no \s \w \b, no grep -P.
# See CLAUDE.md § Runtime policy.
#
# Mirrors bundle_graph.py function-for-function. Read that file's module
# docstring for the design: the pass enumerates the bundle ROOT rather than the
# file list, because an orphan is "no index names this concept" and the index is
# usually not in the same diff as the concept.
#
# Categories and evidence labels — ONE literal each, byte-identical to the C_*/
# L_* constants in bundle_graph.py.
C_ORPHAN="memory-orphan"
C_DANGLING_INDEX="memory-dangling-index"
C_MULTI_INDEX="memory-multi-index"
C_STALE="memory-stale"
C_MISSING_WHY="memory-missing-why"

L_ORPHAN="Concept is named by no index"
L_DANGLING="Index names a file that does not exist"
L_MULTI="Concept is named by more than one index"
L_STALE_DATE="Memory is past its stale_after date"
L_STALE_DEPRECATED="Memory is marked status: deprecated"
L_MISSING_WHY="Body is missing a section required for this type"

DEFAULT_INDEX_NAMES="MEMORY.md index.md index-*.md"

# read_config_list FILE KEY — the `- item` list under `health.<KEY>`, one per
# line. Mirrors read_config_list() in bundle_graph.py, including the
# absent-vs-empty distinction: an ABSENT key prints nothing and returns 1, an
# empty one prints nothing and returns 0, so a caller can tell "use the default"
# from "the operator configured none". Collapsing them would make a rule
# impossible to turn off.
read_config_list() {
    local file="$1" key="$2" line stripped first in_health=0 in_key=0 found=1 item
    [ -f "$file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        stripped="${line#"${line%%[![:space:]]*}"}"
        stripped="${stripped%"${stripped##*[![:space:]]}"}"
        [ -n "$stripped" ] || continue
        case "$stripped" in '#'*) continue ;; esac
        first="${line%"${line#?}"}"
        case "$first" in
            ' ' | "$TAB") ;;
            *)
                # A column-0 line opens or closes `health:`, and always ends any
                # key block within it.
                case "$stripped" in
                    health:*) in_health=1 ;;
                    *) in_health=0 ;;
                esac
                in_key=0
                continue
                ;;
        esac
        [ "$in_health" -eq 1 ] || continue
        case "$stripped" in
            '- '*)
                if [ "$in_key" -eq 1 ]; then
                    item="${stripped#- }"
                    # Strip an inline comment, then one layer of quotes.
                    case "$item" in *' #'*) item="${item%% #*}" ;; esac
                    item="${item#"${item%%[![:space:]]*}"}"
                    item="${item%"${item##*[![:space:]]}"}"
                    item="${item#\"}"
                    item="${item%\"}"
                    item="${item#\'}"
                    item="${item%\'}"
                    command printf '%s\n' "$item"
                fi
                continue
                ;;
        esac
        case "$stripped" in
            "$key":*)
                in_key=1
                found=0
                ;;
            *) in_key=0 ;;
        esac
    done <"$file"
    return "$found"
}

# read_index_names — $OKF_INDEX_NAMES -> thresholds.yml -> built-in default.
# An explicitly EMPTY env override means "no indexes configured", distinct from
# unset, matching the python twin.
read_index_names() {
    local from_config
    if [ -n "${OKF_INDEX_NAMES+set}" ]; then
        command printf '%s' "$OKF_INDEX_NAMES"
        return 0
    fi
    # shellcheck disable=SC2154  # $_here is patterns.sh's, set at its :40 before this file is sourced
    if from_config="$(read_config_list "$_here/thresholds.yml" index_names)"; then
        command printf '%s' "$(command printf '%s' "$from_config" | command tr '\n' ' ')"
        return 0
    fi
    command printf '%s' "$DEFAULT_INDEX_NAMES"
}

# is_index BASENAME NAMES — true when BASENAME routes recall. Mirrors
# is_index() in bundle_graph.py, including the two-pass order.
#
# LITERAL EQUALITY FIRST, for every name, before any glob interpretation: a
# configured name is operator input rather than a pattern language they opted
# into. Checking metacharacters first makes `notes[1].md` a character class that
# does not match the file literally called `notes[1].md`, so the repo's only
# index is classified as a concept and every memory in the bundle is reported as
# an orphan. Both impls did this identically, so parity held while both were
# wrong — see the python twin for the measurement.
is_index() {
    local base="$1" names="$2" n
    for n in $names; do
        [ "$base" = "$n" ] && return 0
    done
    for n in $names; do
        case "$n" in
            *'*'* | *'?'* | *'['*)
                # shellcheck disable=SC2254 # intentional: a configured glob.
                case "$base" in
                    $n) return 0 ;;
                esac
                ;;
        esac
    done
    return 1
}

# index_targets FILE — `<basename>.md<TAB><line>` for every concept an index
# line points at. Markdown link targets first, else bare mentions on that line,
# mirroring the python twin's two regexes. Only the basename is kept.
index_targets() {
    command awk '
        {
            n = 0
            s = $0
            while (match(s, /\]\([^)]*\.md\)/)) {
                t = substr(s, RSTART + 2, RLENGTH - 3)
                # A `<dir>/index.md` target keeps its directory — it names a §8
                # SUB-INDEX, and collapsing it to `index.md` like any other
                # target made every sub-index read as dangling (#934).
                sub(/^\//, "", t)
                sub(/^\.\//, "", t)
                if (t ~ /^[^\/]+\/index\.md$/) {
                    print t "\t" NR
                    n++
                    s = substr(s, RSTART + RLENGTH)
                    continue
                }
                sub(/^.*\//, "", t)
                print t "\t" NR
                n++
                s = substr(s, RSTART + RLENGTH)
            }
            if (n == 0) {
                s = $0
                while (match(s, /[A-Za-z0-9._-]+\.md/)) {
                    t = substr(s, RSTART, RLENGTH)
                    pre = (RSTART > 1) ? substr(s, RSTART - 1, 1) : ""
                    s = substr(s, RSTART + RLENGTH)
                    # Mirror the python negative lookbehind: a target preceded
                    # by (, a word char, / or - was part of a link or path we
                    # already handled.
                    if (pre ~ /[(A-Za-z0-9_\/-]/) continue
                    sub(/^.*\//, "", t)
                    print t "\t" NR
                }
            }
        }
    ' "$1"
}

# fm_get FILE NAME — a frontmatter value by bare name: TOP LEVEL, or under a
# top-level block literally named `metadata:`. Mirrors frontmatter_fields()+
# field() in the python twin, whose dict holds top-level keys plus `metadata.*`
# flattened, and whose field() looks up only those two spellings.
#
# DEPTH IS NOT LIMITED, and saying so is deliberate. `parent` is reset only by a
# top-level line, so ANY depth under an open `metadata:` block resolves —
# `metadata:` / `sub:` / `status: deprecated` yields `deprecated`. The python
# twin does exactly the same (its `prefix` is likewise touched only by
# non-indented lines), so this is parity, not a bash quirk. An earlier draft of
# this comment claimed "exactly one level"; the code never enforced that, and a
# maintainer who "fixed" the code to match would have BROKEN parity rather than
# restored it (#669 review cycle 2). Pinned by a two-level fixture in
# tests/validate-okf-detectors.sh.
#
# THE SCOPING IS THE POINT, and an earlier version of this function had the
# comment without the code: it stripped indentation from every line and returned
# the first bare-key match at ANY depth under ANY parent. Three divergences from
# the python twin, all reproduced (#669 review cycle 1):
#
#   * `some_other_block:` / `status: deprecated` — bash fired memory-stale on a
#     file python considered clean.
#   * `nested:` / `deeper:` / `stale_after: …` — same, at arbitrary depth.
#   * a nested `type:` appearing BEFORE the real top-level one — bash returned
#     the nested value, so a document legitimately declaring `type: feedback`
#     was reported okf-missing-type and never got its body-requirement check.
#
# That is a live production path (PATTERNS_FORCE_BASH, and any host without
# python3.11+), not just a parity-gate concern: a producer's own structured data
# under an unrelated key would silently mis-scan.
#
# Tracks the current top-level parent the way the python twin tracks `prefix`,
# and matches an indented line only while that parent is `metadata`.
fm_get() {
    command awk -v want="$2" '
        NR == 1 && $0 != "---" { exit }
        NR == 1 { next }
        $0 == "---" { exit }
        {
            raw = $0
            line = raw
            sub(/^[ \t]+/, "", line)
            if (line == "" || substr(line, 1, 1) == "#") next
            # Indented iff the raw line began with whitespace.
            indented = (raw ~ /^[ \t]/)
            p = index(line, ":")
            if (p == 0) next
            k = substr(line, 1, p - 1)
            v = substr(line, p + 1)
            gsub(/^[ \t]+|[ \t]+$/, "", k)
            gsub(/^[ \t]+|[ \t]+$/, "", v)
            gsub(/^["'"'"']|["'"'"']$/, "", v)
            if (!indented) {
                # A top-level key with no value OPENS a block; one with a value
                # closes any open block, mirroring the python twin, where
                # `prefix` is set only for a valueless top-level key.
                parent = (v == "") ? k : ""
                if (k == want && v != "") { print v; exit }
                next
            }
            # Indented: visible only while the open block is `metadata:`. Depth
            # is NOT limited — `parent` survives until the next top-level line,
            # so a key two levels down still resolves, matching the python twin.
            if (parent == "metadata" && k == want && v != "") { print v; exit }
        }
    ' "$1"
}

# okf_today — the date staleness is judged against. INJECTED via $OKF_TODAY so a
# fixture cannot rot into a false pass (#669 AC); production falls back to the
# real date.
okf_today() {
    local env_val="${OKF_TODAY:-}"
    env_val="${env_val#"${env_val%%[![:space:]]*}"}"
    env_val="${env_val%"${env_val##*[![:space:]]}"}"
    if [ -n "$env_val" ]; then
        command printf '%s' "$env_val"
    else
        command date +%Y-%m-%d
    fi
}

# scan_bundle ROOT — the whole-bundle pass.
#
# THE ROOT LEVEL ONLY, not a recursive walk — the same deliberate scope limit
# the python twin documents: OKF §8 gives each directory its own index.md, so
# judging a concept in sub/ against the ROOT index would report an orphan for
# every correctly-nested file.
scan_bundle() {
    local root="$1" f base names now
    [ -n "$root" ] || return 0
    [ -d "$root" ] || return 0
    names="$(read_index_names)"
    now="$(okf_today)"

    # Partition the bundle root into indexes and concepts. A reserved non-index
    # file (log.md) is NEITHER: §9 makes it a changelog, and calling it an
    # orphan would fire on every conformant bundle in existence.
    local indexes="" concepts=""
    for f in "$root"/*.md; do
        [ -f "$f" ] || continue
        # THE ROOT LEVEL NEEDS THE SAME SYMLINK GUARD AS THE SUBDIRECTORIES
        # below. `[ -f ]` FOLLOWS a symlink, so `leaked.md -> /outside/x.md` was
        # admitted as a concept and then READ — and the health checks echo a
        # memory's own `stale_check` into their evidence, so off-root content was
        # disclosed in the report. Measured in BOTH runtimes: a sentinel string
        # in an outside file appeared verbatim in a memory-stale row.
        [ -L "$f" ] && continue
        base="${f##*/}"
        if is_index "$base" "$names"; then
            indexes="${indexes}${base}
"
        else
            case "$base" in
                index.md | log.md) continue ;;
            esac
            concepts="${concepts}${base}
"
        fi
    done

    # named = "<target>\t<index>\t<line>" rows. bash-3.2 has no associative
    # arrays (tests/lint-shell-portability.sh bans `declare -A`), so the graph is
    # accumulated as newline-delimited text and queried with grep/case — the
    # idiom the portability gate documents.
    local named="" idx targets target line_no seen_here
    while IFS= read -r idx; do
        [ -n "$idx" ] || continue
        seen_here=""
        targets="$(index_targets "$root/$idx")"
        while IFS="$TAB" read -r target line_no; do
            [ -n "$target" ] || continue
            # One index naming a concept twice is a duplicate LINE, not a
            # multi-index — that category is about two DIFFERENT indexes.
            case "$seen_here" in
                *"|$target|"*) continue ;;
            esac
            seen_here="${seen_here}|$target|"
            named="${named}${target}${TAB}${idx}${TAB}${line_no}
"
        done <<EOF
$targets
EOF
    done <<EOF
$indexes
EOF

    # Dangling + multi-index, walking each distinct target once in first-seen
    # order (the python twin sorts; both emit one row per target).
    local seen_targets="" sites n first_idx first_line where
    while IFS="$TAB" read -r target idx line_no; do
        [ -n "$target" ] || continue
        case "$seen_targets" in
            *"|$target|"*) continue ;;
        esac
        seen_targets="${seen_targets}|$target|"
        # A `<dir>/index.md` target is a §8 SUB-INDEX: present iff the file
        # exists. It is not a concept and must never be judged as one.
        case "$target" in
            */index.md)
                # PRESENT MEANS "a real file we will actually walk": a SYMLINKED
                # sub-index is skipped by the directory walk, so counting it
                # present would leave its directory silently unchecked while no
                # dangling row fired either.
                if [ ! -f "$root/$target" ] || [ -L "$root/$target" ]; then
                    # ENVIRON, NEVER `awk -v`: a `-v` assignment is
                    # escape-processed, so a target containing the two
                    # characters `\n` decodes and stops matching the literal
                    # field — the row still fires, but with an EMPTY index name
                    # and line number, which is a finding nobody can act on.
                    # Same rule moves.sh follows; these two sites were added by
                    # the very commit that fixed the class elsewhere.
                    first_idx="$(command printf '%s' "$named" | OKF_T="$target" command awk -F"$TAB" '$1 == ENVIRON["OKF_T"] { print $2; exit }')"
                    first_line="$(command printf '%s' "$named" | OKF_T="$target" command awk -F"$TAB" '$1 == ENVIRON["OKF_T"] { print $3; exit }')"
                    emit "$root/$first_idx" "$first_line" "$C_DANGLING_INDEX" \
                        "Index names a subdirectory index that does not exist: $target" "HIGH"
                fi
                continue
                ;;
        esac
        # An index pointing at another INDEX is ordinary structure (a root index
        # naming its sub-indexes), so it is neither dangling nor multi-indexed.
        case "
$indexes" in
            *"
$target
"*) continue ;;
        esac
        # ENVIRON here too: pre-existing, but this diff's index_targets change
        # widened what shapes `$target` can take (a `<dir>/index.md` now keeps
        # its slash), so the exposure grew with it.
        sites="$(command printf '%s' "$named" | OKF_T="$target" command awk -F"$TAB" '$1 == ENVIRON["OKF_T"] { print $2 "\t" $3 }')"
        first_idx="$(command printf '%s\n' "$sites" | command head -1 | command cut -f1)"
        first_line="$(command printf '%s\n' "$sites" | command head -1 | command cut -f2)"
        case "
$concepts" in
            *"
$target
"*) ;;
            *)
                emit "$root/$first_idx" "$first_line" "$C_DANGLING_INDEX" \
                    "$L_DANGLING: $target" "HIGH"
                continue
                ;;
        esac
        n="$(command printf '%s\n' "$sites" | command grep -c .)"
        if [ "$n" -gt 1 ]; then
            where="$(command printf '%s\n' "$sites" | command cut -f1 | command tr '\n' ',' | command sed 's/,$//; s/,/, /g')"
            emit "$root/$target" 1 "$C_MULTI_INDEX" "$L_MULTI: $where" "HIGH"
        fi
    done <<EOF
$named
EOF

    # Orphans. A BUNDLE WITH NO INDEX HAS NO ORPHANS — §11 forbids rejecting a
    # bundle for missing index.md files, so a bundle that does not route through
    # indexes must not have every concept reported. Guarded here rather than by
    # an early return, because the health rules below are per-file and hold
    # whether or not the bundle indexes anything. Mirrors the python twin.
    if [ -n "$indexes" ]; then
        while IFS= read -r base; do
            [ -n "$base" ] || continue
            case "
$named" in
                *"
$base$TAB"*) continue ;;
            esac
            emit "$root/$base" 1 "$C_ORPHAN" "$L_ORPHAN" "HIGH"
        done <<EOF
$concepts
EOF
    fi

    # Each SUBDIRECTORY against its own index.md (§8). ONE LEVEL PER INDEX: a
    # directory's index routes that directory's concepts exactly as the root
    # index routes the root's, so this is the same rule at two levels rather
    # than a special case.
    #
    # A DIRECTORY WITHOUT AN index.md IS SKIPPED ENTIRELY. §8 makes the directory
    # index the routing mechanism, so a directory that has not adopted one has
    # nothing to be judged against; reporting there would fire on every repo
    # keeping unrelated markdown beside its bundle.
    local sub sub_dir sub_index sub_named sub_concepts sub_base sub_targets
    local nested_concepts=""
    # SYMLINKED DIRECTORIES ARE SKIPPED — a SAFETY boundary, not tidiness, and
    # the same line okf-migrate's collect_bundle draws on the write side: this
    # toolset runs against SOMEONE ELSE'S bundle. The `*/` glob form FOLLOWS a
    # symlink, so `evil -> /somewhere/else` was descended and its files reported
    # under the bundle's name. Measured in BOTH runtimes before fixing.
    for sub_dir in "$root"/*/; do
        [ -d "$sub_dir" ] || continue
        [ -L "${sub_dir%/}" ] && continue
        sub="${sub_dir%/}"
        sub="${sub##*/}"
        case "$sub" in .*) continue ;; esac
        sub_index="$root/$sub/index.md"
        [ -f "$sub_index" ] || continue
        [ -L "$sub_index" ] && continue

        sub_named=""
        sub_targets="$(index_targets "$sub_index")"
        while IFS="$TAB" read -r target line_no; do
            [ -n "$target" ] || continue
            target="${target##*/}"
            case "$sub_named" in
                *"
$target$TAB"*) continue ;;
            esac
            sub_named="${sub_named}
${target}${TAB}${line_no}"
        done <<EOF
$sub_targets
EOF

        sub_concepts=""
        for sub_base in "$root/$sub"/*.md; do
            [ -f "$sub_base" ] || continue
            # A symlinked .md is skipped too: it would be read and reported under
            # its in-bundle name while its bytes came from outside.
            [ -L "$sub_base" ] && continue
            sub_base="${sub_base##*/}"
            case "$sub_base" in index.md | log.md) continue ;; esac
            sub_concepts="${sub_concepts}${sub_base}
"
        done

        while IFS="$TAB" read -r target line_no; do
            [ -n "$target" ] || continue
            case "$target" in index.md) continue ;; esac
            case "
$sub_concepts" in
                *"
$target
"*) continue ;;
            esac
            emit "$sub_index" "$line_no" "$C_DANGLING_INDEX" \
                "$L_DANGLING: $target" "HIGH"
        done <<EOF
$(command printf '%s' "$sub_named")
EOF

        while IFS= read -r sub_base; do
            [ -n "$sub_base" ] || continue
            # Collected for the HEALTH pass below, which walks root concepts AND
            # these — see its own note.
            nested_concepts="${nested_concepts}${sub}/${sub_base}
"
            case "$sub_named" in
                *"
$sub_base$TAB"*) continue ;;
            esac
            emit "$root/$sub/$sub_base" 1 "$C_ORPHAN" "$L_ORPHAN" "HIGH"
        done <<EOF
$sub_concepts
EOF
    done

    # Health: staleness and per-type body requirements.
    #
    # ROOT CONCEPTS **AND** NESTED ONES. Staleness and body requirements are
    # properties of a memory's own text — nothing about them is root-specific —
    # so walking only the root meant a concept STOPPED being health-checked the
    # moment it was filed into a directory. Measured on this repo's own bundle
    # with a mirror taxonomy: 80 known memory-missing-why rows became 1, and the
    # scan still exited 0 — a migration silencing 79 real findings while
    # reporting success, which would have read as the migration FIXING them.
    #
    # Nested concepts come only from directories that HAVE an index.md, because
    # the walk above skips the others entirely; that boundary is deliberate.
    #
    # The config is read ONCE, outside the per-file loop. Reading it inside meant
    # re-parsing thresholds.yml for every concept — 222 redundant parses on this
    # repo's own bundle, for a file that cannot change mid-scan.
    local status stale_after stale_check ftype reqs spec sections sec missing ev
    reqs="$(read_config_list "$_here/thresholds.yml" body_requirements || true)"
    while IFS= read -r base; do
        [ -n "$base" ] || continue
        f="$root/$base"
        status="$(fm_get "$f" status)"
        stale_after="$(fm_get "$f" stale_after)"
        stale_check="$(fm_get "$f" stale_check)"
        if [ "$status" = "deprecated" ]; then
            emit "$f" 1 "$C_STALE" "$L_STALE_DEPRECATED" "MEDIUM"
        elif command grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' <<<"$stale_after" &&
            [ "$stale_after" \< "$now" ]; then
            # QUOTE THE MEMORY'S OWN stale_check (#669) — that field names the
            # sentence to re-verify, so it beats "may be out of date".
            ev="$L_STALE_DATE ($stale_after)"
            [ -n "$stale_check" ] && ev="$ev: $stale_check"
            emit "$f" 1 "$C_STALE" "$ev" "MEDIUM"
        fi

        ftype="$(fm_get "$f" type)"
        [ -n "$ftype" ] || continue
        missing=""
        while IFS= read -r spec; do
            [ -n "$spec" ] || continue
            case "$spec" in *'='*) ;; *) continue ;; esac
            sections="${spec#*=}"
            spec="${spec%%=*}"
            spec="${spec#"${spec%%[![:space:]]*}"}"
            spec="${spec%"${spec##*[![:space:]]}"}"
            [ "$spec" = "$ftype" ] || continue
            # Sections are `|`-separated; IFS splitting on | is bash-3.2 clean.
            local old_ifs="$IFS"
            IFS='|'
            for sec in $sections; do
                sec="${sec#"${sec%%[![:space:]]*}"}"
                sec="${sec%"${sec##*[![:space:]]}"}"
                [ -n "$sec" ] || continue
                command grep -qF -- "$sec" "$f" && continue
                if [ -z "$missing" ]; then
                    missing="$sec"
                else
                    missing="$missing, $sec"
                fi
            done
            IFS="$old_ifs"
        done <<EOF
$reqs
EOF
        if [ -n "$missing" ]; then
            emit "$f" 1 "$C_MISSING_WHY" "$L_MISSING_WHY: $missing" "MEDIUM"
        fi
    done <<EOF
$concepts$nested_concepts
EOF
}
