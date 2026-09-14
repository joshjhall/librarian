# shellcheck shell=bash
# okf-migrate — the move-concept transform, bash fallback (issue #934, slice J).
#
# Sourced by migrate.sh, never executed. The bash twin of moves.py: the two must
# agree on output BYTE FOR BYTE, which is the language boundary CLAUDE.md
# § Runtime policy defines and tests/okf-migrate/60-parity.sh pins.
#
# Split into its own file for the same reason moves.py is: transforms.sh is the
# bash twin of transforms.py, and a transform that lives in one file on the
# python side and a different one on the bash side makes the parity contract
# harder to check by eye than it needs to be.
#
# WHAT THIS TRANSFORM IS FOR. OKF concept IDs are the bundle path minus `.md`
# (§3), so nesting is native to the format and a flat bundle throws away the one
# addressing mechanism OKF provides. Moving a file is trivial; rewriting every
# INBOUND link and every INDEX POINTER to follow it is not, and is what nobody
# does correctly by hand across 225 files.
#
# THE INDEX POINTER IS THE WHOLE RISK. A memory's index line is the only thing
# that makes it recallable, so a move that leaves the pointer behind breaks
# nothing visibly — the file still exists, the bundle still passes a file-level
# check, and the memory is simply never found again (#632's recorded shape).
#
# bash-3.2 clean and BSD-regex safe: no declare -A / mapfile / namerefs /
# ${v,,} / ;;&, and no \s \w \b or grep -P. Association is done with sorted
# TAB-delimited temp files, which is what bash 3.2 has instead of a hash.

# --- link scanning -----------------------------------------------------------

