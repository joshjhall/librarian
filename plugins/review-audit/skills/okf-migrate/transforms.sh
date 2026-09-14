# shellcheck shell=bash
# okf-migrate — transform bodies (bash-3.2 fallback).
#
# Sourced by migrate.sh, never executed on its own — the mirror of
# transforms.py, and the same split for the same reason: each half stays under
# the 500 production-LOC budget. Sourcing precedent and its fail-loud existence
# check: check-okf-conformance/patterns.sh, which sources bundle-graph.sh the
# same way.
#
# THE CONTRACT IS THE OUTPUT, not the implementation (CLAUDE.md § Runtime
# policy). These functions must emit byte-identical plan/check output to their
# python twins; tests/okf-migrate/60-parity.sh pins it per case.
#
# EDITS ARE EMITTED, NEVER APPLIED. Every function here writes edit records to
# stdout and touches no file. migrate.sh is the only writer, and it writes only
# what a plan listed — the property that makes `plan` a genuine preview.
#
# Edit record format, tab-separated (one per line):
#   transform \t path \t kind \t line \t old \t new \t note
# kind is create | replace-line | insert-line. A `create` carries its body in
# `new` with newlines escaped as \n, since the record itself is line-oriented.
#
# bash-3.2 clean and BSD-safe: no declare -A / mapfile / namerefs / ${v,,} /
# ;;& , and no \s \w \b or grep -P — macOS ships bash 3.2 and BSD grep/sed,
# which read those as LITERALS and would silently match nothing.

# --- shared helpers ----------------------------------------------------------

# strip_quotes VALUE — one layer of surrounding quotes removed.
strip_quotes() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    case "$v" in
        '"'*'"')
            v="${v#\"}"
            v="${v%\"}"
            ;;
        "'"*"'")
            v="${v#\'}"
            v="${v%\'}"
            ;;
    esac
    command printf '%s' "$v"
}

# frontmatter_end FILE — 1-based line of the closing `---`, or 0.
# Mirrors frontmatter_span() in the python twin: only where the block IS, never
# how well-formed it is. The validator owns grading.
frontmatter_end() {
    local file="$1" line n=0 first=1
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        case "$line" in *[![:space:]-]*) ;; esac
        local t="${line#"${line%%[![:space:]]*}"}"
        t="${t%"${t##*[![:space:]]}"}"
        if [ "$first" -eq 1 ]; then
            [ "$t" = "---" ] || {
                command printf '0'
                return 0
            }
            first=0
            continue
        fi
        if [ "$t" = "---" ]; then
            command printf '%s' "$n"
            return 0
        fi
    done <"$file"
    command printf '0'
}

