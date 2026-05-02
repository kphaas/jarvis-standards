# CLAUDE.md Guide — JARVIS repo convention

Source of truth for how every JARVIS repo structures its `CLAUDE.md` file. Read by Claude Code at session start; required at root of every JARVIS repo.

---

## Required sections (in this order)

1. **Quick orientation** — repo paths per node, owner, one-paragraph purpose, sister repos.
2. **Authoritative documents** — table of repo-internal docs to read before non-trivial changes. 3-7 rows.
3. **Architecture invariants (locked)** — numbered list of decisions that must not be violated. Imperative mood. Reference the ADR if one exists.
4. **Commit discipline** — pointer to `docs/adr/ADR-0005-adopt-multi-writer-coordination-model.md` (in jarvis-standards). Add repo-specific notes if applicable (e.g., generated `<repo>_commit.sh`).
5. **Secrets** — one-liner: where secrets live (Sandbox path, Air path if relevant).
6. **DO NOT list** — imperative rules specific to this repo. Skip stylistic preferences.
7. **When this file is wrong** (footer, verbatim):

> If a rule here conflicts with current reality, that is a bug in this file. Update via PR. Conflicts with a locked ADR resolve in favor of the ADR.

---

## Optional sections (include only if applicable)

- **Coding conventions** — only if repo has code
- **Local dev environment** — only if there's a dev stack
- **Useful commands** — only if non-obvious make / just targets exist
- **Workflow patterns** — only if non-default flows

Skip these for repos without runtime code.

---

## Prohibited content

- **No restating universals.** Tool split, command-block formatting, file-write verification, discovery-first protocol — all live in `DEVELOPMENT_PROCESS.md` (this repo). Reference, do not duplicate.
- **No active-task content.** In-flight work goes in `docs/tasks/`, not in CLAUDE.md.
- **No hardcoded IPs, hostnames, or secrets.** Use Tailscale magic DNS, env vars, or `~/.secrets`.
- **No session retrospectives.** Those go in `docs/handoffs/`.

---

## Tasks vs Handoffs

Two parallel directories, different audiences:

| Directory | Audience | Direction | Naming |
|---|---|---|---|
| `docs/tasks/` | Agents (Claude Code, Forge) | Forward — what to do | `TASK-NNN-<slug>.md` |
| `docs/handoffs/` | Humans / next session | Backward — what happened | `HANDOFF_YYYY-MM-DD_NN.md` |

Done tasks move to `docs/tasks/done/` or are deleted on PR merge.

---

## Lifecycle

- Updates require PR. No direct commits to main.
- Review every 4 sessions or on architecture-invariant change.
- Conflicts with a locked ADR resolve in favor of the ADR.

---

## Reference implementations

Pre-guide examples (predate this standard, may diverge): jarvis-financial, jarvis-family, jarvis-forge.

First post-guide implementation: jarvis-council.

TD-160 (jarvis-standards): extract universal sections from pre-guide CLAUDE.md files into a propagatable template via `scripts/_templates/`.
