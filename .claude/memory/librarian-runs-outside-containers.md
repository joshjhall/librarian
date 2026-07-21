---
name: librarian-runs-outside-containers
description: "Librarian is installed in many envs (Mac host, bare-linux, container) — never introduce a hard dependency on the containers submodule/devcontainer being present; cross-repo container changes get a companion high-priority issue on joshjhall/containers"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 4a569e6e-ef19-4017-ab95-d5f8dfddb610
  modified: 2026-07-21T04:21:00.488Z
---

Operator directive (2026-07-20 orchestrate session): librarian is a Claude Code
plugin marketplace installed across **many environments** — the operator's **Mac
host**, bare Linux, AND inside the containers devcontainer. Two standing rules
follow:

1. **Never rely on `containers` being present.** The `containers/` submodule is
   pinned (`update = none`) and exists only to build the devcontainer. Plugin
   code (skills, agents, workflow scripts) must run identically host /
   bare-linux / container / base-macOS. This is the *why* behind the repo's
   documented runtime policy (Python 3.11 floor → bash-3.2-clean fallback, no
   `just` in workflow scripts — they call `${CLAUDE_PLUGIN_ROOT}/scripts/...`
   directly). Apply it as a review lens on every plan: reject any container-only
   assumption, any path that only resolves inside the dev image, any
   `docker`/devcontainer prerequisite for a host-runnable tool.

2. **A change that must touch `containers` gets a companion issue there.** If a
   librarian issue's real fix lands inside the pinned submodule (e.g. #400: pin
   `agnix@latest` in `containers/lib/features/lib/dev-tools/install-binary-tools.sh`),
   do NOT edit the submodule from librarian. File a **high-priority**
   (`severity/high`) companion issue on **joshjhall/containers** with full
   cross-repo linkage (ADR + librarian tracking issue + already-merged consumers),
   and keep the librarian golem scoped to the **librarian-side coordination only**
   (ADR/config version-ref sync, cross-link). The operator lands containers
   issues in the next release (roughly next-day cadence). Live example: librarian

   #400 → **containers#769** (agnix pin), filed this session. The librarian golem
   for #400 must be plan-gated to librarian-side-only work.

Ties to the CLAUDE.md runtime policy and the [[two-runtime-model]] (sandbox vs
host tools). The companion-issue mechanics parallel
[[umbrella-issue-closes-vs-contributes]]: #400 is *coordination*, closed
librarian-side; containers#769 carries the actual fix.
