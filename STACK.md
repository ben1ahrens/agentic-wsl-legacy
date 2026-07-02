# STACK.md — Environment briefing for AI agents

This document orients an AI coding agent (Claude Code or any other) operating inside this
machine's WSL2 development environment. It explains the topology, toolchain, identity model,
secrets model, and the **hard rules** you must follow so you don't break things or leak secrets.

**Source of truth:** the live environment is authoritative — `35-verify-setup.sh` (read-only health
check) and the managed blocks in `~/.zshrc` reflect reality; this file is a snapshot (last verified
2026-06-29). If this doc names a file, flag, or command, confirm it still exists before relying on it.

---

## ⚠️ Operating rules — read first

1. **Code lives on ext4 under `~/projects`, never under `/mnt/c`.** The 9P bridge is slow and breaks
   file watching. Clone, scaffold, and build only under `~/projects/<profile>/...`.
2. **Secrets never touch the WSL disk.** Don't hardcode tokens/keys, don't commit them, don't write
   them to files. Resolve them at runtime from 1Password (`op.exe`) or a **gitignored** `.env`
   produced by `openv`. A Windows Hello prompt once per session is normal and expected.
3. **Git identity follows the directory.** A repo's account, signing key, and SSH key are decided by
   which `~/projects/<profile>` folder it sits in (`work` / `personal` / `imperial`). **Never set a
   global git identity.** Create new repos *inside* the correct profile folder.
4. **Don't hand-edit `~/.zshrc` blocks.** Shell config is owned by scripts via `# >>> name >>>`
   managed blocks. To change it, edit the owning script and re-run it (they're idempotent, back up
   first, and support `--dry-run`). See §7.
5. **Toolchain is fixed:** Python via **uv**, Node via **fnm**, plus **Bun**. Do **not** `apt install`
   node/python or use system pip. GPU ML uses **PyTorch on the `cu128` wheel index** (no TensorFlow).
6. **Commits are SSH-signed** and should show **Verified** on GitHub. Don't disable signing.

---

## 1. Topology — Windows hosts the hardware & vault; WSL holds the code

| Layer | Lives on | Notes |
|------|----------|-------|
| GPU driver, 1Password app, Docker Desktop, editor UI | **Windows 11** | RTX 5070 Ti (Blackwell `sm_120`), CUDA 12.9 driver |
| All code, tools, dependencies, runtimes | **WSL2 / Ubuntu 24.04** (ext4) | systemd on, **zsh** login shell |
| Editor | **VS Code on Windows + WSL remote** | you edit `~/projects/...` from inside WSL |

Host: Intel Core Ultra 9 275HX, ~15 GiB RAM to WSL. Windows Terminal. 1Password unlocks via Windows Hello.

Windows↔WSL interop you'll use: `op.exe` (1Password CLI), `clip.exe` (clipboard), `explorer.exe`,
`cmd.exe`/`rundll32.exe` (via the `wopen` helper), `npiperelay.exe` + `socat` (SSH-agent bridge).

## 2. Filesystem & projects

```
~/projects/
  work/       → GitHub @bahrens213   (profile: work)
  personal/   → GitHub @ben1ahrens   (profile: personal)
  imperial/   → GitHub @ba822        (profile: imperial)
```

The setup scripts themselves live at `~/projects/personal/agentic-wsl/agentic-wsl/`.

## 3. Toolchain

| Tool | Provided by | Location | Notes |
|------|-------------|----------|-------|
| Python (3.12 / 3.13) | **uv** | `~/.local/bin` | `uv sync`, `uv run`, `uvx`; never system pip |
| Node (LTS) | **fnm** | `~/.local/share/fnm` | auto-switches per dir; Windows Node is pruned from PATH |
| Bun | bun | `~/.bun` | alongside Node |
| AWS CLI v2 | binary | PATH | `aws sso login` (SSO not yet configured) |
| starship, zoxide, direnv, bat, eza, gitleaks, fzf | Homebrew | `/home/linuxbrew` | `z` (zoxide), `direnv` auto-activates venvs |
| ripgrep (`rg`), fd | apt/brew | PATH | `grep`→`rg`, `find`→`fd`, `cat`→`bat`, `ls`→`eza` are interactive aliases |
| pre-commit | uv tool | `~/.local/bin` | |