# normalize_rel PATH — collapse `a/../b` and `./` to a plain relative path.
#
# The python twin gets this from os.path.normpath. Written out here because BSD
# has no portable equivalent (`realpath` is GNU-only for the `-m` form this would
# need, and a non-existent path must still normalize — the whole point is
# resolving a link target that may not exist yet).
normalize_rel() {
    local p="$1" out="" seg rest
    case "$p" in /*) out="" ;; esac
    rest="$p"
    while [ -n "$rest" ]; do
        seg="${rest%%/*}"
        if [ "$seg" = "$rest" ]; then
            rest=""
        else
            rest="${rest#*/}"
        fi
        case "$seg" in
            "" | ".") continue ;;
            "..")
                case "$out" in
                    "" | "..") out="${out:+$out/}.." ;;
                    */*) out="${out%/*}" ;;
                    *) out="" ;;
                esac
                ;;
            *) out="${out:+$out/}$seg" ;;
        esac
    done
    command printf '%s' "$out"
}

# scan_links LINE — print one `label<TAB>target` row per markdown link on LINE.
#
# The shared link parser for both passes below, so the two cannot disagree about
# what a link IS. Pure parameter expansion rather than sed: BSD sed has no
# non-greedy quantifier, and a greedy `\(.*\)` swallows every link on a line but
# the last — silently dropping the first of two, which is precisely the
# two-inbound-links case AC3 exists to pin.
scan_links() {
    local rest="$1" label target
    while :; do
        case "$rest" in *'['*']('*')'*) ;; *) break ;; esac
        rest="${rest#*[}"
        label="${rest%%]*}"
        case "$rest" in *']('*) ;; *) break ;; esac
        # A `]` that is not followed by `(` is not a link; skip past this `[`.
        case "$label" in *']'*) continue ;; esac
        rest="${rest#*](}"
        target="${rest%%)*}"
        case "$rest" in *')'*) rest="${rest#*)}" ;; *) rest="" ;; esac
        command printf '%s\t%s\n' "$label" "$target"
    done
}

# --- index membership --------------------------------------------------------

# index_members ROOT FILE_LIST — print `concept_rel<TAB>index_rel` rows.
#
# ALL NAMING INDEXES, NOT THE FIRST. A concept listed in both a root MEMORY.md
# and a topic index is ordinary, and picking one by path sort would decide the
# destination by an alphabetical accident: measured on this transform's first
# fixture, `MEMORY.md` sorted ahead of `index-golem.md` and an
# `index:index-golem.md` rule silently matched nothing. Emitting every index
# lets RULE ORDER arbitrate, which is the first-match-wins semantics the rest of
# this grammar already has — stated by the operator, not by the filesystem.
index_members() {
    local root="$1" list="$2" path base rel_index here line label target resolved
    while IFS= read -r path || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        base="${path##*/}"
        case "$base" in
            MEMORY.md | index*) ;;
            *) continue ;;
        esac
        rel_index="${path#"$root"/}"
        here="${path%/*}"
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in *']('*) ;; *) continue ;; esac
            while IFS="$(command printf '\t')" read -r label target || [ -n "$label" ]; do
                [ -n "$target" ] || continue
                case "$target" in
                    *.md) ;;
                    *) continue ;;
                esac
                case "$target" in *://*) continue ;; esac
                if [ "${target#/}" != "$target" ]; then
                    resolved="$(normalize_rel "${target#/}")"
                elif [ "$here" = "$root" ]; then
                    resolved="$(normalize_rel "$target")"
                else
                    resolved="$(normalize_rel "${here#"$root"/}/$target")"
                fi
                command printf '%s\t%s\n' "$resolved" "$rel_index"
            done <<EOF
$(scan_links "$line")
EOF
        done <"$path"
    done <"$list" | command sort -u
}

# --- destination resolution --------------------------------------------------

# resolve_destination REL RULES_FILE MEMBERS_FILE — the target directory, or
# empty when no rule matches.
#
# Ordered, first-match-wins — the same determinism rule infer_type holds, for the
# same reason: two runtimes must reach the same answer.
#
# A file matching NO rule STAYS PUT, which is why this transform needs no
# ambiguity channel: not matching is a complete answer ("not part of the
# taxonomy"), unlike backfill-type where it leaves a required key unfilled.
resolve_destination() {
    local rel="$1" rules="$2" members="$3"
    local base dir rule source pattern target idx_rel idx_base
    base="${rel##*/}"
    case "$rel" in
        */*) dir="${rel%/*}" ;;
        *) dir="" ;;
    esac

    while IFS= read -r rule || [ -n "$rule" ]; do
        [ -n "$rule" ] || continue
        case "$rule" in *=*) ;; *) continue ;; esac
        source="${rule%%=*}"
        target="${rule#*=}"
        source="${source%"${source##*[![:space:]]}"}"
        target="${target#"${target%%[![:space:]]*}"}"
        target="${target%"${target##*[![:space:]]}"}"
        target="${target%/}"
        [ -n "$target" ] || continue
        case "$source" in *:*) ;; *) continue ;; esac
        pattern="${source#*:}"
        source="${source%%:*}"

        case "$source" in
            index)
                while IFS="$(command printf '\t')" read -r _c idx_rel || [ -n "$_c" ]; do
                    [ "$_c" = "$rel" ] || continue
                    idx_base="${idx_rel##*/}"
                    # shellcheck disable=SC2254  # pattern is config, glob intended
                    case "$idx_base" in $pattern)
                        command printf '%s' "$target"
                        return 0
                        ;;
                    esac
                done <"$members"
                ;;
            file)
                # shellcheck disable=SC2254
                case "$base" in $pattern)
                    command printf '%s' "$target"
                    return 0
                    ;;
                esac
                ;;
            dir)
                [ -n "$dir" ] || continue
                # shellcheck disable=SC2254
                case "$dir/" in $pattern)
                    command printf '%s' "$target"
                    return 0
                    ;;
                esac
                # shellcheck disable=SC2254
                case "$dir" in $pattern)
                    command printf '%s' "$target"
                    return 0
                    ;;
                esac
                ;;
        esac
    done <"$rules"
    return 0
}

# --- plan_moves --------------------------------------------------------------

