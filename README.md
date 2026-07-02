# WSL2 Dev Environment

A reproducible, production-grade **WSL2 (Ubuntu 24.04)** development environment for software,
ML, and agentic-coding work — built from a small set of **idempotent, backed-up** scripts.
This file is the entry point: it explains what each script does and the exact order to run them.

---

## Design in one line

**Windows hosts the hardware and the vault; WSL2 holds all the code.**
The GPU driver, 1Password, Docker Desktop, and your editor's UI live on Windows. Every project,
dependency, and tool lives on the Linux ext4 filesystem under `~/projects` — **never** under
`/mnt/c` (the 9P bridge is slow and breaks file watching). Secrets stay in 1Password and are
**never written to the WSL disk**: the SSH agent forwards keys in, and `op inject` resolves
secrets into a gitignored `.env` once per session.

## Target machine (what the setup assumes)

- Windows 11 + WSL2, **Ubuntu 24.04**, systemd on, **zsh** login shell, Windows Terminal
- **RTX 5070 Ti** (Blackwell, `sm_120`) — PyTorch via the **cu128** CUDA wheel index
- Docker Desktop with WSL integration enabled
- 1Password desktop app (Windows Hello)
- Three GitHub accounts → **directory-based** git profiles: `work`, `personal`, `imperial`

## What's in this folder

| File | Purpose |
|------|---------|
| `10-wsl-base.sh` | apt full-upgrade + build essentials (incl. `socat`, `bubblewrap`); masks the tty getty |
| `20-tooling.sh` | installs uv (+Python 3.12/3.13), fnm (+Node LTS), Bun, AWS CLI v2, brew CLI tools, pre-commit — **no shell-config changes** |
| `30-shell.sh` | writes one complementary `~/.zshrc` block (PATH, fnm/Bun, Windows-node prune, fzf, `op`/`open` aliases) |
| `35-verify-setup.sh` | **read-only** health check across the whole stack, plus a git-setup pre-flight |
| `40-git-setup.sh` | interactive multi-account git: 1Password keys, SSH host aliases, per-directory identity + signing, folders, shortcuts |
| `45-github-profiles.sh` | authenticates `gh` per account, uploads each key (auth + signing), installs a directory-aware shell hook |
| `48-win-folders.sh` | symlinks Windows Downloads/OneDrive into `~`, adds `dl`/`dls`/`dlcp`/`dlmv`/`dlput` helpers |
| `50-shortcuts.sh` | workflow shortcuts: 1Password helpers (`opget`/`opcp`/`opadd`/`openv`/`oprun`), nav (`mkcd`/`pj`), the `docs` cheatsheet command |
| `60-github-mcp.sh` | per-profile GitHub-MCP tokens: the `claude` launcher wrapper + `ghmcp` token health check |
| `new-project.sh` | scaffolds a uv project (PyTorch cu130, ruff, direnv, 1Password, Playwright) and verifies the GPU |
| `tidy-backups.sh` | maintenance: sweeps legacy scattered `*.bak.*` strays into the central backup dir |
| `wsl2-dev-environment-setup.md` | the full 16-section tutorial — the narrative and rationale behind these scripts |

> **This repo is the canonical script location** — clone it and run scripts from here (they're
> already executable). Every mutating script supports `--dry-run`, backs up anything it edits to
> `~/.local/state/wsl2-dev/backups/`, and is safe to re-run.

---

## Before you start — Windows host setup (once)

These are outside WSL and only you can do them. Several are likely already done.

1. **WSL2 + Ubuntu 24.04** installed; global settings applied via the **WSL Settings** app.
2. **NVIDIA driver** for the RTX 5070 Ti (Game Ready / Studio). Verify in WSL: `nvidia-smi`.
3. **Docker Desktop** → Settings → Resources → WSL integration → enable for your distro.
4. **1Password**: install the CLI and turn on three toggles.
   ```powershell
   winget install 1password-cli
   ```
   Then in the app: **Settings → Developer → Use the SSH agent**, **Integrate with 1Password CLI**,
   and **Settings → Security → Unlock using system authentication** (Windows Hello).
5. **npiperelay.exe** — the Windows side of the SSH-agent bridge:
   ```powershell
   winget install albertony.npiperelay
   ```
6. **Editor**: Cursor or VS Code on Windows + the **WSL** extension (you open `~/projects/...` from inside WSL).

