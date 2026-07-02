# Project Status — WSL2 Dev Environment

**Last updated:** 2026-06-29

> A reproducible, scripted WSL2 (Ubuntu 24.04) dev environment for software, ML, and
> agentic-coding work. **The base layer AND the git/GitHub + Windows-bridge layers are now
> built, run, and verified on the machine** — live audit on 2026-06-29 confirms all three
> GitHub profiles authenticate over SSH, directory-based identity + commit signing resolve
> correctly, and the 1Password agent bridge works end-to-end. **The only substantive item
> still outstanding is AWS SSO**; `new-project.sh` remains effectively unexercised.
> This file tracks state and decisions; see `README.md` for how to run everything.

---

## Status at a glance

| Layer | Components | State |
|-------|-----------|-------|
| Base system | `10-wsl-base.sh`, `20-tooling.sh`, `30-shell.sh`, `35-verify-setup.sh` | ✅ **Run & verified on the machine** — 58 passed / 1 warning / 0 failed |
| Git & GitHub | `40-git-setup.sh`, `45-github-profiles.sh` | ✅ **Run & verified** — 3 profiles authenticate over SSH; identity + signing resolve per-directory |
| Conveniences | `48-win-folders.sh` | ✅ **Run** — `win-shortcuts` block present in `~/.zshrc` |
| Per-project scaffold | `new-project.sh` | 🟡 Built & sandbox-validated — **not yet exercised** on a real cu128 project |
| Finishing | AWS SSO (`aws configure sso`) | 🔴 **Not started** — no `~/.aws/config` yet |
| Documentation | tutorial, `README.md`, this file | ✅ Complete |

## Goal & guiding principle

**Windows hosts the hardware and the vault; WSL2 holds all the code.** The GPU driver,
1Password, Docker Desktop, and the editor UI live on Windows; every project, dependency, and
tool lives on the Linux ext4 filesystem under `~/projects` (never `/mnt/c`); secrets stay in
1Password and never touch the WSL disk.

## Machine (audited)

- Windows 11 (build 10.0.26200.8655) + WSL 2.7.3, **Ubuntu 24.04**, systemd on, **zsh** login shell
- Intel Core Ultra 9 275HX (24 vCPU), ~15 GiB RAM to WSL
- **RTX 5070 Ti** Laptop GPU (12 GB, Blackwell `sm_120`) — confirmed via `nvidia-smi`, CUDA 12.9 driver
- Docker Desktop w/ WSL integration; Windows Terminal; 1Password desktop app (Windows Hello)
- Three GitHub accounts → directory-based profiles: `work` (@bahrens213), `personal` (@ben1ahrens),
  `imperial` (@ba822) — **all three authenticated via `gh` and confirmed authenticating over SSH**
  (`ssh -T git@github-{work,personal,imperial}` each greets the right account)

---

## Deliverables (scripts live in this repo)

| File | Type | Status |
|------|------|--------|
| `wsl2-dev-environment-setup.md` | Tutorial (16 sections) | ✅ Complete |
| `README.md` | Entry-point guide | ✅ Complete |
| `PROJECT-STATUS.md` | This status doc | ✅ Complete |
| `10-wsl-base.sh` | apt base + essentials | ✅ Run & verified |
| `20-tooling.sh` | uv, fnm/Node, Bun, AWS CLI, brew tools, pre-commit | ✅ Run & verified |
| `30-shell.sh` | `~/.zshrc` managed block | ✅ Run & verified |
| `35-verify-setup.sh` | Read-only health check (6 sections) | ✅ Run — 58/1/0 |
| `40-git-setup.sh` | Multi-account git: keys, identity, signing, folders, shortcuts | ✅ **Run & verified** |
| `45-github-profiles.sh` | `gh` auth + key upload (auth+signing) + directory hook | ✅ **Run & verified** |
| `48-win-folders.sh` | Symlink Downloads/OneDrive + download helpers + projects nav | ✅ **Run** |
| `new-project.sh` | uv scaffold (cu128 torch, ruff, direnv, Playwright) + GPU verify | 🟡 Validated, not exercised |