# plan_moves ROOT CONCEPT_LIST FILE_LIST RULES_FILE MAPPING_OUT
#
# Emits move edit records on stdout AND writes `old_rel<TAB>new_rel` rows to
# MAPPING_OUT, which rewrite_inbound_links consumes. One mapping, two consumers:
# recomputing it in the rewriter would be a second chance to disagree with this.
#
# NO RULES MEANS NO MOVES, silently. An unconfigured repo — every repo on the day
# it installs this — must get "nothing to move" rather than a taxonomy the engine
# invented (AC10).
#
# IDEMPOTENT BY CONSTRUCTION: a file already at its destination emits no edit, so
# a second run against the tool's own output plans nothing (AC5).
plan_moves() {
    local root="$1" concepts="$2" every="$3" rules="$4" mapping="$5"
    local members taken path rel target_dir new_rel
    : >"$mapping"
    [ -s "$rules" ] || return 0

    members="$(command mktemp)"
    taken="$(command mktemp)"
    index_members "$root" "$every" >"$members"
    # Every existing concept occupies its own path; a move into one would
    # overwrite it. Seeded here so the collision check below is one lookup.
    while IFS= read -r path || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        command printf '%s\n' "${path#"$root"/}" >>"$taken"
    done <"$concepts"

    while IFS= read -r path || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        rel="${path#"$root"/}"
        target_dir="$(resolve_destination "$rel" "$rules" "$members")"
        [ -n "$target_dir" ] || continue
        new_rel="$target_dir/${rel##*/}"
        [ "$new_rel" != "$rel" ] || continue
        # A DESTINATION COLLISION IS SKIPPED, NEVER OVERWRITTEN. Two concepts
        # with the same basename routed to one directory would otherwise have
        # the second silently destroy the first — an unrecoverable loss of a
        # memory, from a tool whose premise is running against someone else's
        # bundle. Leaving it put is visible in the next check run.
        if command grep -Fx "$new_rel" "$taken" >/dev/null 2>&1; then
            continue
        fi
        command printf '%s\n' "$new_rel" >>"$taken"
        command printf '%s\t%s\n' "$rel" "$new_rel" >>"$mapping"
        emit_edit "move-concept" "$path" "move" "0" "$rel" "$new_rel" \
            "relocate into $target_dir/ per the taxonomy"
    done <"$concepts"

    command rm -f "$members" "$taken"
}

# --- plan_directory_indexes --------------------------------------------------

# retarget_line LINE BASE — LINE with its first bundle-internal `.md` link
# target replaced by BASE.
retarget_line() {
    local line="$1" base="$2" head label target tail
    case "$line" in *']('*) ;; *)
        command printf '%s' "$line"
        return 0
        ;;
    esac
    head="${line%%[*}"
    tail="${line#*[}"
    label="${tail%%]*}"
    tail="${tail#*](}"
    target="${tail%%)*}"
    case "$target" in
        *.md) ;;
        *)
            command printf '%s' "$line"
            return 0
            ;;
    esac
    command printf '%s[%s](%s)%s' "$head" "$label" "$base" "${tail#*)}"
}

