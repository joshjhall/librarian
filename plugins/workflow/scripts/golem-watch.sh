#!/usr/bin/env bash
# golem-watch.sh — proactively watch for blocked golems (streams feed + pane
# gate channels; Ctrl-C to stop).
#
# Replaces the containers `golem-watch` just recipe so the golem flow runs
# WITHOUT `just`. The PUSH complement to golem-status.sh's PULL surface: it
# streams both gate channels and emits one "<golem> <message>" line on each
# transition into a fresh gate.
#
# Pane channel in the background, feed channel in the foreground; both prefix
# their source so the operator can tell which channel fired. The background pane
# watcher is killed when the foreground feed watcher exits.
#
# Usage: golem-watch.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"
watch="$SCRIPT_DIR/golem-gate-watch.sh"

command echo "Watching for golem permission gates (feed + panes). Ctrl-C to stop." >&2

( "$watch" --stream-panes 2>/dev/null | /usr/bin/sed -u 's/^/[pane] /' ) &
pane_pid=$!
trap '/usr/bin/kill "$pane_pid" 2>/dev/null || true' EXIT INT TERM
"$watch" --stream 2>/dev/null | /usr/bin/sed -u 's/^/[feed] /'
