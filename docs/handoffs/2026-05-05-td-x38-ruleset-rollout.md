# Handoff 2026-05-05 — TD-X38 v2 — apply canonical `main` ruleset across JARVIS

**Status:** Open
**Source:** TD-X34 v2 redesign (this PR — `RULESET_CANONICAL.md` v2)
**Owner:** Ken
**Supersedes:** TD-X38 v1 (`backfill required_status_checks on non-substrate rulesets`) — obsolete after v1 rulesets were deleted.

---

## Why this exists

TD-X34 v1 produced a canonical ruleset spec that placed `pull_request` and `required_status_checks` rules on agent-branch namespaces (`claude-code/**`, `cursor/**`, `copilot/**`, `forge/**`, `bot/**`). v1 was rolled out to all 8 JARVIS repos and reverted in the same session after the design errors below surfaced. v2 (this PR's `RULESET_CANONICAL.md`) corrects the architecture: `main` carries every gate; agent branches have no ruleset.

This handoff tracks the rollout of v2 to all 8 repos. **No `jarvis-main` ruleset exists anywhere yet** as of this handoff — applying it is the work.

## v1 design errors (post-mortem)

1. **`do_not_enforce_on_create` defaulted false on `required_status_checks`.** The initial push that creates a new branch matching the ruleset pattern was rejected (zero check runs exist on a brand-new branch). Discovered when the v1 spec PR's own follow-up branch failed to push. Patched live; not the deeper problem.
2. **`pull_request` and `required_status_checks` were applied to the wrong target.** When a ruleset targets `claude-code/**` and includes those rules, GitHub reads them as "to merge changes INTO branches matching this pattern, you need a PR / passing checks." Every direct push to `claude-code/foo` was treated as a "merge into the protected branch" requiring a PR — blocking the agent iteration loop the rules were supposed to enable. The intent was always *"agent commits go through PR before reaching `main`"*, which is a `main`-branch invariant, not an agent-branch invariant.

The v1 rulesets (eight total, IDs `15994778`, `15994780`, `15994782`, `15994783`, `15994784`, `15994793`, `15994794`, `15844036`) were DELETED on 2026-05-05 before this handoff was written. No v1 rulesets remain.

## v2 architecture (this PR)

Two ruleset slots per repo. Only one is canonical:

1. **`jarvis-main` ruleset on `refs/heads/main`** — carries every gate: `pull_request`, `required_status_checks` (with `do_not_enforce_on_create: true`), `required_linear_history`, `non_fast_forward`, `deletion`. Spec in `RULESET_CANONICAL.md` §A1 + §B.
2. **No ruleset on agent-branch patterns.** The absence is the policy. Spec in `RULESET_CANONICAL.md` §A2.

## Rollout plan

When this spec PR (TD-X34 v2) merges, apply the canonical `main` ruleset to all 8 repos:

| Repo | Substrate adoption | `required_status_checks` rule? |
|---|---|---|
| `jarvis-standards` | ✓ | full payload |
| `jarvis-alpha` | ✓ | full payload |
| `jarvis-council` | ✓ | full payload |
| `jarvis-data-sources` | ✓ | full payload |
| `jarvis-print-copilot` | ✓ | full payload |
| `jarvis-forge` | ✗ (TD-X31 deferred) | OMIT `required_status_checks` rule; backfill when TD-X31 lands |
| `jarvis-financial` | ✗ (TD-X35 deferred) | OMIT `required_status_checks` rule; backfill when TD-X35 lands |
| `jarvis-family` | ✗ (no `ci.yml` yet) | OMIT `required_status_checks` rule; backfill when CI substrate lands |

Apply via:

```bash
gh api repos/kphaas/<repo>/rulesets --method POST --input <payload>.json
```

`<payload>.json` is the §B reference payload (with the `required_status_checks` rule included or omitted per the table).

## Self-test before broadening

Before the eight-way apply: pick ONE repo (recommend `jarvis-standards` since this branch is already there). Apply the `jarvis-main` ruleset. Then:

1. Create a fresh agent branch on that repo: `git checkout -b cursor/test-after-rollout-XXXX`.
2. Make a trivial change, push (should succeed — no rule on agent branches).
3. Force-push (should succeed).
4. Open a PR into `main`. The `main` ruleset's gates should fire on the PR (PR review required, checks required).
5. Merge the PR (should succeed only if checks pass + PR has approval/auto-approval).
6. Try a direct push to `main` from local (should be REJECTED by `non_fast_forward` + `pull_request`).

If any of (1)–(5) fail, the v2 spec is still wrong; STOP and triage before applying to the other 7 repos. Step (6) failing is the success signal — `main` should reject direct pushes.

## Conformance check

Repo conforms to v2 when:

```bash
# 1. main ruleset exists with expected shape
gh api repos/kphaas/<repo>/rulesets --jq '.[] | select(.name=="jarvis-main") | .id'   # must return one ID

# 2. NO ruleset exists on agent-branch patterns
gh api repos/kphaas/<repo>/rulesets --jq '.[] | select(.conditions.ref_name.include[]? | contains("claude-code"))'   # must return empty
```

The `DEPLOYMENT.md` §6.3 quarterly audit query SHOULD be extended to include both checks. That extension is part of this rollout (when applied), not of the spec PR.

## Notes

- v1 left no audit trail in `main` history because the v1 PR (#22) was merged, not reverted. v2 revises the spec in place rather than spawning ADR-0005 Amendment v2. The post-mortem is preserved in ADR-0005 Amendment §6.1.1 → "Discovery during rollout" and in this handoff.
- Family's pre-v1 ruleset (id `15844036`, `non_fast_forward` + `pull_request` only on `claude-code/**`/`forge/**`/`bot/**`) is also gone — it was UPDATED to the v1 no-checks variant, then DELETED with the others. Family currently has only the `main — branch invariants` ruleset (id `15844156`). That ruleset SHOULD be audited against v2 §B and either updated in place or replaced when family's `jarvis-main` ruleset is applied during rollout.
- `main` branch protection on the other 7 repos is whatever they had prior to TD-X34 v1 (none, in most cases). The rollout per the plan above is the first time most of them get any `main` enforcement.
