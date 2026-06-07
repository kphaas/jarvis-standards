# RULESET_CANONICAL — JARVIS branch ruleset spec

**Status:** Active (v2 — redesigned 2026-05-05 per TD-X34 v2)
**Authority:** ADR-0005 (multi-writer coordination model) + ADR-0005 Amendment 2026-05-05 (§6.1.1 force-push semantics)
**Operational reference:** `DEPLOYMENT.md` §6.1, §6.1.1, §6.2

This file defines the canonical GitHub branch rulesets every JARVIS repository MUST adopt. It is the source of truth for what `gh api` ruleset payloads should look like; runbooks and tools that apply rulesets MUST conform to this spec.

Application of these rulesets across repos is *out of scope* for this document — see TD-X38 v2 for the rollout follow-up.

---

## Why this is v2

The first version of this spec (v1, merged in TD-X34 PR #22, rolled out and reverted on 2026-05-05) defined a single ruleset targeting agent-branch namespaces (`claude-code/**`, `cursor/**`, `copilot/**`, `forge/**`, `bot/**`) with `pull_request`, `required_linear_history`, and `required_status_checks` rules. Rolling it out surfaced two design errors:

1. **`required_status_checks` blocks initial branch creation** (zero check runs exist yet). Required `do_not_enforce_on_create: true` to even allow first push. Discovered, patched live.
2. **`pull_request` and `required_status_checks`, when applied to a ruleset *targeting* agent branches, mean "to merge changes INTO an agent branch, you need a PR / passing checks."** That treats every direct push to `claude-code/foo` as a "merge into the protected branch" requiring a PR. Agents cannot push directly to their own branches under that interpretation. The rules were applied to the wrong target.

The intent was always *"agent commits go through PR before reaching `main`."* That is a `main`-branch invariant, not an agent-branch invariant. It belongs on the `main` ruleset.

v2 corrects the architecture: `main` carries all the gates; agent branches have NO ruleset and rely on the absence of rules to permit direct push, force-push, rewrites, deletion-via-`gh pr merge`, and free iteration.

---

## Scope

Two ruleset slots per repo. Only one is canonical here:

1. **`main` ruleset** (this document, §A1) — applied to `refs/heads/main`. Carries every gate: PR review, status checks, linear history, no force-push, no deletion.
2. **Agent-branch ruleset** (this document, §A2) — **DELETED** by design. The absence of any ruleset on agent-branch patterns is the policy.

`DEPLOYMENT.md` §6.2 ("Rule 2 — `main` branch invariants") describes the same `main` posture in operator-procedure form. §A1 below is the API-level source of truth; §6.2 is the operator runbook. They MUST agree.

---

## §A1 — `main` ruleset (canonical)

### Target

```
refs/heads/main
```

### Enforcement

`active` (not `evaluate`).

### Rules

| Rule | Included? | Configuration | Why |
|---|---|---|---|
| `pull_request` | ✓ | `required_approving_review_count: 0`, `require_last_push_approval: false`, `dismiss_stale_reviews_on_push: true` | Layer 1 — agent commits cannot reach `main` except via PR. Solo dev: `required_approving_review_count=0`; the owner's own self-approval is the human gate. `require_last_push_approval=false` because Ken is both the last pusher and the only authorized approver — set to `true`, every PR is unmergeable. Flip back to `true` if collaborators are added (see §D). `dismiss_stale_reviews_on_push: true` still forces re-review when the diff actually changes. |
| `required_status_checks` | ✓ | `strict_required_status_checks_policy: false`, `do_not_enforce_on_create: true`, contexts list per repo | Status checks (substrate CI matrix) must pass before merge to `main`. `do_not_enforce_on_create: true` lets the rule survive ruleset (re)creation without spuriously blocking on branches that pre-existed. `strict_required_status_checks_policy: false` permits squash/rebase merges without a re-run round-trip. |
| `required_linear_history` | ✓ | — | Squash or rebase merge only; no merge commits land on `main`. |
| `non_fast_forward` | ✓ | — | Force-push to `main` is prohibited (per ADR-0005 §6.1; the §6.1.1 carve-out applies only to agent branches). |
| `deletion` | ✓ | — | `main` cannot be deleted. |
| `update` | ✗ | — | Not used; `pull_request` covers update gating with finer parameters. |
| `creation` | ✗ | — | `main` already exists; not applicable. |

### Bypass actors

```
[]
```

Empty. Owner-bypass is documented in `DEPLOYMENT.md` §15.2.3 (must be logged in handoff) and SHOULD be granted via temporary ruleset toggle, not via bypass-actor list.

### Conditions

None. The ruleset applies whenever the target ref matches.

---

## §A2 — Agent-branch ruleset (intentionally absent)

**No ruleset MUST exist** on any of the following patterns:

```
refs/heads/claude-code/**
refs/heads/cursor/**
refs/heads/copilot/**
refs/heads/forge/**
refs/heads/bot/**
```

Rationale: the §6.1.1 amendment's intent ("force-push allowed on agent branches with open PRs") is automatically satisfied when no rule blocks it. Adding *any* `pull_request` or `required_status_checks` rule to these patterns blocks the direct-push iteration loop that defines the agent workflow — that was the v1 design error.

**Migration note.** If your repo previously had a `jarvis-agent-branches` ruleset from the broken v1 spec (TD-X34 v1, rolled out and reverted 2026-05-05), it has been DELETED. The §6.1.1 amendment's intent is preserved — force-push works because no rule prohibits it; PR review still gates merge to `main` because the **`main` ruleset** (§A1) blocks direct pushes there.

The `non_fast_forward`, `pull_request`, and `required_status_checks` enforcement intent for agent-branch *contents reaching `main`* is satisfied at the `main` boundary in §A1. There is no operational benefit to applying rules at the agent-branch boundary, and v1 demonstrated significant operational harm.

---

## §B — Reference payload (`main` ruleset)

The following GitHub Rulesets API payload is the canonical shape. Tools that apply this ruleset MUST emit this structure (modulo `required_status_checks.required_status_checks` contexts list, which is repo-specific):

```jsonc
{
  "name": "jarvis-main",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ["refs/heads/main"],
      "exclude": []
    }
  },
  "rules": [
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "require_last_push_approval": false,
        "dismiss_stale_reviews_on_push": true,
        "required_review_thread_resolution": false,
        "require_code_owner_review": false
      }
    },
    {
      "type": "required_linear_history"
    },
    {
      "type": "non_fast_forward"
    },
    {
      "type": "deletion"
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "do_not_enforce_on_create": true,
        "required_status_checks": [
          { "context": "secret-scan" },
          { "context": "base-staleness" },
          { "context": "forge/native-ci-shadow" }
        ]
      }
    }
  ],
  "bypass_actors": []
}
```

The required-checks list is the **native-gated** JARVIS matrix. `secret-scan`
and `base-staleness` stay on GitHub-hosted Actions because they are cheap and
benefit from GitHub PR context. `forge/native-ci-shadow` is posted by Forge
native CI on Sandbox and owns trusted lint/typecheck/test/build work.

Do not require hosted `lint`, `typecheck`, `test`, or `ci-pass` after a repo is
promoted to Forge native CI. For repos whose native adoption is still pending,
either keep their current repo-local status policy or apply this payload with
the `required_status_checks` rule omitted until `forge/native-ci-shadow` has a
green sample PR.

`do_not_enforce_on_create: true` is **not optional** when `required_status_checks` is present. It permits the ruleset itself to be (re)applied without spuriously blocking on a branch state that pre-existed; it does not weaken merge-time enforcement.

The load-bearing parts of this spec are: (a) `pull_request`, (b)
`non_fast_forward`, (c) `required_linear_history`, (d) presence of
`required_status_checks` once Forge native CI is active. Anything else is
tunable per-repo.

---

## §C — Conformance

A JARVIS repo conforms when:

1. A ruleset matching §B exists on `refs/heads/main`, named `jarvis-main`, enforcement=`active`.
2. **No** ruleset exists on any of the five agent-branch patterns (`claude-code/**`, `cursor/**`, `copilot/**`, `forge/**`, `bot/**`). The absence is the policy.
3. The §6.3 quarterly audit checklist in `DEPLOYMENT.md` confirms both of the above.

The §6.3 audit query MUST check both: presence of `jarvis-main` ruleset, AND absence of any ruleset on agent patterns. That extension lands with the rollout runbook (TD-X38 v2).

---

## §D — Trade-off acknowledged

Agent branches have **zero** server-side enforcement under v2. Anyone with push access can rewrite, force-push, or delete an agent branch freely. Acceptable today because:

- Only the repo owner has push access to JARVIS repositories.
- The `main` ruleset blocks any unreviewed, unchecked, or merge-commit-bearing change from reaching `main` regardless of what happens on agent branches first.
- Agent-branch chaos (force-pushes, rebases, mid-flight rewrites) is *expected* and *desired* — that is the workflow §6.1.1 was amended to permit.

Revisit via ADR amendment if push access broadens (additional contributors, paid agent integrations with their own GitHub identities, etc.). At that point, consider a `pull_request`-only ruleset on agent branches with `do_not_enforce_on_create: true` to gate merges *into* agent branches by non-owner actors while still allowing the owner's direct iteration.