# plan_directory_indexes ROOT FILE_LIST MAPPING_FILE CLAIMED_OUT
#
# Emits `create` edits for each new directory's index.md AND writes
# `new_rel<TAB>original_index_line` rows to CLAIMED_OUT.
#
# OKF §8 GIVES EACH DIRECTORY ITS OWN index.md, and that is what makes a nested
# concept reachable: `golem/thing.md` is routed by `golem/index.md`, never by
# the bundle root's index. Repointing the ROOT line at `golem/thing.md` instead
# — the obvious-looking move — produces a bundle the validator faults as
# memory-dangling-index, because the root index is not what routes a nested file.
#
# So a move RELOCATES an index line rather than repointing it: the line leaves
# the root index and lands in the new directory's index, and the root keeps one
# line naming the sub-index. The claimed lines are published so the caller knows
# not to also repoint them — a concept named in both places is
# memory-multi-index, itself a HIGH finding.
#
# An EXISTING directory index is APPENDED TO, never regenerated — both halves
# required. Not regenerating follows adopt_bundle's rule for the bundle root
# (the file is the operator's); appending matters because the arriving concept's
# old index line is being repointed at this very index, so skipping it leaves the
# concept named by NO index. Measured: a memory-orphan on a clean apply.
plan_directory_indexes() {
    local root="$1" list="$2" mapping="$3" claimed="$4"
    local dirs path here line old_rel new_rel dir base body count target label
    : >"$claimed"
    [ -s "$mapping" ] || return 0

    # Which line named each moved concept, keyed by its NEW path.
    while IFS= read -r path || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        here="${path#"$root"/}"
        case "$here" in
            */*) here="${here%/*}" ;;
            *) here="" ;;
        esac
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in *']('*) ;; *) continue ;; esac
            while IFS="$(command printf '\t')" read -r label target || [ -n "$label" ]; do
                [ -n "$target" ] || continue
                case "$target" in
                    *.md) ;;
                    *) continue ;;
                esac
                case "$target" in *://*) continue ;; esac
                if [ "${target#/}" != "$target" ]; then
                    old_rel="$(normalize_rel "${target#/}")"
                else
                    old_rel="$(normalize_rel "${here:+$here/}$target")"
                fi
                new_rel="$(lookup_mapping "$old_rel" "$mapping")"
                [ -n "$new_rel" ] || continue
                command grep -q "^$new_rel	" "$claimed" 2>/dev/null && continue
                command printf '%s\t%s\n' "$new_rel" "$line" >>"$claimed"
            done <<EOF
$(scan_links "$line")
EOF
        done <"$path"
    done <"$list"

    # One index per NEW directory.
    dirs="$(command cut -f2 "$mapping" | command sed -e 's|/[^/]*$||' |
        command grep -v '^$' | command sort -u)"
    while IFS= read -r dir || [ -n "$dir" ]; do
        [ -n "$dir" ] || continue
        if [ -e "$root/$dir/index.md" ]; then
            # AN EXISTING DIRECTORY INDEX IS APPENDED TO, NEVER REGENERATED. The
            # file is the operator's and may hold hand-written lines — but it
            # MUST gain a line for each arriving concept or that concept is named
            # by no index at all. Measured: moving into a directory that already
            # had an index left the moved file a memory-orphan, because the line
            # naming it was repointed at the sub-index while the sub-index never
            # learned about it.
            # ONE EDIT FOR THE WHOLE BLOCK, not one per arriving concept, and
            # that is correctness rather than tidiness: edits to a file apply
            # HIGHEST LINE FIRST and each insert clamps against the GROWING
            # buffer, so N separate appends at len+1, len+2, len+3 land OUT OF
            # ORDER — measured with three concepts, `c1, c2, c3` was written as
            # `c1, c3, c2`. Both runtimes did it identically, so a byte-parity
            # check could not catch it.
            _at="$(command wc -l <"$root/$dir/index.md" | command tr -d ' ')"
            _block=""
            _n=0
            while IFS="$(command printf '\t')" read -r _o new_rel || [ -n "$_o" ]; do
                [ -n "$new_rel" ] || continue
                case "$new_rel" in "$dir"/*) ;; *) continue ;; esac
                base="${new_rel##*/}"
                command grep -F "($base)" "$root/$dir/index.md" >/dev/null 2>&1 && continue
                line="$(OKF_K="$new_rel" command awk -F"$(command printf '\t')" \
                    '$1 == ENVIRON["OKF_K"] { sub(/^[^\t]*\t/, ""); print; exit }' "$claimed")"
                if [ -n "$line" ]; then
                    line="$(retarget_line "$line" "$base")"
                else
                    line="- [${base%.md}]($base)"
                fi
                # EACH LINE IS ESCAPED FIRST, THEN joined with a literal `\n`.
                # The order is the whole contract, exactly as esc_field/unpad
                # already document it: escaping per line turns a content
                # backslash into `\\`, so a hook legitimately containing the two
                # characters `\n` — ordinary in a repo that documents regexes —
                # survives as those two characters instead of becoming a real
                # newline. Joining first and escaping after would make the
                # separator and the content indistinguishable. Measured: without
                # this, `matches \n and \t literally` was written as two lines.
                line="$(esc_field "$line")"
                if [ -n "$_block" ]; then
                    _block="$_block\\n$line"
                else
                    _block="$line"
                fi
                _n=$((_n + 1))
            done <"$mapping"
            if [ "$_n" -gt 0 ]; then
                emit_edit "move-concept" "$root/$dir/index.md" "insert-block" \
                    "$((_at + 1))" "" "$_block" \
                    "name $_n arriving concept(s) in the existing $dir/ index"
            fi
            continue
        fi
        body="# $dir\n"
        count=0
        while IFS="$(command printf '\t')" read -r _o new_rel || [ -n "$_o" ]; do
            [ -n "$new_rel" ] || continue
            case "$new_rel" in "$dir"/*) ;; *) continue ;; esac
            base="${new_rel##*/}"
            # ENVIRON, NEVER `awk -v`: a `-v` assignment is escape-processed, so
            # a path legitimately containing a backslash is mangled and the
            # lookup silently misses. Same rule as the moved_new lookup and as
            # migrate.sh's apply path.
            line="$(OKF_K="$new_rel" command awk -F"$(command printf '\t')" \
                '$1 == ENVIRON["OKF_K"] { sub(/^[^\t]*\t/, ""); print; exit }' "$claimed")"
            if [ -n "$line" ]; then
                # The ORIGINAL index line, retargeted to the sibling basename —
                # its hook text is the operator's prose and is what makes the
                # entry useful to recall against. A bare regenerated link would
                # silently discard it.
                body="$body\n$(retarget_line "$line" "$base")"
            else
                body="$body\n- [${base%.md}]($base)"
            fi
            count=$((count + 1))
        done <"$mapping"
        [ "$count" -gt 0 ] || continue
        emit_edit "move-concept" "$root/$dir/index.md" "create" "0" "" "$body" \
            "create the §8 directory index for $dir/ naming $count moved concept(s)"
    done <<EOF