---

## Run order

### Phase 1 — base system (in WSL)

```bash
./10-wsl-base.sh        # apt base layer + essentials
./20-tooling.sh         # uv, fnm/Node, Bun, AWS CLI, brew tools, pre-commit
#   ↑ review what it installed
./30-shell.sh           # adds the managed ~/.zshrc block
exec zsh                # reload the shell
./35-verify-setup.sh       # health check — sections A–D should be all ✓
```

`20-tooling.sh` makes **zero** permanent shell changes (it snapshots and restores your rc files);
`30-shell.sh` is the only one that edits `~/.zshrc`, and it adds a *complementary* block that leaves
your existing `comfort-shell` block untouched.

### Phase 2 — git & GitHub

First confirm the 1Password **SSH agent** and **CLI integration** are on (Phase 0 step 4), then:

```bash
./35-verify-setup.sh       # Section F (git-setup pre-flight) should be ✓/·, no ✗
./40-git-setup.sh          # → pauses for you to create each ed25519 key in the 1Password app
#   builds: ~/.ssh/config aliases, per-profile identity+signing, ~/projects/<profile> folders,
#   zsh shortcuts, the SSH_AUTH_SOCK bridge; offers to `brew install gh`
exec zsh
./45-github-profiles.sh    # gh auth per account (browser or PAT), uploads keys, installs the directory hook
exec zsh
```

Then test each profile:
```bash
work && ssh -T git@github-work          # should greet your work account
git -C ~/projects/work/<repo> commit …  # commits show as Verified on GitHub
```

### Phase 3 — per project

Run from **inside** a profile folder so the new repo inherits that identity automatically:

```bash
cd ~/projects/work
./new-project.sh my-thing               # scaffold + install + GPU/Playwright verify
./new-project.sh my-thing --dry-run     # or preview first
```

### Phase 4 — finishing touches (manual)

```bash
aws configure sso && aws sso login      # set up short-lived AWS creds (CLI already installed)
```
Open the project from your editor's WSL remote, and you're working.

---

## Script reference

Each mutating script takes `--dry-run` (preview, no changes) and backs up any file it edits to
`<file>.bak.<timestamp>`.

### `10-wsl-base.sh`
apt full-upgrade, then installs `build-essential cmake pkg-config htop tree zip ca-certificates
socat bubblewrap`, and masks `getty@tty1` (cosmetic). `socat` is the WSL side of the 1Password
SSH-agent bridge; `bubblewrap` is a lightweight sandbox for agents.

### `20-tooling.sh`
Installs the toolchain **without touching shell config** (uses `--no-modify-path` / `--skip-shell`
and restores rc files on exit): **uv** (+ Python 3.12 & 3.13), **fnm** (+ Node LTS), **Bun**,
**AWS CLI v2**, Homebrew tools (`starship zoxide direnv bat eza gitleaks fzf`), and **pre-commit**.
Locations: uv/uvx → `~/.local/bin`; fnm/Node → `~/.local/share/fnm`; Bun → `~/.bun`; brew → `/home/linuxbrew`.

### `30-shell.sh`
Writes one managed block — `# >>> wsl2-dev-setup >>>` — to `~/.zshrc`, adding only what your
existing `comfort-shell` block lacks: `~/.local/bin`/fnm/Bun on PATH, PATH de-dup + a prune of the
leaking Windows Node, fnm init, Bun completions, a version-robust `fzf` line, `op`/`open` aliases +
`$BROWSER`, and history settings. Re-running replaces the block in place.

### `35-verify-setup.sh`  *(read-only)*
Six sections: **A** apt packages, **B** tools at absolute paths, **C** `~/.zshrc` config, **D** the
*live* interactive shell (via `zsh -ic` — confirms `node`/`npm` resolve to fnm with no `/mnt/c`
leak), **E** interop/manual items, **F** git-setup pre-flight (1Password CLI, the agent pipe + a
check for the competing Windows `ssh-agent` service, `npiperelay.exe`, `gh`). Exit `0` only if every
critical check passes. `--open-browser` also fires a live `wopen` test.

