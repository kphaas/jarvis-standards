# jarvis-standards/scripts

Shared tooling for JARVIS repos. Template-driven propagation to consumer repos.

## Pattern

Source of truth lives here as templates in `_templates/`. The `propagate_scripts.sh` engine copies templates into each consumer repo's `scripts/` directory with a `# GENERATED` header. Consumer repos never hand-edit generated files — they regenerate via propagation.

This follows the big-tech "generated code, checked in" pattern (e.g., Google's proto-generated code). Each consumer repo works standalone (sovereignty preserved — no runtime dependency on this repo). The single source of truth lives here.

## Directory Layout
scripts/
├── _templates/              # Source of truth — edit here
│   ├── check_sync.template.sh
│   └── ruff_detect.template.sh
├── propagate_scripts.sh     # Engine: reads templates, writes to consumer repos
├── propagate.config         # Config: which repos, which templates, per-repo vars
└── README.md                # This file

## Consumer Repos

- `jarvis-family`
- `jarvis-alpha`
- `jarvis-forge`

## Template Placeholders

Templates use `@@VAR@@` syntax (not `${VAR}` to avoid bash collision). Common placeholders:

| Placeholder | Example value |
|---|---|
| `@@REPO_NAME@@` | `jarvis-family` |
| `@@REPO_PATH@@` | `~/jarvis-family` |
| `@@VENV_PATH@@` | `~/jarvis-family/.venv` |
| `@@MAIN_BRANCH@@` | `main` |

## Usage

```bash
# Dry-run (show what would change, write nothing)
bash ~/jarvis-standards/scripts/propagate_scripts.sh --dry-run

# Real run (respects safety: won't overwrite non-generated files)
bash ~/jarvis-standards/scripts/propagate_scripts.sh

# Initial migration (overwrites hand-written files — one-time use)
bash ~/jarvis-standards/scripts/propagate_scripts.sh --initial
```

## Requirements

- Bash 5+ (macOS default bash 3.2 not supported — use Homebrew bash)
- `shellcheck` (available on every consumer repo for CI gate)

## Adding a New Template

1. Add `scripts/_templates/<name>.template.sh` to this repo
2. Add entry to `scripts/propagate.config` for each consumer repo
3. Run `bash scripts/propagate_scripts.sh --dry-run` to preview
4. Run real propagation
5. Commit the generated files in each consumer repo with their own commit flow

## Generated-File Header

Every generated file starts with:

```bash
#!/usr/bin/env bash
# GENERATED FROM jarvis-standards/scripts/_templates/<name>.template.sh
# Source commit: <sha>
# Generated:     <ISO-8601 timestamp>
# DO NOT EDIT DIRECTLY — edit the template in jarvis-standards and re-propagate.
```

This header is how `propagate_scripts.sh` detects whether a target file is safe to overwrite.

## Template file structure

Every `*.template.sh` file in `_templates/` MUST follow this structure for the propagation engine to strip the meta-block correctly:

```bash
#!/usr/bin/env bash
# TEMPLATE FILE — <short description, can use @@VAR@@>
# Source of truth: jarvis-standards/scripts/_templates/<filename>
# Propagated to:   @@REPO_PATH@@/scripts/<consumer-path>
#
# <docstring starts here — preserved in generated output>
# <multi-line docstring is fine, including blank-comment lines like the next one>
#
# <more docstring>

set -euo pipefail
# ... actual bash code ...
```

The engine strips exactly 5 lines from the top of every template before substitution:

1. The `#!/usr/bin/env bash` shebang (we provide our own with the GENERATED header)
2. The `# TEMPLATE FILE — ...` marker line
3. `# Source of truth: ...` meta line
4. `# Propagated to:   ...` meta line
5. `#` (empty comment separator line)

Everything below those 5 lines is treated as docstring/code and preserved in the generated output. `@@VAR@@` placeholders in the preserved content are substituted per `propagate.config`.

**Why count-based stripping (not blank-line-based)?**

Earlier versions of the engine stripped "from `# TEMPLATE FILE` until the first blank line." This silently broke when a template's docstring had no blank line between the meta-block and the first comment line — the engine would keep stripping comment lines until it hit `set -euo pipefail`, deleting the entire docstring. Caught during family pilot adoption (Session #10) when `check_sync.sh` propagated without its newly-rewritten docstring. Fixed in PR #8 with explicit count-based stripping.