$dirs
EOF
}

# --- rewrite_inbound_links ---------------------------------------------------

# lookup_mapping REL MAPPING_FILE — the new path for REL, or empty.
lookup_mapping() {
    local rel="$1" mapping="$2" old new
    while IFS="$(command printf '\t')" read -r old new || [ -n "$old" ]; do
        if [ "$old" = "$rel" ]; then
            command printf '%s' "$new"
            return 0
        fi
    done <"$mapping"
    return 0
}

# relative_to DEST FROM_DIR — DEST expressed relative to FROM_DIR.
#
# The python twin gets this from os.path.relpath. Written out because BSD has no
# `realpath --relative-to`, and the paths here need not exist.
relative_to() {
    local dest="$1" from="$2" d_head f_head up=""
    if [ -z "$from" ]; then
        command printf '%s' "$dest"
        return 0
    fi
    # Strip the shared leading segments.
    while [ -n "$from" ]; do
        d_head="${dest%%/*}"
        f_head="${from%%/*}"
        [ "$d_head" = "$f_head" ] || break
        case "$dest" in */*) dest="${dest#*/}" ;; *) dest="" ;; esac
        case "$from" in */*) from="${from#*/}" ;; *) from="" ;; esac
    done
    while [ -n "$from" ]; do
        up="$up../"
        case "$from" in */*) from="${from#*/}" ;; *) from="" ;; esac
    done
    command printf '%s' "$up$dest"
}

# rewritten_target TARGET HERE_REL MAPPING_FILE — TARGET rewritten for the move
# set, or empty when it needs no change.
#
# HANDLES BOTH LIVE LINK FORMS, which is not a nicety: wikilink-convert emits the
# `/`-rooted bundle-relative form, while a hand-written MEMORY.md / index-*.md
# uses plain relative targets. A rewriter that understood only one would leave
# every pointer in the other form dangling — the silent un-recall this transform
# exists to prevent.
#
# The OUTPUT form always matches the INPUT form. Restyling links is
# wikilink-convert's job (§6.1); doing it here would make this diff unreviewable.
rewritten_target() {
    local target="$1" here_rel="$2" mapping="$3"
    local rooted=0 old_rel new_rel here_dir new_here new_here_dir
    case "$target" in *://*) return 0 ;; esac
    case "$target" in
        *.md) ;;
        *) return 0 ;;
    esac
    if [ "${target#/}" != "$target" ]; then
        rooted=1
        old_rel="$(normalize_rel "${target#/}")"
    else
        case "$here_rel" in
            */*) here_dir="${here_rel%/*}" ;;
            *) here_dir="" ;;
        esac
        old_rel="$(normalize_rel "${here_dir:+$here_dir/}$target")"
    fi
    new_rel="$(lookup_mapping "$old_rel" "$mapping")"
    [ -n "$new_rel" ] || return 0
    if [ "$rooted" -eq 1 ]; then
        command printf '/%s' "$new_rel"
        return 0
    fi
    # The REFERRING file may itself be moving, so the relative link is recomputed
    # from where that file will LAND, not where it sits now. Missing this breaks
    # exactly the links between two files that move together — the common case
    # when a whole bucket relocates at once.
    new_here="$(lookup_mapping "$here_rel" "$mapping")"
    [ -n "$new_here" ] || new_here="$here_rel"
    case "$new_here" in
        */*) new_here_dir="${new_here%/*}" ;;
        *) new_here_dir="" ;;
    esac
    relative_to "$new_rel" "$new_here_dir"
}