Run `35-verify-setup.sh` for exact versions and live resolution checks.

## 4. Multi-account git (directory-based identity)

Three GitHub accounts, selected by directory:

| Profile | Folder | GitHub login | SSH host alias |
|---------|--------|--------------|----------------|
| work | `~/projects/work` | @bahrens213 | `github-work` |
| personal | `~/projects/personal` | @ben1ahrens | `github-personal` |
| imperial | `~/projects/imperial` | @ba822 | `github-imperial` |

- **Identity & signing:** `~/.gitconfig` uses `includeIf "gitdir:~/projects/<profile>/"` → per-profile
  `~/.config/git/<profile>.gitconfig` (name, no-reply email, SSH signing key, `commit.gpgsign=true`).
  Signing uses 1Password's `op-ssh-sign-wsl.exe`. Global identity is intentionally blank.
- **Push/clone:** clone with the host alias, e.g. `git clone git@github-work:org/repo.git`. A
  `url.insteadOf` rewrite maps `github.com` → the profile's alias inside each profile dir.
- **gh CLI:** authenticated for all three accounts. A `chpwd` hook switches `gh`'s active account to
  match the folder and **clears stray `GH_TOKEN`/`GITHUB_TOKEN`** (which would otherwise override it).
- **Cross-check:** run `ghwho` to confirm `gh`'s active account matches the current folder.

**Agent rule:** to start a new project, `cd ~/projects/<profile>` first, then create/clone there — it
inherits the right identity automatically. Don't `git config --global user.email`.

## 5. Secrets — 1Password owns everything

- `op` is aliased to **`op.exe`** (the Windows 1Password CLI over interop; unlocks via Windows Hello).
- SSH **private keys never leave 1Password**; the SSH agent is bridged into WSL (`socat` + `npiperelay.exe`),
  so `git push`/signing work without keys on disk.
