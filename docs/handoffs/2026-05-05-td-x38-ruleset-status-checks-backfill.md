# Handoff 2026-05-05 — TD-X38 — backfill `required_status_checks` on non-substrate repos

**Status:** Open
**Source:** TD-X34 rollout (canonical ruleset application across 8 JARVIS repos)
**Owner:** Ken
**Blocked by:** TD-X31 (forge substrate), TD-X35 (financial + family substrate)

---

## Context

TD-X34 amended ADR-0005 with §6.1.1 (force-push semantics on agent branches) and shipped `docs/policy/RULESET_CANONICAL.md`. The canonical §B payload requires status checks `lint`, `typecheck`, `test`, `secret-scan`, `base-staleness`, `ci-pass` — the JARVIS substrate matrix.

Rollout (this session) applied the canonical ruleset to all 8 JARVIS repos. Three repos do not yet have the substrate CI workflow merged, so applying the literal §B payload would block PR merges on missing required checks. **Per pre-flight Option B (confirmed by Ken)**, those 3 repos received a variant ruleset with the `required_status_checks` rule omitted — the load-bearing parts (`pull_request`, `required_linear_history`, no `non_fast_forward`, all 5 target patterns) ship; status check enforcement waits.

## Affected repos

| Repo | Ruleset ID | Substrate adoption blocker | Variant applied |
|---|---|---|---|
| `jarvis-forge` | 15994793 | TD-X31 | no-checks |
| `jarvis-financial` | 15994794 | TD-X35 | no-checks |
| `jarvis-family` | 15844036 | TD-X34 + TD-X35 (no `ci.yml` exists yet) | no-checks (UPDATED in place from prior broken ruleset) |

The 5 substrate-adopting repos (`standards`, `alpha`, `council`, `data-sources`, `print-copilot`) received the full canonical payload and are conformant per `docs/policy/RULESET_CANONICAL.md` §C.

## Action when unblocked

After each of the 3 deferred repos merges its substrate CI workflow (i.e. when `lint`, `typecheck`, `test`, `secret-scan`, `base-staleness`, `ci-pass` all exist as check contexts on a representative PR), update its agent-branch ruleset to add the `required_status_checks` rule:

```jsonc
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
```

Apply via `gh api repos/kphaas/<repo>/rulesets/<id> --method PUT --input <payload>` with the full canonical payload (`/tmp/canonical_full.json` shape, see `RULESET_CANONICAL.md` §B). Verify post-apply that `[.rules[] | .type]` contains `required_status_checks` and still excludes `non_fast_forward`.

## Conformance check

Repo is fully conformant with `RULESET_CANONICAL.md` §C when:

```bash
gh api repos/kphaas/<repo>/rulesets/<id> --jq '{
  name,
  has_pr: ([.rules[] | .type] | contains(["pull_request"])),
  has_linear: ([.rules[] | .type] | contains(["required_linear_history"])),
  has_status_checks: ([.rules[] | .type] | contains(["required_status_checks"])),
  has_nff: ([.rules[] | .type] | contains(["non_fast_forward"])),
  patterns: .conditions.ref_name.include
}'
```

Expected for full conformance: `name=jarvis-agent-branches`, `has_pr=true`, `has_linear=true`, `has_status_checks=true`, `has_nff=false`, `patterns` covers all 5 namespaces.

## Notes

- Family's prior ruleset (also id `15844036`) had `non_fast_forward` + `pull_request` only and missed `cursor/**` and `copilot/**` patterns. The PUT replaced it in place — the ID is preserved, so any audit links remain valid.
- `main` branch protections were NOT touched in this rollout. They remain per-repo as currently configured (family has id `15844156`; other 7 repos' `main` posture is whatever they had prior). Treat `main` ruleset conformance to `DEPLOYMENT.md` §6.2 as a separate audit pass — out of scope for TD-X38.
