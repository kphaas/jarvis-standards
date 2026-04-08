# JARVIS Standards

Living documents that define how all JARVIS repos are built.

This repo is the single source of truth for cross-repo conventions. Every JARVIS repo (jarvis-alpha, jarvis-forge, and future services) references the standards here.

## Current Standards

| Document | Purpose |
|---|---|
| [docs/LOGGING.md](docs/LOGGING.md) | Structured logging pattern using `get_logger` |

## Planned Standards

| Document | Purpose |
|---|---|
| `docs/SECURITY.md` | Secrets handling, `get_secret()` pattern, no-hardcoded-IPs rule |
| `docs/COMMIT_SCRIPTS.md` | Shared commit script pattern (jarvis*_commit.sh) |
| `docs/RLS.md` | Postgres Row-Level Security patterns |
| `docs/TESTING.md` | Test file layout and pytest conventions |
| `docs/PATTERNS.md` | Cross-cutting implementation patterns |

## How to Use

1. **Read before coding** — when starting a new repo or adding a new service, read the relevant standard.
2. **Reference in repo PATTERNS.md** — each repo's `docs/PATTERNS.md` links back here.
3. **Update centrally** — standards change here, not in individual repos. Repos inherit by reference.
4. **Propose changes via PR** — no direct pushes to standards (applies when collaborators exist).

## Philosophy

- **Standards repo vs template repo:** this repo contains *living* documents. A separate future `jarvis-template` repo will contain the *scaffolding* (file skeletons, boilerplate) to spin up a new service. Standards are referenced at development time; templates are used at repo-creation time.
- **Big-tech pattern:** Stripe, Netflix, and Shopify all separate standards from templates for the same reason — standards evolve, templates are snapshots.
- **Zero-rework upgrades:** new docs can be added without reorganizing existing repos. Repos only reference this one, so adding `SECURITY.md` here makes it immediately available everywhere.
