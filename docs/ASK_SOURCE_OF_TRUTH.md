# Ask Source of Truth

This standard keeps "Ask" from becoming three similar but drifting products.
The canonical machine-readable contract is
[`contracts/ask_surfaces.v1.json`](../contracts/ask_surfaces.v1.json).

## Decision

JARVIS has two Ask surfaces:

| Surface | Owner | Backend | Purpose |
|---|---|---|---|
| Operator Ask | `jarvis-helm` | `jarvis-alpha` | Ken/AT-0 operator chat, Beacon evidence, memory, model routing, research |
| Family Safe Ask | `jarvis-family` | `jarvis-family` | Parent/child-safe family chat, safety filtering, family document sources |

`jarvis-alpha` is not an Ask frontend owner. Alpha provides the operator Ask
backend: `/v1/chat/completions`, thread endpoints, memory endpoints, Beacon
evidence, approvals, and audit. Alpha UI may show status or hand off to Helm,
but must not implement its own chat composer or mode controls.

## Preserve What Works

### Helm Operator Ask

Current source of truth:

- `jarvis-helm/src/ask/AskWorkspace.tsx`
- `jarvis-helm/src/ask/alphaAskClient.ts`

Preserve these behaviors:

- Streaming SSE against Alpha `/v1/chat/completions`
- Thread list, message history, rename, delete, and escalation
- Model routing for `auto`, local, Claude, Perplexity, Gemini, and council
- Internet modes `none`, `web_search`, and `deep_research`
- Beacon evidence metadata, source quality, citations, raw web isolation, and
  deep research report metadata
- Semantic and working memory review/save/forget
- Operator voice input and AT-0 avatar response state

### Family Safe Ask

Current source of truth:

- `jarvis-family/api/routes/ask.py`
- `jarvis-family/api/services/ask_safety.py`
- `jarvis-family/ui/src/components/ask/AskChat.tsx`

Preserve these behaviors:

- Role-aware parent and child Ask UI
- Input safety assessment before model calls
- Child answer filtering after model calls
- Parent caution levels for medical, legal, and financial prompts
- Parent-only family document source retrieval
- Child-safe context with no parent document excerpts
- Streaming SSE answers with non-stream fallback
- Family voice input and optional voice reply

## Rules

1. Do not add a full Ask UI to Alpha.
2. Do not copy Family child-safety behavior into Helm.
3. Do not copy Helm operator model/research behavior into Family.
4. Shared behavior starts in the standards contract before app code copies it.
5. A repo that changes Ask ownership must update
   `contracts/ask_surfaces.v1.json` in the same work package.
6. Smoke/tests must prove the preserved capabilities before migration.

## Review Checklist

- Helm changes still exercise `streamAlphaChatCompletion` and
  `parseAlphaStreamFrame`.
- Family changes still exercise `assess_question`, `filter_child_answer`,
  `/v1/ask`, and `/v1/ask/stream`.
- Parent document sources never flow into child Ask.
- Alpha UI does not advertise or mount a standalone Ask workspace.
- Beacon source quality and citations remain attached to operator Ask messages.