# rewrite_inbound_links ROOT FILE_LIST MAPPING_FILE
#
# "EVERY inbound reference" is the acceptance criterion (AC3) and the reason this
# is a whole-bundle pass: a file linked from two different directories must have
# BOTH rewritten, and a rewriter stopping at the first hit leaves the second
# dangling while a fixture checking only one still passes.
#
# Indexes are not special-cased (AC4) — an index is a file containing links, so
# one pass satisfies both criteria and there is no second code path to drift.
rewrite_inbound_links() {
    local root="$1" list="$2" mapping="$3" claimed="${4:-}"
    local path here_rel line n in_fence changed rest label target new_target t
    local claimed_line sub_dir moved_new
    [ -s "$mapping" ] || return 0

    while IFS= read -r path || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        here_rel="${path#"$root"/}"
        n=0
        in_fence=0
        while IFS= read -r line || [ -n "$line" ]; do
            n=$((n + 1))
            t="${line#"${line%%[![:space:]]*}"}"
            case "$t" in
                '```'* | '~~~'*)
                    in_fence=$((1 - in_fence))
                    continue
                    ;;
            esac
            [ "$in_fence" -eq 0 ] || continue
            case "$line" in *']('*) ;; *) continue ;; esac

            # A line RELOCATED into a new directory index must not also be
            # repointed at the concept: it would then be named by two indexes,
            # which is memory-multi-index — a HIGH finding and a real ambiguity
            # about which index owns the concept. Repoint it at the SUB-INDEX
            # instead (§8: the root names the bucket, the bucket names its
            # concepts).
            if [ -n "$claimed" ] && [ -s "$claimed" ]; then
                # ENVIRON, NEVER `awk -v`: a `-v` assignment is
                # ESCAPE-PROCESSED, so a hook legitimately containing the two
                # characters `\n` — ordinary in a repo that documents regexes —
                # became a real newline and the comparison silently missed,
                # leaving that one line pointed at the concept while its
                # siblings pointed at the sub-index. Measured on a three-concept
                # fixture. This is the same rule migrate.sh's apply path states.
                moved_new="$(OKF_L="$line" command awk -F"$(command printf '\t')" \
                    '{ ln = $0; sub(/^[^\t]*\t/, "", ln); if (ln == ENVIRON["OKF_L"]) { print $1; exit } }' \
                    "$claimed")"
                if [ -n "$moved_new" ]; then
                    case "$moved_new" in
                        */*)
                            sub_dir="${moved_new%/*}"
                            claimed_line="$(retarget_line "$line" "$sub_dir/index.md")"
                            if [ "$claimed_line" != "$line" ]; then
                                emit_edit "move-concept" "$path" "replace-line" "$n" \
                                    "$line" "$claimed_line" \
                                    "point at the §8 directory index for $sub_dir/"
                            fi
                            continue
                            ;;
                    esac
                fi
            fi

            changed=""
            rest="$line"
            while :; do
                case "$rest" in *'['*']('*')'*) ;; *) break ;; esac
                changed="$changed${rest%%'['*}"
                rest="${rest#*[}"
                label="${rest%%]*}"
                case "$rest" in *']('*) ;; *)
                    changed="${changed}[$rest"
                    rest=""
                    break
                    ;;
                esac
                case "$label" in
                    *']'*)
                        # A `[` whose `]` is not followed by `(` is not a link.
                        changed="${changed}["
                        continue
                        ;;
                esac
                rest="${rest#*](}"
                target="${rest%%)*}"
                case "$rest" in
                    *')'*) rest="${rest#*)}" ;;
                    *) rest="" ;;
                esac
                new_target="$(rewritten_target "$target" "$here_rel" "$mapping")"
                [ -n "$new_target" ] || new_target="$target"
                changed="${changed}[$label]($new_target)"
            done
            changed="$changed$rest"

            if [ "$changed" != "$line" ]; then
                emit_edit "move-concept" "$path" "replace-line" "$n" \
                    "$line" "$changed" \
                    "follow moved concept(s) to their new path"
            fi
        done <"$path"
    done <"$list"
}
