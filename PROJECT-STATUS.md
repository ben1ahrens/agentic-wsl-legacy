# Project Status — WSL2 ML-Research Environment

**Last updated:** 2026-07-02 (redesign built & verified live)

> A reproducible, scripted WSL2 (Ubuntu 24.04) research workstation for ML, software, and
> agentic-coding work. **The full redesign is built, run, and verified on the machine**:
> base layer, git/GitHub identity, ML layer (cu130 PyTorch, HF stack, trackio), the
> three-agent fleet (Claude Code · Codex · Claude Science), the Notion knowledge graph,
> and the polish layer (bootstrap, dashboard, notifications, persistent runs).
> `35-verify-setup.sh`: **70 passed / 0 warnings / 0 failed.** This file tracks state and
> decisions; `README.md` is the run guide; `STACK.md` briefs agents on the environment.

---

## Status at a glance

| Layer | Components | State |
|-------|-----------|-------|
| Base system | `10-` `20-` `30-` `35-` | ✅ Run & verified (atuin + GL diagnostics added) |
| Git & GitHub | `40-` `45-` | ✅ Run & verified — 3 profiles, SSH-signed commits **confirmed Verified on GitHub end-to-end** (2026-07-02) |
| Windows bridge | `48-win-folders.sh` | ✅ Run — damaged `win-shortcuts` block repaired by the hardened strip |
| Shortcuts & research | `50-shortcuts.sh` | ✅ Run — `train`/`nb` + `docs`/`notify`/`lab`/`onboard` installed and live-tested |
| GitHub MCP | `60-github-mcp.sh` | ✅ Run (pre-redesign); wrapper pattern extended to Codex |
| Agent fleet | `65-agent-fleet.sh` | ✅ Run — Claude sandbox on (network allowlist, gh-token blocking), config-guard hook, Codex MCP + AGENTS.md, `codexr`, 3 skills installed |
| Claude Science | `70-claude-science.sh` | ✅ Run — app installed (0.1.15-dev), `science` launcher live |
| Scaffold | `new-project.sh` | ✅ **Exercised for real**: `ml-sandbox` created with `--ml`; torch **2.12.1+cu130**, sm_120 kernels verified on the GPU |
| Knowledge graph | Notion "Research Hub" | ✅ Built — Papers ↔ Ideas ↔ Projects ↔ Experiments (dual relations); Projects seeded; `paper` / `log-experiment` skills installed |
| Bootstrap | `00-bootstrap.sh` | ✅ Written (dry-run validated); full cold-start run only possible on a fresh machine |
| Finishing | AWS SSO / cloud burst | 🔴 **Deferred by design** — "local-first, cloud later"; Claude Science's SSH/Modal connectors are the planned burst path |

## Machine (audited 2026-07-02)

- Windows 11 + WSL2 (kernel 6.6.114), Ubuntu 24.04.4, systemd on, zsh; 20 vCPU / ~20 GiB; NAT networking
- **RTX 5070 Ti Laptop (12 GB, sm_120)** — driver **592.01 = CUDA 13.1** (was 12.9 in June)
- Docker Desktop 29.5.2 with the **NVIDIA container runtime registered**
- Toolchain: uv 0.11.23 (py 3.12/3.13), fnm + Node 24, Bun 1.3.14, gh 2.95, brew CLIs + **atuin**,
  claude 2.1.198, codex 0.142.2, claude-science 0.1.15
- Three GitHub profiles (work @bahrens213 · personal @ben1ahrens · imperial @ba822), all verified

## Key decisions (current)

- **PyTorch on the `cu130` wheel index** — re-decided 2026-07-02: cu128 was removed from
  PyTorch's build matrix (Apr 2026) and is frozen at torch 2.11.x; current stable is 2.12.x
  on cu130 with native sm_120, and the driver (CUDA 13.1) satisfies it. Verified empirically:
  the old cu128 test project resolved exactly 2.11.0; the new cu130 scaffold resolved 2.12.1
  and ran real kernels on the GPU.
- **Directory-based identity** (unchanged, verified): `includeIf gitdir:` + SSH host aliases;
  extended to the whole fleet (per-profile GitHub-MCP PATs for Claude; Codex reviews read-only).
- **1Password owns secrets** (unchanged): only `.pub` keys and gh's own oauth file touch disk;
  the Claude sandbox additionally denies `~/.config/gh` and the GH token env vars to Bash.
- **Managed blocks, hardened**: strip logic is keyed on the block *name*, tolerates markers
  from older script names, and stops at the next `# >>> ` opener if a closer is missing —
  a damaged block can no longer swallow its neighbours. Verify section J checks marker pairs.
- **Backups centralized** everywhere: `~/.local/state/wsl2-dev/backups` (newest 5/file).
- **One canonical script set**: numbered pipeline in this repo only; commands install to
  `~/.local/bin`; the diverged copies and `~/projects/scripts/` deployment copies are gone.
- **Agent posture**: Claude Code native sandbox on (bubblewrap; network allowlist; credential
  blocking; config-guard hook protecting `~/.zshrc`/`~/.gitconfig`/`~/.ssh/config`); Codex is
  the second-opinion reviewer, always `--sandbox read-only`; both read one AGENTS.md brief
  (Claude via `@AGENTS.md` import — it does not read AGENTS.md natively).
- **Local-first tracking**: trackio (HF; wandb-style API, local dashboard) in the `--ml`
  scaffold; metrics stay local, the *narrative* goes to the Notion Experiments database.
- **GUI**: Windows-first via wrappers (`wopen`, localhost forwarding); WSLg only where forced
  (Claude Science). GL is diagnosed (verify section I), not tuned — no need demonstrated yet.

## Verified end-to-end this session (2026-07-02)

1. Signed commit → push → **GitHub `verified: true`** (the badge path had never been tested).
2. `new-project.sh --ml` → uv sync resolved **torch 2.12.1+cu130** → `verify_gpu.py`:
   sm_120 detected, 4096² matmul executed on the RTX 5070 Ti.
3. Damaged `win-shortcuts` block repaired live by the hardened strip (7/7 marker pairs after).
4. Windows toast fired from WSL via `notify` (PowerShell WinRT — no installs needed).
5. `lab` dashboard renders GPU/disk/caches/tmux/docker/Claude Science live.
6. Notion graph created via MCP with dual relations; Projects seeded with 3 repos.
7. Full verify: **70 / 0 / 0**, exit 0.

## Remaining / deferred

- [ ] `sudo apt install -y mesa-utils glmark2` — approved but needs your password (verify
      section I then reports the GL renderer; run `./10-wsl-base.sh` on rebuilds).
- [ ] First signed commit in `ml-sandbox` (scaffold suggests it at the end).
- [ ] Claude Science first sign-in (`science` → claude.ai login, paid plan) and a real session.
- [ ] AWS SSO / Modal burst path — deferred by design; revisit when a job outgrows 12 GB.
- [ ] GL benchmark decision (once glmark2 is installed) — invest in GPU-GL only if numbers hurt.
- [ ] `wsl2-dev-environment-setup.md` (the 16-section tutorial) predates the redesign — the
      narrative is still sound but its file names/phases lag README.md, which is authoritative.

## See also

- **`README.md`** — entry point: file table, host prep, run order (or just `./00-bootstrap.sh`).
- **`STACK.md`** — the environment briefing agents read first.
- **`docs/design-notes.md`** — original design-rationale transcript (historical).
