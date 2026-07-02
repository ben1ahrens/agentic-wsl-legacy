# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **Operating in this WSL2 environment?** Read **`STACK.md`** first — it's the full briefing on the
> machine an agent runs inside (Windows↔WSL split, multi-account git, the 1Password secrets model,
> GitHub-MCP, shell conventions, and the hard guardrails). `CLAUDE.md` covers *this repo*; `STACK.md`
> covers the *environment* every project lives in.

## What this repo is

A set of standalone, idempotent **bash provisioning scripts** that build a reproducible WSL2
(Ubuntu 24.04) dev environment for software/ML/agentic-coding work. There is **no application,
build system, package manifest, or test suite** — each `*.sh` file is a self-contained installer
run directly on the target machine. The Markdown files (`README.md`, `PROJECT-STATUS.md`,
`wsl2-dev-environment-setup.md`, `docs/design-notes.md`) are the design record, not code.

`README.md` is the authoritative run guide; `PROJECT-STATUS.md` tracks what has actually been run
on the machine vs. only sandbox-validated. Read both before changing behavior.

## Running / "testing" scripts

There are no unit tests. The verification surface is:

- **`./35-verify-setup.sh`** — read-only health check (sections A–F). Run it to confirm the
  environment is intact; exit 0 means all critical checks passed. `--open-browser` also fires a
  live `wopen` test. This is the closest thing to a test harness — after editing any installer,
  re-run this to confirm nothing regressed.
- **`<script> --dry-run`** (alias `-n`) — every *mutating* script previews its actions and changes
  nothing. This is the safe way to inspect what an edit will do. `35-verify-setup.sh` has no
  `--dry-run` because it is already read-only.
- **`<script> --help`** / `-h` — prints the header comment block (implemented as `sed -n '2,NNp' "$0"`).

Intended run order (from `README.md`):

```
./10-wsl-base.sh → ./20-tooling.sh → ./30-shell.sh → exec zsh → ./35-verify-setup.sh   # Phase 1
./40-git-setup.sh → exec zsh → ./45-github-profiles.sh → exec zsh                            # Phase 2
./48-win-folders.sh   (optional)   |   cd ~/projects/<profile> && ./new-project.sh <name>  # Phase 3
```

## Conventions every script must follow

These are load-bearing — match them exactly when adding or editing a script, because the design
guarantees (re-runnable, reviewable, reversible) depend on them:

- **`set -uo pipefail`, never `set -e`.** Mutating scripts handle errors explicitly (check, print
  via the helpers below, `exit 1`) rather than dying silently. (`wopen.example` is the one exception
  — it uses `set -euo pipefail` because it's a tiny helper.)
- **`--dry-run` is mandatory** for anything that mutates. In dry-run it must simulate (e.g. `apt -s`,
  "would run: …") and touch nothing.
- **Back up before editing** any existing file. All scripts use the centralized `backup_file`
  helper — copies go to `~/.local/state/wsl2-dev/backups` (newest 5 kept per file).
  `tidy-backups.sh` sweeps any legacy scattered `<file>.bak.<timestamp>` strays into it.
- **Idempotent: safe to re-run.** Installs are no-ops if present; config edits strip-and-reappend.
- **TTY-guarded color helpers.** Detect `[ -t 1 ]`, then define `say/ok/warn/err/note` (installer
  style) or `pass/warn/fail/info/hdr` (verify style). End with a **summary** section.

### Managed blocks (how config files are edited)

Scripts never append loosely to `~/.zshrc` etc. — they own a **named block** delimited by
`# >>> <name> (managed by <script>) >>>` … `# <<< <name> (managed by <script>) <<<`, and re-running
strips the old block and re-appends a fresh one (so edits never duplicate). Ownership map:

| Block | Owner | Don't touch |
|-------|-------|-------------|
| `comfort-shell` | the **user's** pre-existing block | yes — leave it untouched |
| `wsl2-dev-setup` | `30-shell.sh` | |
| `git-profiles` | `40-git-setup.sh` | |
| `gh-profiles` | `45-github-profiles.sh` | |
| `win-shortcuts` | `48-win-folders.sh` | |
| `dev-shortcuts` | `50-shortcuts.sh` | |
| `github-mcp` | `60-github-mcp.sh` | |

`20-tooling.sh` is deliberately the exception that makes **no permanent** shell change: it snapshots
the rc files and restores them on exit. The strip logic is keyed on the block *name* (tolerant of
markers written under older script names) and stops at the next `# >>> ` opener or EOF if a block's
end marker is missing — keep that property when touching `strip_block`/`insert_block`/`assemble`.

## Design invariants (constrain what edits are acceptable)

- **Windows hosts hardware + vault; WSL holds all code.** Don't add steps that put projects/tools
  under `/mnt/c` (the 9P bridge is slow and breaks file watching) — everything lives on ext4 under
  `~/projects`.
- **Secrets never hit the WSL disk.** SSH private keys are created in the 1Password app; only `.pub`
  files are pulled (via `op`). Long-lived secrets resolve via `op inject`/`op run` into a gitignored
  `.env` once per session — never per-`cd` (`docs/design-notes.md` explains why that was the original design flaw).
- **Git identity follows the directory.** Which GitHub account, signing key, and SSH key a repo uses
  is decided by which `~/projects/<profile>` folder it's in (`includeIf "gitdir:"` for identity/signing,
  `github-<label>` SSH host aliases for keys). This model was chosen specifically because Claude Code
  operates per-directory and spawns subshells.
- **PyTorch via the `cu128` wheel index** for the Blackwell RTX 5070 Ti — `new-project.sh` pins torch
  through `[[tool.uv.index]]` + `[tool.uv.sources]` (not `--torch-backend`, which is pip-only).
- **uv is the single Python tool; fnm manages Node; Bun is added alongside.** A known hazard is the
  Windows Node leaking onto PATH — `30-shell.sh` prunes it and `35-verify-setup.sh` section D asserts
  `node`/`npm` resolve to fnm with no `/mnt/c` path.

## History note

Until 2026-07-02 the git/GitHub scripts existed as diverged numbered + unnumbered copies; they were
reconciled into the single numbered pipeline above (`40-git-setup.sh`, `45-github-profiles.sh`,
`48-win-folders.sh` — formerly `link-windows-folders.sh`). This repo is the **only** canonical
location for the scripts — don't create deployment copies elsewhere; installed commands go to
`~/.local/bin` via their owning script.