> **Note on filenames.** The base scripts are numbered (`10-`, `20-`, `30-`, `35-`); the git/GitHub
> scripts also exist as numbered copies (`40-git-setup.sh`, `45-github-profiles.sh`) that have
> diverged from the unnumbered canonical versions. Files referenced in older drafts
> (`artifact-editing.skill`, `wsl2-audit.sh`, `wsl2-inventory-graph.sh`, `wt-profile-diff.py`) are
> not present in this repo. See `CLAUDE.md` for the full inconsistency note.

## What's verified vs. what's pending  *(live audit 2026-06-29)*

- **Base system — verified.** `35-verify-setup.sh` returned **58 passed, 1 warning, 0 failed**.
  The live-shell section confirmed `node`/`npm` resolve to the fnm shim with **no `/mnt/c` leak**,
  the GPU is detected (RTX 5070 Ti), and Docker is reachable. All tooling present at current
  versions (uv 0.11.23, fnm 1.39 + Node v24.17, Bun 1.3.14, AWS CLI 2.35.9, starship/zoxide/
  direnv/bat/eza/gitleaks, Homebrew fzf 0.73.1).
- **Windows interop bridge — verified live.** `op.exe` (2.34.1) reachable; the OpenSSH agent pipe
  is served by 1Password (the competing Windows `ssh-agent` service is not running);
  `npiperelay.exe` + `socat` both present; `op-ssh-sign-wsl.exe` present on the Windows side.