### `40-git-setup.sh`
Interactive. Per profile it collects label, name, email, GitHub username; finds or creates your
projects root and a subfolder per profile; **pauses while you create each ed25519 key in the
1Password app**, then pulls only the *public* key via `op`. Generates: `~/.ssh/config` host aliases
(`github-<label>`, pinned to each `.pub` with `IdentitiesOnly`), per-profile
`~/.config/git/<label>.gitconfig` (identity + SSH commit signing + `url.insteadOf`), `~/.gitconfig`
defaults + **directory-based** `includeIf "gitdir:…"`, and a `~/.zshrc` block with the
`SSH_AUTH_SOCK` bridge + navigation shortcuts. Offers to `brew install gh`.

### `45-github-profiles.sh`
Detects your profiles from `~/.ssh/config`. For each, **pauses so you switch the github.com account
in your browser**, authenticates `gh` (`--auth web`, default — no PAT; or `--auth pat`, which opens
a pre-filled token page), then uploads the key as **both** an authentication and a signing key.
Finally installs a zsh `chpwd` hook: entering a profile directory prints a notice and runs
`gh auth switch`. Flags: `--auth web|pat`, `--hook-only`, `--dry-run`.

### `new-project.sh`
Scaffolds `./<name>`: a `pyproject.toml` with **torch/torchvision pinned to the cu128 wheel index**
(via `[[tool.uv.index]]` + `[tool.uv.sources]`), a `dev` group (ruff, pre-commit, pytest,
pytest-playwright), `.envrc` (`layout uv` + `dotenv_if_exists .env`), `.env.tpl`/`.env.example`,
`.vscode/settings.json`, local ruff pre-commit hooks, a Playwright smoke test, and
`scripts/verify_gpu.py`. Then `git init`, `uv sync`, `playwright install --with-deps chromium`,
`pre-commit install`, `direnv allow`, and runs the GPU + Playwright checks. Flags: `--python`,
`--cuda cu128|cu129|…`, `--no-torch`, `--no-playwright`, `--no-install`, `--dry-run`.

---

## Conventions

- **Managed blocks.** Everything these scripts add to a config file lives between markers like
  `# >>> name >>>` … `# <<< name <<<`. Re-running a script strips and re-appends its block, so
  edits never duplicate. Your `~/.zshrc` ends up with seven independent blocks:
  `comfort-shell` (yours), `wsl2-dev-setup` (30), `git-profiles` (40), `gh-profiles` (45),
  `win-shortcuts` (48), `dev-shortcuts` (50), `github-mcp` (60).
- **Backups + dry-run.** Mutating scripts back up edited files to
  `~/.local/state/wsl2-dev/backups/` (newest 5 kept) and accept `--dry-run`.
- **1Password is the source of truth.** SSH private keys are created in the app and never hit the WSL
  disk (only `.pub` files do); long-lived secrets resolve via `op inject` into a gitignored `.env`.
- **Identity follows the directory.** Which GitHub identity, signing key, and SSH key a repo uses is
  decided by which `~/projects/<profile>` folder it lives in — chosen for clean Claude Code behaviour.

## Daily workflow

```bash
cd ~/projects/work                      # the directory hook announces the active profile
./new-project.sh api-service            # or: git clone git@github-work:org/repo.git
cd api-service                          # direnv auto-activates the venv
op inject -i .env.tpl -o .env           # resolve secrets once (one Windows Hello prompt)
uv run python main.py                   # tools read .env with no further prompts
git commit -am "…"                      # signed with the work identity → Verified
```

## Health check & troubleshooting

`./35-verify-setup.sh` is the first thing to run when something feels off. Common items:

- **`unknown option: --zsh` on shell start** — old apt `fzf`; `brew install fzf` (30-shell's line is already version-robust).
- **`op.exe` not reachable** — install the CLI (`winget install 1password-cli`) and enable the CLI integration.
- **SSH auth fails** — confirm `npiperelay.exe` is installed and the 1Password SSH agent is on; check the
  Windows `ssh-agent` service isn't competing for the pipe (verify-setup Section F flags this).
- **`gh ssh-key add --type signing` scope error** — `gh auth refresh -h github.com -s admin:ssh_signing_key`.
- **GPU not detected by torch** — `scripts/verify_gpu.py` prints why; cu128 needs a 12.8+ driver (yours reports 12.9).

## Full tutorial

For the complete narrative — every decision, alternative, and verification step — see
**`wsl2-dev-environment-setup.md`** (16 sections). This README is the quick map; the tutorial is the territory.