# fm_lookup FILE KEY — the raw value of frontmatter KEY, dotted for nesting
# (`metadata.type`). Empty when absent.
#
# The dotted spelling is what makes the commonest real migration expressible as
# configuration: a bundle whose `type` is nested has the answer already written
# down, so reading it is not an inference at all. Depth is tracked by indent
# width, which is all the shape these files use.
fm_lookup() {
    local file="$1" want="$2" end line n=0 t indent name value
    local parent="" parent_indent=-1
    end="$(frontmatter_end "$file")"
    [ "$end" -gt 0 ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        [ "$n" -gt 1 ] || continue
        [ "$n" -lt "$end" ] || break
        t="${line#"${line%%[![:space:]]*}"}"
        [ -n "$t" ] || continue
        case "$t" in '#'* | '- '*) continue ;; esac
        case "$t" in *:*) ;; *) continue ;; esac
        indent=$((${#line} - ${#t}))
        name="${t%%:*}"
        value="${t#*:}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [ "$parent_indent" -ge 0 ] && [ "$indent" -le "$parent_indent" ]; then
            parent=""
            parent_indent=-1
        fi
        local dotted="$name"
        [ -z "$parent" ] || dotted="$parent.$name"
        if [ "$dotted" = "$want" ] && [ -n "$value" ]; then
            strip_quotes "$value"
            return 0
        fi
        if [ -z "$value" ]; then
            parent="$name"
            parent_indent="$indent"
        fi
    done <"$file"
    return 0
}

# emit_edit TRANSFORM PATH KIND LINE OLD NEW NOTE
#
# EVERY FIELD IS PREFIXED WITH A COLON, which the reader strips. That is not
# decoration — it is what keeps EMPTY fields addressable. `read` splits on IFS,
# and when IFS holds a WHITESPACE character (tab is one) a run of them collapses
# to a single delimiter, so an empty `old` on an insert-line record silently
# shifts every later field left by one: `note` lands in `new`, and the plan
# renders "+infer type: project" where the file content belongs.
#
# Measured before fixing: bash rendered `@@ backfill-type:  @@` / `-type: project`
# against python's `@@ backfill-type: infer type: project @@` / `+type: project`
# — a parity break that only appears on records with an empty field, which is
# every create and every insert.
#
# THE LINE FIELD IS ZERO-PADDED TO 6 DIGITS so it sorts LEXICALLY in the order
# it would sort numerically. `sort -n` cannot be used on it: the colon above
# makes `:12` non-numeric, so GNU and BSD sort both read it as 0 and EVERY edit
# ties. Ties then apply in arbitrary order, and order is load-bearing — an
# insert shifts the line numbers of every edit below it, so applying a low
# insert before a high replace rewrites the wrong line.
#
# Measured before fixing: a file needing both a `type:` insert at line 2 and a
# wikilink replace at line 8 came out with "line one" deleted and the wikilink
# unconverted — silent corruption of a memory's body, and only on files needing
# two DIFFERENT transforms, which no single-transform fixture would have caught.
# A LITERAL TAB IN CONTENT IS ESCAPED TO \t, and unpad restores it. The record
# is tab-delimited, so a tab inside `old`/`new` is read as a field separator and
# shifts every later field — silent CORRUPTION of a memory's body rather than a
# visible error. Measured before fixing: a line reading
# `A line with<TAB>a literal tab and [[t]].` came back from the bash apply as
# `a literal tab and [[t]].` — the text before the tab simply gone, while the
# python twin converted the line correctly. Tab-indented content is ordinary in
# markdown (code blocks, tables), so this is a real shape, not a contrived one.
#
# Same treatment newlines already get in a `create` body, for the same reason:
# the record is line-and-tab structured, so both characters must travel escaped.
esc_field() {
    local v="$1" out="" tab head
    tab="$(command printf '\t')"
    case "$v" in
        *"$tab"* | *'\'*) ;;
        *)
            command printf '%s' "$v"
            return 0
            ;;
    esac
    # THE BACKSLASH IS ESCAPED FIRST, and that ordering is the whole contract.
    # Escaping only the tab is NOT round-trip safe: content that already holds
    # the two characters `\t` — ordinary in this repo, which documents regexes
    # constantly — would be decoded back into a REAL TAB it never contained.
    # Measured before fixing: `Regex \t means tab.` came out of the bash apply
    # as `Regex <TAB> means tab.` while python left it alone, so the escape
    # meant to fix a parity break introduced a subtler one.
    #
    # Escaping `\` -> `\\` first and decoding it LAST (see unpad) makes the
    # mapping injective, which is what "round trip" requires.
    while [ -n "$v" ]; do
        case "$v" in
            '\'*)
                out="$out\\\\"
                v="${v#?}"
                ;;
            "$tab"*)
                out="$out\\t"
                v="${v#?}"
                ;;
            *)
                # Copy the run up to the next character needing an escape.
                head="${v%%[\\"$tab"]*}"
                if [ "$head" = "$v" ]; then
                    out="$out$v"
                    break
                fi
                out="$out$head"
                v="${v#"$head"}"
                ;;
        esac
    done
    command printf '%s' "$out"
}

