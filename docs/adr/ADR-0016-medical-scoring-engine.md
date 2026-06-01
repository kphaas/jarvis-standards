# ADR-0016 — Medical Scoring Engine (jarvis-medical Phase-12)

**Status:** PROPOSED
**Date:** 2026-05-29
**Repo home:** jarvis-standards (shared sequence) · applies to jarvis-medical
**Owner:** Ken (medical = P-trait)
**Inputs:** discovery (no local store; lib-only) + Perplexity pediatric-standards research + Dr. William (pending sign-off)

---

## 1. Context
- jarvis-medical is library-only; no local store, no stable observation ID. Data flows to Brain via `AlphaPort.write_memory`.
- Family-Vault spec defines an **adult** composite "Health Score" (6 weighted categories, 27 biomarkers, outlier overrides, lifestyle modifier).
- Pediatric research verdict: **a composite 0–100 score is NOT clinically defensible for ages 5 & 8.** Standard practice = flag each metric against age/sex pediatric reference intervals + growth percentiles + screening. "Flag by domain, not score by summing unrelated measurements."
- Rule logic = pure stdlib. Config pattern = fail-closed YAML loader.

## 2. Decision

### 2.1 Pure, config-driven module, two modes
```python
def score(panel: Panel, mode: ScoreMode, cfg: ScoringConfig) -> Score: ...
```
No persistence, no network, no Ollama in v1. Fully local, deterministic. The engine **applies** clinician-sourced config; it never authors medical values.

| Mode | Output |
|---|---|
| **adult** | Composite hero score (6 categories + weights + overrides + lifestyle) layered on per-metric flags |
| **pediatric** | **Flag-only, by domain** (growth / vitals / labs) — NO hero score |

### 2.2 Unified contract (Option A) — phase-13 reads one shape
```python
ScoreMode = Literal["adult", "pediatric"]
Tier      = Literal["normal", "review", "call_office", "critical"]

@dataclass(frozen=True)
class MetricFlag:
    metric: str
    domain: str                 # growth|vitals|labs|cardio|metabolic|...
    value: float
    unit: str
    tier: Tier
    ref_low: float | None
    ref_high: float | None
    note: str                   # "BP needs height %ile" / "fever route-dependent"
    source: str                 # provenance / citation

@dataclass(frozen=True)
class CategoryScore:            # adult only
    category: str
    score: int                  # 0-100
    weight: float

@dataclass(frozen=True)
class Score:
    subject_token: str          # pseudonymous — raw name NEVER stored/logged
    mode: ScoreMode
    flags: tuple[MetricFlag, ...]              # ALWAYS present (common core)
    hero_score: int | None = None             # adult only
    categories: tuple[CategoryScore, ...] = () # adult only
    high_risk: bool = False                   # any critical flag, or adult override
    config_version: int = 0
    computed_at: str = ""
    disclaimer: str = DISCLAIMER
```

### 2.3 Flagging tiers (both modes)
`normal` · `review` (next visit) · `call_office` (soon) · `critical` (only when a lab/clinician-defined critical value exists — **never invented**). Engine rounds **up** when ambiguous.

### 2.4 Config — external, clinician-sourced, versioned
Two files, fail-closed loader, `schema_version` stamped onto every `Score`:
```
~/.config/jarvis-medical/scoring-adult.yml
~/.config/jarvis-medical/scoring-pediatric.yml
```
Per-metric fields: `domain, unit, specimen, age band, sex, height_pctile/route?, normal/borderline/critical, source(type+title+date+assay), note, verified_by`.
Pediatric standards: growth = CDC percentile (2–20y); BP = age/sex/**height** percentile; vitals age-banded; fever route-dependent. Adult longevity labs are **not** part of pediatric config.

## 3. Safety / liability (binding)
Advisory triage-assist only — **not a diagnosis, not medical advice.** The engine must **never**: diagnose, reassure against symptoms, recommend withholding/delaying care, override a clinician, or present a composite as a medical summary. Flag copy: *"outside the expected pediatric reference interval for age — review with the child's clinician."* Every `Score` carries the disclaimer.

## 4. PHI
`Score` is derived PHI; `subject_token` pseudonymous; logs/audit metadata-only. v1 neither persists nor transmits Scores.

## 5. Explicitly DEFERRED
| Item | Why |
|---|---|
| Persistence of panels + scores | No store exists; own ADR (residency: Brain Postgres + Unraid per README) |
| Trend scoring over time | Needs history → depends on persistence |
| Ollama LLM-assist (`engine_mode` reserved) | After rules ship |
| `ROUTE_OLLAMA` no-op fix (low-conf PHI still egresses) | PHI-gate completion → own phase + TD |
| PHI audit `:memory:` → durable (6-yr retention unmet) | Phase-11 debt → TD |

## 6. Consequences
**+** small blast radius; no PHI-at-rest; zero new deps; offline-testable; clinically defensible; locked contract de-risks parallel phase-13; pediatric path usable before adult numbers exist.
**−** output not stored by v1 (caller handles); range accuracy owned by Ken+William (mitigated by `config_version` + warn-once); needs later persistence ADR.

## 7. Test requirements
Deterministic, pure (config read only; no DB/HTTP/FS mutation). Fixtures: in-range→`normal`; one high→`review`; lab-critical→`critical`+`high_risk`; assert engine **never** downgrades on ambiguity; fail-closed on missing/malformed config (warn-once, never silent `normal`); no raw name in any field/log.

---
*Engine applies clinician-sourced ranges; it does not provide medical advice. All values require Dr. William's sign-off.*
