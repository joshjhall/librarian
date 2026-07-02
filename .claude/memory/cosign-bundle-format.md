---
name: cosign-bundle-format
description: release.yml cosign signing must use --bundle (.sigstore.json); cosign 3.x ignores the old --output-signature/-certificate flags and fails with an empty-path error
metadata:
  node_type: memory
  type: project
  originSessionId: 33d52fde-3186-45a2-b727-5a680228e918
---

`release.yml`'s cosign signing step must use `cosign sign-blob --bundle
librarian-<version>.tar.gz.sigstore.json`, NOT the old
`--output-signature`/`--output-certificate` pair.

`sigstore/cosign-installer@v4.1.2` installs **cosign 3.x** (3.0.6 at time of
writing), which defaults to `--new-bundle-format`. That format **deprecated and
IGNORES** `--output-signature`/`--output-certificate` (cosign warns "will be
ignored"), then tries to write to an empty `--bundle` path and dies:

```text
Error: signing librarian-<v>.tar.gz: create bundle file: open : no such file or directory
```

**Why this bit us:** signing landed in #142 (after v0.3.0), so **v0.4.0 was the
first release to actually run cosign** — the `validate` job had always passed,
but `publish` had never executed the signing step until a real feat/fix release
forced a bump past v0.3.0. Fixed in PR #153 (`fix(ci)`).

**The published contract is now two assets, not three:**

- `librarian-<version>.tar.gz` — signed archive
- `librarian-<version>.tar.gz.sigstore.json` — Sigstore bundle (signature +
  Fulcio cert in one file)

Verify with `cosign verify-blob --bundle <bundle> --certificate-identity … \
--certificate-oidc-issuer https://token.actions.githubusercontent.com <tarball>`
(README § "Verifying a release"). The three touchpoints that must stay in sync:
`.github/workflows/release.yml`, `README.md` (asset table + recipe), `CLAUDE.md`.

**Gotcha reproducing locally:** cosign 3.x's bundle signing routes through a
signing-config and always contacts Rekor — you can't do a fully offline
round-trip in a network-less sandbox (`--tlog-upload=false` is rejected as
"not supported with --signing-config"). Best local proof is that `--bundle` is
accepted and signing reaches the Rekor call; full keyless signing only works in
CI (needs the GitHub OIDC token). Related: [[release-process]],
[[git-cliff-checksum-sha512]].
