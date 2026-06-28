---
description: Context for security-sensitive work — authentication, authorization, secrets management, input validation, and OWASP concerns. Activate when building auth flows, handling credentials, or processing untrusted input.
---

# context-security

Activates security-focused skills across pipeline phases when the work
involves authentication, authorization, secrets, or untrusted input.

**Machine-readable mapping**: See `context.yml` for the phase-to-skill
mapping consumed by the pipeline orchestrator.

## When to Activate

- Building or modifying authentication or authorization flows
- Handling credentials, tokens, API keys, or secrets
- Processing user input or data from untrusted sources
- Implementing access control or permission systems
- Working with cryptographic operations

## What This Context Adds

| Phase         | Effect                                             |
| ------------- | -------------------------------------------------- |
| **Plan**      | Security requirements surfaced during planning     |
| **Implement** | `loop-make-it-secure` activated after core loops   |
| **Review**    | Security-focused check-\* skills run during review |
| **Test**      | Injection and auth boundary tests prioritized      |
| **Docs**      | Security decisions and trust boundaries documented |

## Project-Level Override

Place a modified `context.yml` in `.claude/skills/context-security/` to
customize the phase mapping for your project's security requirements.
