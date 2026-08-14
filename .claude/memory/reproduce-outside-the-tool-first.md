---
name: reproduce-outside-the-tool-first
description: "Before instrumenting a complex client, reproduce the failure with curl — it collapses the suspect list and exonerates your own instrumentation"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: db464d95-cdfd-4fd7-96fc-87d7814fd584
  modified: 2026-08-14T03:18:51.826Z
---

When a rich client (Claude Code, an SDK, an app) reports a vague error, the
instinct is to instrument the client. Do the cheap thing first: **reproduce the
failure with `curl` against the same endpoint.** A one-line repro collapses the
suspect list faster than any amount of client-side logging.

Worked example (2026-08-10, "API error · Retrying" across several sessions): a
logging proxy captured `ECONNRESET` at a suspiciously constant ~17.96s. The
proxy was itself suspected of causing it. Two curls settled everything:

- small payload direct vs through the proxy → **both 200, 12ms apart** → the
  instrumentation was exonerated by measurement, not by argument
- payload size sweep direct to the gateway → **≤65,000 B ok, ≥65,400 B reset at
  17.96s** → a 64 KiB buffer boundary, reproducible with no client involved

**Why:** an error inside a complex client has many candidate causes (client
version, SDK, proxy, gateway, network, backend). `curl` removes all the
client-side ones in a single command. It also protects your own tooling from
suspicion — when the user asks "is your capture causing this?", the answer
should be an A/B measurement, not reassurance.

**How to apply:**

1. Reproduce with `curl` before building or trusting instrumentation.
2. When your own tool is suspected, **A/B it** (direct vs through) and report
   the two numbers.
3. **Sweep the varying dimension** (size, concurrency, model) rather than
   retrying one case — the threshold IS the diagnosis.
4. **A constant duration is a configured timeout, never congestion.** Six
   samples within 8ms of 17.96s named the cause; variance would have meant load.
5. When a host resolves to **several IPs, test each with `--resolve`.** Partial
   failure across a pool is the classic shape of intermittency, and an
   aggregate test averages the bad backend into invisibility.

Related: [[measure-suppression-before-keeping-it]] — same discipline of
measuring rather than assuming.
