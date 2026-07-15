---
name: check-ai-config-bloat-scan
description: How to run the ai-file-bloat scanner locally + its raw-line-count thresholds per file type
metadata: 
  node_type: memory
  type: reference
  originSessionId: 0514957f-a771-49ed-93ae-8a7b994075b4
---

To reproduce a `check-ai-config` ai-file-bloat finding locally, run
`patterns.py` with a **path-list file** (argv[1] = file of paths, one per line),
NOT the paths directly:

```bash
find plugins/workflow/skills -name '*.md' > /tmp/scan-list.txt
python3 plugins/review-audit/skills/check-ai-config/patterns.py /tmp/scan-list.txt | grep ai-file-bloat
```

Line count is **raw `len(lines)`** (`patterns.py:227`) — no frontmatter/blank
stripping, so `wc -l` matches. Thresholds (`check_ai_file_bloat`, overridable via
env like `SKILL_HIGH`): SKILL.md warn=300 high=500; CLAUDE.md/AGENTS.md 400/600;
agents/*/*.md 250/400; docs/*.md 500/800. Companion `.md` files under a skill dir
match **none** of these globs (only `*/docs/*.md` catches doc bloat), so extracted
companions are not bloat-checked — but keep them < 500 anyway to avoid a future
`doc_md` reclassification. See [[codebase-audit-prescan-location]].