- **Patterns (use these; don't reinvent):**
  - `openv` → `op inject` renders a **gitignored** `./.env` from `./.env.tpl`, once per session.
  - `oprun <cmd>` → runs a process with secrets injected, **zero plaintext on disk**.
  - `opget <op://ref>` / `opcp <op://ref>` → read / clipboard-copy a single secret.
  - `opadd "<Title>"` → store a new secret (API Credential) via a hidden prompt.
- `.env` / `.env.tpl` conventions: `.env` is always gitignored; `.env.tpl` holds `op://` references and
  is safe to commit.

**Agent rule:** if you need a secret, reference it from 1Password or the session `.env`. Never echo a
secret into code, logs, history, or a committed file.

## 6. GitHub MCP server

The `github` MCP server is the **remote HTTP plugin** `https://api.githubcopilot.com/mcp/`, which reads
`Authorization: Bearer ${GITHUB_PERSONAL_ACCESS_TOKEN}` from Claude's process env at launch.

- `claude` is a shell wrapper: at launch it reads the **project account's PAT from 1Password**
  (`op://Private/github-mcp-<profile>/credential`) and passes it to that one Claude process only —
  never exported, never on disk. The token is fixed for the session.
- Because it's chosen by the launch directory, **GitHub-MCP acts as the account of the project you
  launched Claude in.** Two sessions in different projects use different tokens — no mixing.
- `ghmcp` / `ghmcp all` validates the tokens: which account each authenticates as, expiry, scopes, and
  whether it matches the profile. Run it if MCP "fails to connect" or before a PAT expires.
- Quick/management commands (`claude --version`, `update`, `config`, `doctor`) skip the token fetch.

## 7. Shell config conventions (managed blocks)

`~/.zshrc` is assembled from independent **managed blocks**, each delimited by
`# >>> <name> (managed by <script>) >>>` … `# <<< … <<<` and owned by one script:

| Block | Owner script | Provides |
|-------|--------------|----------|
| `comfort-shell` | (user's own) | brew/starship/zoxide/direnv init, aliases, keybindings — **do not touch** |
| `wsl2-dev-setup` | `30-shell.sh` | PATH (uv/fnm/Bun), fnm/fzf init, `op`/`open` aliases, `$BROWSER=wopen`, history |
| `git-profiles` | `40-git-setup.sh` | SSH-agent bridge, `proj`/`work`/`pers`/`icl` nav |
| `gh-profiles` | `45-github-profiles.sh` | per-dir gh account switch, `ghwho` |
| `win-shortcuts` | `48-win-folders.sh` | `dl` / `dls` / `dlcp` / `dlmv` / `dlput` |
| `dev-shortcuts` | `50-shortcuts.sh` | `opget`/`opcp`/`opadd`/`openv`/`oprun`, `mkcd`/`pj`, the `docs` command |
| `github-mcp` | `60-github-mcp.sh` | the `claude` wrapper + `ghmcp` |

**Agent rule:** to change shell behavior, edit the **owning script** and re-run it
(`./<script> --dry-run` first). The script strips and re-appends its block idempotently and backs up
`~/.zshrc` to `~/.local/state/wsl2-dev/backups/`. Never edit another script's block by hand.

## 8. Custom commands (cheatsheet)

Run **`docs`** for the full, always-installed reference (`docs <query>` to filter). Highlights:

- **Secrets:** `opget`, `opcp`, `opadd`, `op` · **Project env:** `openv`, `oprun`
- **GitHub/MCP:** `claude` (token-injecting launcher), `ghmcp` (token health), `ghwho`
- **Nav:** `proj`/`work`/`pers`/`icl`, `pj` (fzf), `mkcd`, `z` (zoxide)
- **Windows bridge:** `open`/`wopen`, `files`, `code`, `dl`/`dls`/`dlcp`/`dlmv`/`dlput`
- **Git/CLI:** `gs`/`ga`/`gc`/`gp`, `ls`/`ll`/`lt`, `cat`/`grep`/`find` (eza/bat/rg/fd)
- **Scaffold/health:** `new-project.sh <name>`, `35-verify-setup.sh`, `docs`

## 9. Setup scripts & conventions

Scripts in the repo are numbered by phase and share strict conventions:

- `10-wsl-base.sh` → `20-tooling.sh` → `30-shell.sh` → `35-verify-setup.sh` (base layer)
- `40-git-setup.sh` / `45-github-profiles.sh` (multi-account git) · `48-win-folders.sh`
- `50-shortcuts.sh` (helpers + `docs`) · `60-github-mcp.sh` (MCP token wrapper + `ghmcp`)
- `new-project.sh` (uv scaffold: cu128 torch, ruff, direnv, Playwright, GPU verify)

Shared conventions every mutating script follows: `set -uo pipefail` (not `-e`; errors handled
explicitly), `--dry-run`/`-n` and `-h`, TTY-guarded color output, **back up before edit**, and
idempotent managed-block edits. Match these when adding or editing a script. See `CLAUDE.md` for the
repo-specific guidance (including a note on numbered-vs-unnumbered git-script copies that have diverged).

## 10. Daily workflow

```bash
cd ~/projects/work/api-service   # directory sets git identity + gh account; direnv activates .venv
openv                            # render ./.env from ./.env.tpl (one Hello prompt)
uv run python main.py            # tools read .env; no further prompts
git commit -am "…"               # SSH-signed with the work identity → Verified
claude                           # launches with the work GitHub PAT injected for MCP
```

## 11. Health & verification

- `35-verify-setup.sh` — read-only check of apt packages, toolchain, shell config, live resolution,
  interop, and the git/MCP preflight. Exit 0 = all critical checks pass.
- `ghmcp all` — confirm each GitHub MCP token authenticates as the right account and isn't near expiry.
- `ghwho` — confirm `gh`'s active account matches the current folder.
- `docs` — the custom-command reference.