# A `create` body is ALREADY ENCODED by its producer (adopt_bundle builds it
# with literal `\n` markers, because a real newline cannot travel in a
# line-oriented record). Running esc_field over it again would escape those
# markers' backslashes, and unpad would then decode them back to a literal `\n`
# instead of a newline — which is how a generated index.md came out as one line
# reading `---\nokf_version: 0.2\n---`. So the create kind skips the encoder and
# every other kind gets it; unpad is the single decoder for both.
# THE PATH IS ESCAPED TOO, for the same reason the content fields are: a
# filename may legitimately contain a tab, and an unescaped one splits the
# record so every later field shifts. Measured: with
# `feedback/odd<TAB>name.md`, python migrated the file and bash silently did
# not — the grep that re-selects a target's edit rows could never match a path
# whose own tab had become a delimiter. Silent skip, not an error.
#
# `note` is deliberately NOT escaped: it is tool-generated prose that never
# carries file content or a path, so it cannot contain a tab.
emit_edit() {
    local path new old="$5"
    path="$(esc_field "$2")"
    new="$6"
    if [ "$3" != "create" ]; then
        old="$(esc_field "$old")"
        new="$(esc_field "$new")"
    fi
    command printf ':%s\t:%s\t:%s\t:%06d\t:%s\t:%s\t:%s\n' \
        "$1" "$path" "$3" "$4" "$old" "$new" "$7"
}

# unpad VALUE — strip emit_edit's leading colon and decode esc_field's escapes.
#
# LEFT TO RIGHT, ONE ESCAPE AT A TIME, which is what makes it the exact inverse
# of esc_field: `\\` decodes to a single backslash and is then DONE, so it can
# never combine with a following `t` to produce a tab the content never had.
# A pass that decoded `\t` globally first would do exactly that.
unpad() {
    local v="${1#:}" out="" tab head
    tab="$(command printf '\t')"
    case "$v" in
        *'\'*) ;;
        *)
            command printf '%s' "$v"
            return 0
            ;;
    esac
    while [ -n "$v" ]; do
        case "$v" in
            '\\'*)
                out="$out\\"
                v="${v#??}"
                ;;
            '\t'*)
                out="$out$tab"
                v="${v#??}"
                ;;
            '\n'*)
                # The `create` body carries its newlines as `\n` (the record is
                # line-oriented, so a real newline cannot travel in a field).
                # Decoding it HERE, in the same left-to-right pass, is what lets
                # ONE decoder serve every field: a separate `sed 's/\\n/…/'` on
                # the create path would double-decode content esc_field had
                # already escaped, which is exactly how `---` became `---\`.
                out="$out
"
                v="${v#??}"
                ;;
            '\'*)
                # A lone backslash esc_field never emits; pass it through rather
                # than dropping it, so an unexpected input stays lossless.
                out="$out\\"
                v="${v#?}"
                ;;
            *)
                head="${v%%\\*}"
                if [ "$head" = "$v" ]; then
                    out="$out$v"
                    break
                fi
                out="$out$head"
                v="${v#"$head"}"
                ;;
        esac
    done
    command printf '%s' "$out"
}

# --- adopt-bundle ------------------------------------------------------------