- **Git & GitHub — run & verified.**
  - `~/.ssh/config` has all three host aliases (`github-{work,personal,imperial}`) pinned to the
    matching `~/.ssh/<profile>.pub`; all three `.pub` keys present.
  - `~/.gitconfig` carries the `git-profiles` managed block with `includeIf "gitdir:"` for all
    three profiles + the non-identity defaults, plus the `gh` credential helper. Per-profile
    `~/.config/git/{work,personal,imperial}.gitconfig` exist with identity + SSH signing.
  - **Directory-based identity confirmed resolving** in real repos: a repo under `~/projects/work`
    signs as `bahrens213` and one under `~/projects/personal` as `ben1ahrens`, both with
    `commit.gpgsign=true`. (Global identity is intentionally blank — it's set per-directory.)
  - **All three accounts authenticated via `gh`** (scopes include `admin:public_key` +
    `admin:ssh_signing_key`) and **all three authenticate over SSH** (`ssh -T` greets each account).
  - The `_ghprofile_chpwd` directory hook (`gh-profiles` block) and the `win-shortcuts` block are
    both installed in `~/.zshrc`. The four expected managed blocks are present:
    `comfort-shell` (yours), `wsl2-dev-setup`, `git-profiles`, `gh-profiles`, `win-shortcuts`.
- **Pending — AWS SSO.** No `~/.aws/config` yet; `aws configure sso && aws sso login` not run.
- **Pending — `new-project.sh`.** Not yet exercised on a real cu128 project. The one populated work
  project (`rngrns-project2`) uses a **CPU-only** torch index and was clearly hand-built, not
  produced by this scaffold; `~/projects/personal/test` is an empty leftover folder.

---

## Key decisions (locked in)

- **Multi-account git is directory-based.** Identity, signing key, and SSH key follow which
  `~/projects/<profile>` folder a repo lives in — `includeIf "gitdir:"` for identity/signing,
  SSH host aliases (`github-<label>`) for keys. Chosen because it's the most robust model for
  **Claude Code**, which operates per-directory and spawns subshells.
- **1Password is the source of truth.** SSH private keys are created in the app and never hit
  the WSL disk (only `.pub` files do). Long-lived secrets resolve via `op inject` into a
  gitignored `.env`, **once per session**. The `SSH_AUTH_SOCK` bridge (socat + `npiperelay.exe`)
  is what lets the agent reach Claude Code's subshells.
- **PyTorch via the `cu128` CUDA wheel index** for Blackwell. Re-verified against current docs:
  torch is **2.9.x**, projects must use `[[tool.uv.index]]` + `[tool.uv.sources]` (not
  `--torch-backend`, which is pip-only), and **cu128 is correct for the 12.9 driver** (cu130
  would need a CUDA-13 driver).
- **Managed-block convention everywhere.** Config additions live between markers, are
  **idempotent** (re-run replaces, never duplicates), **back up** what they touch, and support
  **`--dry-run`**. `~/.zshrc` ends up with independent blocks: `comfort-shell` (yours),
  `wsl2-dev-setup`, `git-profiles`, `gh-profiles`, `win-shortcuts`.
- **Other choices:** `appendWindowsPath` kept (Windows-Node leak fixed via fnm + a PATH prune);
  `wslu` not used (replaced by a `wopen` helper); **TensorFlow excluded**, PyTorch only; **uv**
  as the single Python tool; **Bun** added alongside Node; Docker Desktop kept; `gh` installed
  via Homebrew (offered by `40-git-setup.sh`).

## Issues resolved this session

- **`unknown option: --zsh` on shell start** — Ubuntu's apt `fzf` (0.44) predates `--zsh`.
  Fixed by making the `.zshrc` line version-robust and installing `fzf` via Homebrew.
- **git-setup pre-flight** — added Section F to `35-verify-setup.sh` (1Password CLI, the agent
  pipe, a check for the competing Windows `ssh-agent` service, `npiperelay.exe`, `gh`).
- **1Password CLI install** — corrected to `winget install 1password-cli`; clarified that the
  "Integrate with 1Password CLI" toggle connects the CLI but doesn't install it, and what
  "Unlock using system authentication" (Windows Hello) does.
- **PATs can't be script-generated** — GitHub has no token-creation API, so `45-github-profiles.sh`
  defaults to gh's browser login (no PAT) and offers a pre-filled token page as the alternative.
- **OneDrive vault typo (`WSL-Dev` vs `Private`)** — confirmed it's only a lookup path, not a
  stored setting; nothing to undo.

---

## Remaining work — execution checklist

Most of this is now done (✅ confirmed by the 2026-06-29 audit). Only the unchecked items remain.

**Windows host (once)** — ✅ all confirmed present via the verify pre-flight
- [x] 1Password app: **Use the SSH agent**, **Integrate with 1Password CLI**, **Unlock using system authentication** (agent pipe served; `op.exe` reachable)
- [x] `winget install 1password-cli`
- [x] `winget install albertony.npiperelay`  (the SSH-agent bridge — present)
- [x] Cursor / VS Code + the **WSL** extension *(assumed — editing happens from WSL; not separately probed)*

**Git & GitHub (in WSL)** — ✅ run & verified
- [x] `./35-verify-setup.sh` — Section F all ✓/·, no ✗
- [x] `./40-git-setup.sh` — keys, SSH config, identity, folders, shortcuts; `gh` installed (2.95.0)
- [x] `./45-github-profiles.sh` — gh auth for all 3 accounts, keys uploaded (auth + signing), directory hook installed
- [x] Tested: `ssh -T git@github-{work,personal,imperial}` each greets the right account
- [ ] Make one **Verified** signed commit + push to confirm the green badge end-to-end *(signing is configured and SSH works; this repo currently has only staged files, no commit yet)*

**Conveniences & per project**
- [x] `./48-win-folders.sh` — `win-shortcuts` block installed
- [ ] `cd ~/projects/work && ./new-project.sh <name>` — scaffold + install + GPU/Playwright verify *(not yet exercised; `~/projects/personal/test` is an empty leftover to clean up)*

**Finishing (manual)**
- [ ] `aws configure sso && aws sso login` — **not started** (no `~/.aws/config`)

## Known loose ends (non-blocking)

- The **1 warning** in the verify run: `~/.zshrc` still has the original bare `fzf --zsh` line.
  Harmless — section D confirms `fzf --zsh` works live (Homebrew fzf supports it). Re-run
  `./30-shell.sh` to swap in the hardened line if you want the warning gone.
- **Empty `~/projects/personal/test` folder** — a leftover; safe to `rmdir`.
- **Numbered vs unnumbered git scripts have diverged** (`40-git-setup.sh`/`45-github-profiles.sh`
  vs the canonical `40-git-setup.sh`/`45-github-profiles.sh`) — reconcile or delete the stale copies so a
  future re-run can't pick the wrong one. See `CLAUDE.md`.
- The projects shortcuts in `48-win-folders.sh` duplicate `40-git-setup.sh`'s — identical
  `cd` aliases, so harmless; use `--no-projects-shortcuts` to skip if preferred.

## See also

- **`README.md`** — the entry point: file table, host prep, the four-phase run order, per-script reference.
- **`wsl2-dev-environment-setup.md`** — the full narrative, every decision and verification step.
