# check-demo-zzz — Output Contract

Fixture contract for the patterns-coverage gate (malformed arm). It has a
`## Categories` header but NO backtick-wrapped category slugs (a WIP /
mid-authoring contract). The tool must SKIP this domain silently — not abort —
and still report the well-formed sibling. Named `-zzz` so it sorts AFTER
`check-demo-ok`, reproducing the good→bad→(rest) ordering from the review
finding.

## Categories

Categories are still being authored for this domain.

## Finding Format

Standard finding-schema.md.
