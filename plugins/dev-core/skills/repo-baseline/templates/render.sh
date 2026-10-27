#!/usr/bin/env bash
# Render the repo-baseline scaffold for a chosen set of slices and CI platforms.
#
#   render.sh --slices shell,python --ci github,gitlab --out DIR [--force]
#
# Reads manifest.tsv beside this script: every row whose slice is selected
# (`core` always is) and whose `when` holds is written to DIR/<target>; rows
# sharing a target are concatenated in manifest order. No templating language,
# no network — the same bytes a plain `cat` loop would produce, which is the
# contract a non-LLM renderer (stibbons) implements independently. Format and
# rationale: README.md.
#
# Refuses (exit 2) an unknown slice or CI platform, a manifest row with an
# unknown `when` or a missing source, an absolute or `..` target, and an
# existing target file unless --force. Nothing is written until every check
# passes. bash-3.2 clean.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${RENDER_MANIFEST:-$HERE/manifest.tsv}"
TEMPLATES="$(cd "$(dirname "$MANIFEST")" && pwd)"

die() {
    printf 'render.sh: %s\n' "$1" >&2
    exit 2
}

usage() {
    printf 'usage: render.sh --slices a,b --ci github,gitlab --out DIR [--force]\n' >&2
    exit 2
}

slices="" ci="" out="" force=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --slices)
            [ "$#" -ge 2 ] || usage
            slices="$2"
            shift 2
            ;;
        --ci)
            [ "$#" -ge 2 ] || usage
            ci="$2"
            shift 2
            ;;
        --out)
            [ "$#" -ge 2 ] || usage
            out="$2"
            shift 2
            ;;
        --force)
            force=1
            shift
            ;;
        *) usage ;;
    esac
done
[ -n "$out" ] || usage
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"

# Known slices are the ones the manifest names — adding a slice is adding rows.
known_slices=" "
while IFS="$(printf '\t')" read -r target slice when source || [ -n "${target:-}" ]; do
    case "$target" in '' | '#'*) continue ;; esac
    case "$known_slices" in *" $slice "*) ;; *) known_slices="$known_slices$slice " ;; esac
done <"$MANIFEST"
[ "$known_slices" != " " ] || die "manifest has no rows: $MANIFEST"

selected=" core "
for s in $(printf '%s' "$slices" | tr ',' ' '); do
    case "$known_slices" in *" $s "*) ;; *) die "unknown slice '$s' (known:$known_slices)" ;; esac
    case "$selected" in *" $s "*) ;; *) selected="$selected$s " ;; esac
done

platforms=" "
for p in $(printf '%s' "$ci" | tr ',' ' '); do
    case "$p" in
        github | gitlab) platforms="$platforms$p " ;;
        *) die "unknown CI platform '$p' (known: github gitlab)" ;;
    esac
done

# Pass 1: validate every row and collect the selected ones, in order.
plan="$(mktemp)"
trap 'rm -f "$plan"' EXIT
n=0
while IFS="$(printf '\t')" read -r target slice when source || [ -n "${target:-}" ]; do
    n=$((n + 1))
    case "$target" in '' | '#'*) continue ;; esac
    [ -n "$slice" ] && [ -n "$when" ] && [ -n "$source" ] ||
        die "manifest line $n: expected 4 tab-separated columns"
    case "$target" in
        /* | ../* | */../* | *'/..' | '..') die "manifest line $n: target must be a relative path inside the repo: $target" ;;
    esac
    [ -f "$TEMPLATES/$source" ] || die "manifest line $n: source not found: $source"
    case "$when" in
        always) keep=1 ;;
        ci=github | ci=gitlab)
            case "$platforms" in *" ${when#ci=} "*) keep=1 ;; *) keep=0 ;; esac
            ;;
        *) die "manifest line $n: unknown when '$when' (known: always ci=github ci=gitlab)" ;;
    esac
    case "$selected" in *" $slice "*) ;; *) keep=0 ;; esac
    [ "$keep" -eq 1 ] && printf '%s\t%s\n' "$target" "$source" >>"$plan"
done <"$MANIFEST"

targets="$(cut -f1 "$plan" | awk '!seen[$0]++')"
if [ "$force" -eq 0 ]; then
    for t in $targets; do
        [ ! -e "$out/$t" ] || die "refusing to overwrite $out/$t (pass --force)"
    done
fi

# Pass 2: write. Each target is truncated once, then its rows are appended.
for t in $targets; do
    mkdir -p "$out/$(dirname "$t")"
    : >"$out/$t"
done
while IFS="$(printf '\t')" read -r t source; do
    cat "$TEMPLATES/$source" >>"$out/$t"
done <"$plan"
for t in $targets; do
    case "$t" in *.sh) chmod 0755 "$out/$t" ;; esac
    printf '%s\n' "$t"
done