# adopt_bundle ROOT VERSION TITLE CONCEPT_LIST_FILE
#
# ROOT-LEVEL CONCEPTS ONLY. OKF §8 gives each DIRECTORY its own index.md, so a
# concept in `sub/` is routed by `sub/index.md`, never by the root index.
# Naming nested concepts here claims a routing relationship §8 does not define,
# and the validator's health pass (root-level only, by the same §8 reasoning)
# reports every such line as memory-dangling-index. Measured: a nested concept
# produced a dangling row immediately after a clean apply.
#
# IDEMPOTENT: an existing index.md is never rewritten, so a second run plans
# nothing. The file is the operator's; regenerating it would silently discard
# hand-written index lines.
adopt_bundle() {
    local root="$1" version="$2" title="$3" list="$4"
    local index="$root/index.md" path rel body count=0
    [ -e "$index" ] && return 0

    body="---\\nokf_version: $version\\n---\\n\\n# $title\\n"
    while IFS= read -r path || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        rel="${path#"$root"/}"
        case "$rel" in */*) continue ;; esac
        body="$body\\n- [${rel%.md}]($rel)"
        count=$((count + 1))
    done <"$list"
    [ "$count" -gt 0 ] || return 0

    emit_edit "adopt-bundle" "$index" "create" "0" "" "$body" \
        "declare the bundle at okf_version $version and index $count root-level concept(s)"
}

# --- backfill-type -----------------------------------------------------------

# infer_type PATH ROOT RULES_FILE — the inferred type, or empty when no rule
# matches. Rules are ORDERED and first-match-wins, which is what makes the
# outcome deterministic and therefore reproducible between the two runtimes.
infer_type() {
    local path="$1" root="$2" rules="$3"
    local rel dir base rule source pattern target value
    rel="${path#"$root"/}"
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
        case "$source" in *:*) ;; *) continue ;; esac
        pattern="${source#*:}"
        source="${source%%:*}"

        case "$source" in
            frontmatter)
                case "$pattern" in *=*) continue ;; esac
                value="$(fm_lookup "$path" "$pattern")"
                if [ -n "$value" ]; then
                    # `$value` means adopt what is already written down — the
                    # nested-key case, which is not an inference at all.
                    if [ "$target" = '$value' ]; then
                        command printf '%s' "$value"
                    else
                        command printf '%s' "$target"
                    fi
                    return 0
                fi
                ;;
            dir)
                [ -n "$dir" ] || continue
                # shellcheck disable=SC2254  # pattern is config, glob intended
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
            file)
                # shellcheck disable=SC2254
                case "$base" in $pattern)
                    command printf '%s' "$target"
                    return 0
                    ;;
                esac
                ;;
        esac
    done <"$rules"
    return 0
}

# backfill_type ROOT CONCEPT_LIST RULES_FILE AMBIGUITY_OUT
#
# AN AMBIGUOUS FILE PRODUCES NO EDIT — it produces an ambiguity row, which the
# driver turns into a non-zero exit that writes nothing at all (AC5). The engine
# does not guess, and it does not partially apply around files it could not
# decide: a half-migrated bundle is harder to reason about than an unmigrated
# one. §4.1 requires consumers to TOLERATE unknown types, so a wrong value is
# rejected nowhere and propagates silently — a missing type is one loud finding,
# a wrong one is a lie the ecosystem believes.
#
# A file whose frontmatter is unparseable is LEFT ALONE: the validator reports
# it, and inserting a key into a block whose shape we do not understand risks
# compounding the damage.
backfill_type() {
    local root="$1" list="$2" rules="$3" amb_out="$4"
    local path end existing value n line t

    while IFS= read -r path || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        end="$(frontmatter_end "$path")"
        [ "$end" -gt 0 ] || continue
        existing="$(fm_lookup "$path" "type")"
        [ -z "$existing" ] || continue

        value="$(infer_type "$path" "$root" "$rules")"
        if [ -z "$value" ]; then
            command printf '%s\t%s\n' "$path" "no inference rule matched" >>"$amb_out"
            continue
        fi

        # Present but empty -> replace in place rather than adding a second
        # `type:` key, which would leave the file with two.
        n=0
        local replaced=0
        while IFS= read -r line || [ -n "$line" ]; do
            n=$((n + 1))
            [ "$n" -gt 1 ] || continue
            [ "$n" -lt "$end" ] || break
            t="${line#"${line%%[![:space:]]*}"}"
            case "$t" in
                type:*)
                    if [ "${#line}" -eq "${#t}" ]; then
                        emit_edit "backfill-type" "$path" "replace-line" "$n" \
                            "$line" "type: $value" "fill empty type"
                        replaced=1
                        break
                    fi
                    ;;
            esac
        done <"$path"
        [ "$replaced" -eq 0 ] || continue

        emit_edit "backfill-type" "$path" "insert-line" "2" "" "type: $value" \
            "infer type: $value"
    done <"$list"
}

# --- wikilink-convert --------------------------------------------------------

# resolve_target TARGET PATH ROOT — prints "<rel>\t<resolved 0|1>".
#
# The path is returned even when nothing resolves — the path the target WOULD
# occupy — because §6.1 tolerates a broken link as knowledge not yet written, so
# converting it is lossless and dropping it would destroy the fact that someone
# meant to link there (AC6).
resolve_target() {
    local target="$1" path="$2" root="$3" name here
    name="${target#"${target%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    [ -n "$name" ] || return 0
    case "$name" in *.md) ;; *) name="$name.md" ;; esac
    here="${path%/*}"
    if [ -e "$here/$name" ]; then
        # The result is BUNDLE-RELATIVE, so strip the root even when `here` IS
        # the root — in which case `${here#"$root"/}` strips nothing (there is no
        # trailing slash to match) and the link keeps the whole root path,
        # yielding `[beta](/.claude/memory/beta.md)` where python emits
        # `[beta](/beta.md)`. A concept in a subdirectory hid the bug because
        # that spelling DOES match.
        local rel="$here"
        if [ "$rel" = "$root" ]; then
            rel=""
        else
            rel="${rel#"$root"/}/"
        fi
        command printf '%s\t1' "$rel$name"
        return 0
    fi
    if [ -e "$root/$name" ]; then
        command printf '%s\t1' "$name"
        return 0
    fi
    command printf '%s\t0' "$name"
}

# convert_wikilinks ROOT FILE_LIST FORM CONVERT_UNRESOLVABLE
#
# IDEMPOTENT: the output contains no `[[`, so a second pass matches nothing.
#
# FENCED CODE IS SKIPPED. A memory documenting the old syntax would otherwise
# have its examples silently rewritten, turning documentation of a format into a
# claim about a different one.
convert_wikilinks() {
    local root="$1" list="$2" form="$3" allow_unresolved="$4"
    local path line n in_fence changed rest target label resolved rel link t

    while IFS= read -r path || [ -n "$path" ]; do
        [ -n "$path" ] || continue
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
            case "$line" in *'[['*) ;; *) continue ;; esac

            changed=""
            rest="$line"
            while :; do
                case "$rest" in *'[['*']]'*) ;; *) break ;; esac
                changed="$changed${rest%%'[['*}"
                rest="${rest#*'[['}"
                target="${rest%%']]'*}"
                rest="${rest#*']]'}"
                case "$target" in
                    *'|'*)
                        label="${target#*|}"
                        target="${target%%'|'*}"
                        ;;
                    *) label="$target" ;;
                esac
                local pair
                pair="$(resolve_target "$target" "$path" "$root")"
                rel="${pair%%	*}"
                resolved="${pair##*	}"
                if [ -z "$rel" ]; then
                    changed="${changed}[[${target}]]"
                    continue
                fi
                if [ "$resolved" = "0" ] && [ "$allow_unresolved" != "true" ]; then
                    changed="${changed}[[${target}]]"
                    continue
                fi
                if [ "$form" = "relative" ]; then
                    link="[$label](./$rel)"
                else
                    link="[$label](/$rel)"
                fi
                changed="$changed$link"
            done
            changed="$changed$rest"

            if [ "$changed" != "$line" ]; then
                emit_edit "wikilink-convert" "$path" "replace-line" "$n" \
                    "$line" "$changed" \
                    "convert wikilink(s) to $form markdown links"
            fi
        done <"$path"
    done <"$list"
}
