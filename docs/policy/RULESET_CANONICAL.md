# RULESET_CANONICAL — JARVIS branch ruleset spec

**Status:** Active
**Authority:** ADR-0005 (multi-writer coordination model) + ADR-0005 Amendment 2026-05-05 (§6.1.1 force-push semantics)
**Operational reference:** `DEPLOYMENT.md` §6.1, §6.1.1, §6.2

This file defines the canonical GitHub branch ruleset every JARVIS repository MUST adopt. It is the source of truth for what `gh api` ruleset payloads should look like; runbooks and tools that apply rulesets MUST conform to this spec.

Application of this ruleset across repos is *out of scope* for this document — see TD-X34 follow-up runbook for the rollout tool.

---

## Scope

Two rulesets per repo:

1. **Agent-branch ruleset** (this document, §A) — applied to agent branch patterns; allows force-push, requires PR.
2. **`main` ruleset** — applied to `refs/heads/main`; preserves full Layer 1 protections per `DEPLOYMENT.md` §6.2. Not specified here (already canonical in `DEPLOYMENT.md` §6.2).

---

## §A — Agent-branch ruleset

### Target

```
refs/heads/claude-code/**
refs/heads/cursor/**
refs/heads/copilot/**
refs/heads/forge/**
refs/heads/bot/**
```

### Enforcement

`active` (not `evaluate`).

### Rules

| Rule | Included? | Configuration | Why |
|---|---|---|---|
| `pull_request` | ✓ | `required_approving_review_count: 0`, `require_last_push_approval: true`, `dismiss_stale_reviews_on_push: true`, `required_review_thread_resolution: false` | Layer 1 — agent commits go through PR. Solo dev: `required_approving_review_count=0` because the owner's own self-approval acts as the human gate. `require_last_push_approval` prevents silent re-push past approval. |
| `non_fast_forward` | ✗ | — | **Carve-out per ADR-0005 Amendment §6.1.1.** Permits in-flight rebase-and-fix on agent branches with open PRs. |
| `update` | ✗ | — | Agent branches must remain updatable while in flight. |
| `deletion` | ✗ | — | Branches are deleted by `gh pr merge --delete-branch` post-merge; the rule would block this. |
| `creation` | ✗ | — | Agents must be able to create their own branches. |
| `required_linear_history` | ✓ | — | Squash or rebase merge only; no merge commits into the agent branch (keeps history clean for review). |
| `required_status_checks` | ✓ | repo-specific (typically `lint`, `typecheck`, `test`, `secret-scan`, `base-staleness`, `ci-pass`) | Status checks gate the PR's merge button. The exact check set is per-repo and SHOULD match the substrate CI matrix. |

### Bypass actors

```
[]
```

Empty. The ADR's wording (Amendment §6.1.1) captures the carve-out; we do NOT use bypass-actor lists to scope force-push to a single user. See "Trade-off accepted" in ADR-0005 Amendment for the reasoning.

### Conditions

None. The ruleset applies whenever the target ref pattern matches.

---

## §B — Reference payload

The following GitHub Rulesets API payload is the canonical shape. Tools that apply this ruleset MUST emit this structure (modulo `required_status_checks.contexts`, which is repo-specific):

```jsonc
{
  "name": "jarvis-agent-branches",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": [
        "refs/heads/claude-code/**",
        "refs/heads/cursor/**",
        "refs/heads/copilot/**",
        "refs/heads/forge/**",
        "refs/heads/bot/**"
      ],
      "exclude": []
    }
  },
  "rules": [
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "require_last_push_approval": true,
        "dismiss_stale_reviews_on_push": true,
        "required_review_thread_resolution": false,
        "require_code_owner_review": false
      }
    },
    {
      "type": "required_linear_history"
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [
          { "context": "lint" },
          { "context": "typecheck" },
          { "context": "test" },
          { "context": "secret-scan" },
          { "context": "base-staleness" },
          { "context": "ci-pass" }
        ]
      }
    }
  ],
  "bypass_actors": []
}
```

The required-checks list is the **typical** JARVIS substrate matrix; per-repo overrides are allowed where a check does not exist (e.g. submodule-only repos may drop `test`). The `pull_request` rule and the *absence* of `non_fast_forward` are NOT optional — those are the load-bearing parts of this spec.

---

## §C — Conformance

A JARVIS repo conforms when:

1. A ruleset matching §B exists, named `jarvis-agent-branches`, enforcement=`active`.
2. No additional ruleset on the same patterns adds back `non_fast_forward`.
3. The `main` ruleset (separate, per `DEPLOYMENT.md` §6.2) is also present.

The §6.3 quarterly audit checklist in `DEPLOYMENT.md` SHOULD be extended to verify §A conformance. That extension lands with the rollout runbook, not in this PR.

---

## §D — Trade-off acknowledged

The ruleset grants force-push on agent branches to *any* actor with push access, not only the repo owner. GitHub Rulesets cannot scope force-push to a specific user without populating `bypass_actors`, which we deliberately leave empty. Acceptable today because (a) only the repo owner has push access to JARVIS repositories, (b) any agent commit goes through PR before merge into `main`. Revisit via ADR amendment if push access broadens (additional contributors, paid agent integrations with their own GitHub identities, etc.).
