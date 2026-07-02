# WSL2 as a Production-Grade Dev Environment: A Complete Tutorial for Your RTX 5070 Ti Laptop

**Audience:** an expert-capable developer who is new to WSL2, Docker, AWS, and production environment design. Every recommendation is tailored to your audited machine: Windows 11 (build 10.0.26200.8655), WSL 2.7.3.0 / WSLg 1.0.73, Ubuntu 24.04.4 (systemd on, user `benja`), Intel Core Ultra 9 275HX (24 vCPU), ~15 GiB RAM visible to WSL, RTX 5070 Ti Laptop GPU (12 GB, Blackwell sm_120), zsh 5.9 login shell, Docker Desktop with WSL integration, Linuxbrew, and the 1Password desktop app on Windows with Windows Hello.

> **This revision reflects your decisions:** global WSL settings are managed in the **WSL Settings app**; `appendWindowsPath` stays at its default (the Windows-Node leak is fixed by installing Linux Node, not by disabling the PATH); **`wslu` is not used** — a small `wopen` helper replaces `wslview`; and **TensorFlow is out of scope** — this guide is PyTorch-only.

## TL;DR
- **Build everything inside WSL2 on the ext4 filesystem** (never under `/mnt/c`), use **uv** as your single Python tool, make the **1Password Windows app the source of truth for SSH keys and long-lived secrets**, use **AWS SSO short-lived credentials** instead of access keys, and **keep Docker Desktop** for now. This is secure, reproducible, and team-ready.
- **Your RTX 5070 Ti works today with PyTorch stable on the `cu128` wheel index** (Blackwell support shipped in PyTorch 2.7.0, April 2025). PyTorch is your ML framework; TensorFlow is intentionally excluded.
- **Set your global limits in the WSL Settings app** (memory / CPU / swap), **keep NAT** networking (mirrored mode conflicts with Docker Desktop in 2026), **fix the Windows-Node leak by installing Linux Node** (not by disabling the PATH), use a small **`wopen`** helper instead of the archived `wslu`, and adopt a **5-command uv bootstrap** for every new project.

## Key Findings
1. **What lives where:** Windows owns the GPU driver, Docker Desktop, 1Password (your SSH/secret layer), and the editor UI; WSL2 Ubuntu is your entire dev environment (code, venvs, containers, CLIs). Editors run on Windows but execute their server inside WSL.
2. **uv is the center of the Python universe.** The current stable is **uv 0.11.21 (released 2026-06-11)**; the 0.11 line opened 2026-03-23. uv replaces pip, pipx, pyenv, virtualenv, and poetry, and supports PEP 735 dependency groups. **OpenAI announced its acquisition of Astral on 2026-03-19**, folding the team into its Codex division; uv, Ruff, and ty remain MIT-licensed open source.
3. **GPU:** install nothing GPU-related *inside* WSL except framework wheels — the Windows driver provides `libcuda` via `/usr/lib/wsl/lib`. Verify with `nvidia-smi`; install PyTorch from the `cu128` index.
4. **Secrets:** the 1Password Windows app is your source of truth. SSH keys never touch the WSL disk (requests forward to `ssh.exe`), commit-signing uses the WSL snippet, `op run`/`op inject` provide env vars without writing secrets to disk, AWS uses SSO instead of stored keys, and you never paste secrets into an agent's context.
5. **Docker:** keep Docker Desktop (free for you under the <250-employee / <$10M-revenue threshold). Learn images/containers/volumes/compose; use it for Postgres/Redis, GPU containers, and reproducible builds — not for what uv already handles.

## Details

---

### 1. Recommended Mental Model

Think in **two cooperating machines**:

- **Windows = host platform / hardware layer.** It owns the GPU and its driver, the 1Password desktop app (your secret vault and SSH agent, unlocked by Windows Hello), Docker Desktop's backend VM, Windows Terminal, `ssh.exe`, and the GUI of VS Code / Cursor. You touch Windows rarely and deliberately.
- **WSL2 Ubuntu 24.04 = your development environment.** All code, virtual environments, Docker containers (via the integration), language toolchains, and CLIs live here on the fast ext4 filesystem. This is where ~95% of your time goes.

```
+--------------------------- Windows 11 host ---------------------------+
|  NVIDIA driver (libcuda) -- GPU RTX 5070 Ti                           |
|  1Password app + Windows Hello -- SSH agent / secret vault            |
|  Docker Desktop (backend VM + docker-desktop distro)                  |
|  VS Code / Cursor (UI)   Windows Terminal   ssh.exe                   |
+-----------^-------------------^------------------^--------------------+
            | GPU passthrough    | agent forward    | remote server
+-----------+-------------------+------------------+--------------------+
|  WSL2 Ubuntu 24.04 (ext4 VHD, systemd)                                |
|  ~/projects/* - uv venvs - zsh - git - gh - aws - docker CLI          |
|  VS Code/Cursor remote server runs HERE                               |
+----------------------------------------------------------------------+
```

**Why this split:** native Linux I/O for your code; Windows handles the hardware and human-facing auth (biometrics). Local GPU for development and inference; AWS for scale-out training and production. **must-have principle:** *code and dependencies live in Linux; secrets and hardware live in Windows.*

---

### 2. WSL2 and Ubuntu 24.04 Setup

Your WSL is current (2.7.3.0) and Ubuntu is healthy with systemd on. Focus on tuning.

#### 2.1 Configure global WSL settings in the WSL Settings app (must-have)
You manage global settings through the **WSL Settings** app (the GUI that ships with recent WSL). It writes `C:\Users\<you>\.wslconfig` under the hood, so you never hand-edit that file — the GUI is your front-end. With a 24-vCPU host and ML workloads, the defaults (~50% RAM, all CPUs) are wasteful and can starve Windows. In **WSL Settings**, set:

- **Memory** -> `24 GB` (cap so Windows + Docker Desktop keep headroom)
- **Processors** -> `20` (leave a few cores for Windows)
- **Swap** -> `8 GB`
- **Networking mode** -> leave at **NAT / default** (see 2.4 — do **not** pick Mirrored)
- In the **Optional / Experimental** section: **Automatic memory reclaim -> Gradual**, **Sparse VHD -> On**

For reference, those choices are equivalent to this `.wslconfig` (what the app generates — shown so you know what's under the hood, not for you to write by hand):
```ini
[wsl2]
memory=24GB
processors=20
swap=8GB
[experimental]
autoMemoryReclaim=gradual
sparseVhd=true
```
Apply via the app's restart prompt, or run `wsl --shutdown` in PowerShell and reopen. Your machine reported only ~15 GiB visible **because no global config was set**; pick `Memory` based on confirmed host physical RAM (lower it if the host has <32 GB). **Tradeoff:** *Automatic memory reclaim = Gradual* is gentle and fine with Docker Desktop; switch it to *Drop cache* or *Disabled* only if you ever run a Docker daemon **inside** WSL.

#### 2.2 Tune `/etc/wsl.conf` (inside Ubuntu)
This per-distro file stays hand-edited (the WSL Settings app manages the *global* `.wslconfig`, not the distro's `wsl.conf`).
```ini
# /etc/wsl.conf  (Linux side, per-distro)
[boot]
systemd=true
[user]
default=benja
[interop]
enabled=true
appendWindowsPath=true   # keep Windows tools reachable; Linux PATH still wins (see 4.1)
[automount]
options="metadata,umask=022,fmask=011"
```
**We keep `appendWindowsPath=true` (the default).** Windows executables stay reachable from WSL (`explorer.exe`, `op.exe`, `code`, `cursor`), and because WSL appends them at the **end** of PATH, your Linux tools automatically win on any name collision. The Windows-npm leak from your audit is fixed by **installing Linux Node** (so a Linux `node` exists ahead of the Windows one), not by disabling the PATH — details in 4.1.

#### 2.3 Update packages and install the essential dev set
```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y build-essential cmake pkg-config \
     htop tree zip ca-certificates
```
This closes your audit gaps: **cmake** (was absent), **htop/tree/zip** (absent). `gcc 13.3`, `make`, `curl`, `wget`, `jq`, `ripgrep`, `fd`, `fzf`, `tmux`, `unzip` are already present. Keep `unattended-upgrades` running. (For opening Windows apps/URLs from Linux we use a tiny `wopen` wrapper instead of the now-archived `wslu` — see 4.6.)

#### 2.4 Networking: stay on NAT (do not switch to mirrored)
Your audit shows NAT mode with an auto-generated `resolv.conf` (nameserver 10.255.255.254). **Recommendation: keep NAT.** Mirrored mode (localhost sharing, LAN access, IPv6, better VPN) sounds attractive, but as of 2026 it **conflicts with Docker Desktop's vpnkit port-forwarding** — port bindings can fail silently and become unreachable — and it interferes with local DNS resolvers listening on `127.0.0.1:53`. Since you're new to Docker and rely on Docker Desktop, NAT's reliability wins. Use mirrored only if you hit a specific VPN problem, and expect to troubleshoot Docker port binding.

Common pitfalls/fixes:
- **DNS breakage after VPN connect:** `wsl --shutdown` then reopen; if persistent, set `generateResolvConf=false` in a `[network]` block of `/etc/wsl.conf` and write a static `/etc/resolv.conf` (`nameserver 1.1.1.1`).
- **Reach a WSL service from Windows:** use `localhost:PORT` (NAT forwards localhost).
- **Bind dev servers to `127.0.0.1`**, not `0.0.0.0`, unless you explicitly want LAN exposure.

#### 2.5 Filesystem layout & performance (must-have)
Keep **all projects on ext4** under `~/projects`. Files under `/mnt/c` cross the 9p protocol boundary and are dramatically slower for the many-small-file operations Python/git/node do constantly. Your audit confirms `~/projects` and `~/src` exist and are nearly empty — perfect. Never `git clone` into `/mnt/c/...`.

#### 2.6 Clean up the extra distro & set up backups (must-have)
You have three distros: `Ubuntu-24.04` (main), `docker-desktop` (leave it — Docker manages it), and a leftover `Ubuntu`. Confirm the leftover is empty, then export-then-remove:
```powershell
wsl -l -v
wsl --export Ubuntu  C:\wsl-backups\Ubuntu-leftover.tar   # safety net
wsl --unregister Ubuntu
```
**Disaster-recovery routine (monthly):**
```powershell
wsl --shutdown
wsl --export Ubuntu-24.04 D:\wsl-backups\ubuntu-2026-06.tar
```
Restore on a new machine with `wsl --import Ubuntu-24.04 C:\WSL\Ubuntu D:\wsl-backups\ubuntu-2026-06.tar`. Because your real source of truth is GitHub + 1Password + a dotfiles repo, this snapshot is a convenience, not the primary backup (15).

#### 2.7 Cosmetic: mask the failed getty unit
```bash
sudo systemctl mask getty@tty1.service   # harmless in WSL; silences the failed-unit noise
```

---

### 3. NVIDIA GPU, CUDA, and ML in WSL2

#### 3.1 How GPU support works (read before installing anything)
In WSL2 the **Windows NVIDIA driver provides the CUDA driver** (`libcuda.so`) into Linux through `/usr/lib/wsl/lib`. **You must NOT install a Linux NVIDIA driver inside WSL** — it breaks the passthrough.
- **Windows:** only the NVIDIA GeForce/Studio driver (keep it updated via the NVIDIA app).
- **WSL Ubuntu:** only the **framework wheels** (PyTorch), which bundle their own CUDA runtime libraries. You generally do **not** need a full system CUDA toolkit.

Verify:
```bash
nvidia-smi               # should list "RTX 5070 Ti Laptop GPU" and a CUDA version (e.g. 12.x)
ls /usr/lib/wsl/lib      # libcuda.so etc., provided by the Windows driver
```

#### 3.2 PyTorch on Blackwell (sm_120) — works today
**The critical fact:** Blackwell/sm_120 support landed in **PyTorch 2.7.0** stable wheels (CUDA 12.8), released April 2025. The latest stable is **PyTorch 2.12.0 (released 2026-05-13)** (2.11.0 shipped 2026-03-23). Pre-2.7 or `cu126` wheels throw `CUDA error: no kernel image is available for execution on the device` on your GPU. **Use the `cu128` wheel index** — the proven, universally available Blackwell build across all stable versions from 2.7 to 2.12.

With uv, declare the index in your project (preferred over global pip):
```toml
# pyproject.toml
[project]
dependencies = ["torch", "torchvision", "torchaudio"]
[tool.uv.sources]
torch = { index = "pytorch-cu128" }
torchvision = { index = "pytorch-cu128" }
torchaudio = { index = "pytorch-cu128" }
[[tool.uv.index]]
name = "pytorch-cu128"
url = "https://download.pytorch.org/whl/cu128"
explicit = true
```
Then `uv sync`. Or quick into a venv:
```bash
uv pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128
```
> **Note on cu130:** the newest stable releases (2.9–2.12) also offer `cu129`/`cu130` indexes, and the plain-PyPI default `torch` wheel's CUDA tag has been shifting toward `cu130`. For reproducibility, **always pin `--index-url` explicitly** rather than relying on the default. `cu128` is the safe, well-tested choice for sm_120; `cu130` also works on the newest releases; `cu126` and earlier do **not** contain sm_120 kernels.

Verify:
```python
import torch
print(torch.__version__, torch.version.cuda)      # e.g. 2.12.0+cu128 12.8
print(torch.cuda.is_available())                   # True
print(torch.cuda.get_device_name(0))               # RTX 5070 Ti Laptop GPU
print(torch.cuda.get_device_capability(0))         # (12, 0)  <- confirms sm_120
x = torch.randn(4000, 4000, device="cuda"); print((x @ x).shape)  # kernels actually run
```

> *TensorFlow is intentionally out of scope — you're not using it, and this keeps your CUDA runtime clean (only torch's bundled libraries). If that ever changes, be aware that stable TensorFlow currently has no native Blackwell/sm_120 kernels and JIT-compiles from PTX at runtime, so you'd need to budget for a from-source build.*

#### 3.3 When you need the CUDA toolkit (`nvcc`)
Framework wheels include runtime CUDA, so you don't need a system toolkit for normal training/inference. You need `nvcc` (the full CUDA Toolkit — **the WSL-Ubuntu variant, never the driver**) only when **compiling custom CUDA extensions** (`flash-attn` from source, `tiny-cuda-nn`, custom kernels). Install via NVIDIA's WSL-Ubuntu repo and select the toolkit *without* drivers.

#### 3.4 GPU in Docker
Docker Desktop's WSL2 backend handles the NVIDIA container toolkit for you:
```bash
docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi
```
For a PyTorch CUDA container, use NVIDIA's NGC images (`nvcr.io/nvidia/pytorch:25.xx`), optimized for Blackwell from the 25.01 release onward. Pass `--gpus all`.

#### 3.5 What fits in 12 GB VRAM — local vs cloud
Your 12 GB laptop GPU is excellent for **development and inference**, limited for **full fine-tunes**:
- **Fits comfortably:** 4-bit-quantized 7–8B LLM inference (~5–7 GB); SDXL inference; **LoRA/QLoRA fine-tuning of 7B models** on a 4-bit base; small/medium vision and tabular training; embeddings; prototyping any pipeline.
- **Tight or won't fit:** full-precision fine-tuning of >3B params; training >13B models; large-batch training.
- **Go to AWS when** you need multi-GPU, >12 GB, or long unattended training: EC2 **G6/G6e** (L4/L40S) or **P5** (H100) on **Spot**. **Rule of thumb:** if it fits in 12 GB, do it locally; otherwise burst to a cloud GPU and stop it immediately (12).

---

### 4. Shell and Terminal

You have zsh 5.9 as login shell (`.zshrc`/`.zprofile`), Windows Terminal, and Linuxbrew. Good base.

#### 4.1 PATH hygiene & Linux Node (must-have)
Your audit showed Windows `npm 11.13.0` plus nvm4w/AppData paths reachable in WSL. The clean fix is **not** to disable the Windows PATH — it's to **install a Linux-native Node**, because WSL appends Windows entries at the *end* of PATH, so a Linux `node` automatically wins on name collisions. The only reason your audit surfaced Windows npm is that **no Linux node existed**. Install **fnm**:
```bash
curl -fsSL https://fnm.vercel.app/install | bash
# then add to ~/.zshrc:
eval "$(fnm env --use-on-cd)"
fnm install --lts
```
`which node` now points at fnm's Linux build; the Windows one sits harmlessly at the tail as a never-reached fallback, and you keep every Windows interop convenience (`code`, `cursor`, `op.exe`, `explorer.exe`). For a faster JS/TS toolchain *alongside* Node, also install **Bun** (4.7).

Optional hygiene — keep the Windows Node dirs from even appearing in `which -a node`, and dedupe (your audit showed duplicate brew entries). zsh ties `$PATH` to the `$path` array, so:
```bash
# ~/.zshrc, after the Windows PATH is appended
typeset -U PATH path                        # dedupe
path=("${(@)path:#*/nvm4w/*}")              # drop Windows nvm4w node
path=("${(@)path:#*/AppData/Roaming/npm}")  # drop Windows global npm shims
```

> **Stricter alternative (not chosen):** set `appendWindowsPath=false` in `wsl.conf` and re-add only the Windows tools you want. That gives a fully curated PATH but more upkeep — you'd have to re-add `/mnt/c/Windows/System32` for `explorer.exe`/`cmd.exe`/`powershell.exe`, the 1Password dir for `op.exe`, etc. The fnm approach above is simpler, keeps interop intact, and is what this guide uses.

#### 4.2 brew vs apt (opinionated)
Use **apt for system libraries/compilers**, **uv for everything Python**, **fnm for Node**, and **brew sparingly** for modern CLI tools that are stale in apt (`fzf`, `eza`, `zoxide`, `bat`, `starship`). Don't install Python or Node toolchains via brew — keep those in uv/fnm for reproducibility. Tradeoff: brew adds shell-startup cost and a second package DB; keep its footprint small.

#### 4.3 Prompt and CLI tools that earn their place
- **Prompt: starship** (recommended) — fast single binary; shows git + venv + AWS profile. Pure is a lighter zsh-only alternative, but starship wins for your multi-context work.
- **Keep:** `fzf`, `ripgrep`, `fd`, `jq`, `tmux`.
- **Add:** `zoxide` (smart `cd`), `bat` (syntax-highlighted `cat` for review), `eza` (better `ls` with git status), and **htop** (from 2.3) for memory monitoring given your WSL tuning. **Skip** `tldr` unless you want it.

#### 4.4 Startup performance
Keep `.zshrc` lean; lazy-load heavy completions; avoid running slow version-manager init on every prompt. Measure with `time zsh -i -c exit`. Starship, zoxide, and `fnm env --use-on-cd` are cheap; the usual culprit is heavyweight plugin frameworks.

#### 4.5 Dotfiles (opinionated): chezmoi
For a solo dev heading toward a team and multiple machines, **chezmoi** handles per-machine templating, secret references (can pull from 1Password), and clean onboarding (`chezmoi init --apply <repo>`). A bare git repo is fiddly with secrets/multi-machine diffs; a hand-rolled symlink script doesn't scale. Commit `.zshrc`, the non-secret parts of `.gitconfig`, starship config, your `direnvrc`, and the `wopen` helper below.

#### 4.6 Opening Windows apps from WSL — the `wopen` helper (replaces `wslu`)
`wslu` is archived upstream, so instead of `wslview` use a tiny wrapper. Note **`wslpath` is built into WSL itself** (not part of `wslu`), so path conversion costs you nothing.
```bash
mkdir -p ~/.local/bin
cat > ~/.local/bin/wopen << 'WOPEN'
#!/usr/bin/env bash
# wopen — open a URL, file, or directory in the default Windows app (replaces wslu's wslview).
arg="${1:-}"
if [ -z "$arg" ]; then echo "usage: wopen <url|file|dir>" >&2; exit 1; fi
case "$arg" in
  *://* | mailto:*) loc="$arg" ;;                     # URL / scheme: pass through
  *) loc="$(wslpath -w "$(realpath -m "$arg")")" ;;   # Linux path -> Windows path
esac
# explorer.exe routes URLs to the default browser and files to their default app.
# It returns exit code 1 even on success, so we normalize to 0.
explorer.exe "$loc"; exit 0
WOPEN
chmod +x ~/.local/bin/wopen
ln -sf ~/.local/bin/wopen ~/.local/bin/xdg-open   # tools that call xdg-open now hit Windows
```
Then in `.zshrc` (your `~/.local/bin` is early on PATH, so the `xdg-open` shim wins):
```bash
export BROWSER="$HOME/.local/bin/wopen"
alias open="wopen"     # macOS-style muscle memory
```
This covers every case `wslview` did: interactive opens (`open report.pdf`, `open .`), `gh` opening PRs, Playwright headed runs launching a browser, and any `xdg-open`-based tool — with no unmaintained package. (`explorer.exe` is the most robust opener for URLs because it bypasses `cmd`'s parser, so query strings with `&` work; the only quirk is its exit code, which the script normalizes.)

A complete `.zshrc` is in 16.

#### 4.7 JavaScript/TypeScript with Bun (recommended)
**Bun** is a single-binary JS/TS runtime + package manager + bundler + test runner. The current stable is **Bun 1.3.14 (2026-05-12)**. Add it as a **fast layer on top of** the fnm/Node baseline from 4.1 — not a replacement. Bun aims for ~100% Node compatibility and is **incrementally adoptable**: you can use `bun install` as the fastest npm client and `bun test` as a fast runner inside otherwise-Node projects, without committing to a Bun-only world. Keep Node available for the broad ecosystem that still assumes it (many VS Code extensions, some MCP servers, and tools that haven't been tested on Bun).

Install (needs `unzip`, which you have; Ubuntu 24.04's 6.6 kernel exceeds Bun's 5.6 recommendation):
```bash
curl -fsSL https://bun.sh/install | bash
bun upgrade        # self-updates thereafter (don't use `bun upgrade` if you installed via brew/npm)
```
The installer adds `~/.bun/bin` to PATH and writes zsh completions; the explicit lines are in the example `.zshrc` (16.4). Because `~/.bun/bin` lands in the Linux portion of PATH, `bun` wins over any Windows copy — same precedence logic as Node.

**When to reach for Bun vs Node:**
- **Bun:** installing JS deps fast (`bun install`, ~10–30x quicker than npm), running a `.ts` script directly (`bun run script.ts`, no separate transpile), one-off CLIs (`bunx <pkg>`), bundling (`bun build`), and JS test suites (`bun test --parallel`). Bun 1.3 also ships zero-config frontend dev with HMR/React Fast Refresh — handy if a FastAPI service grows a small React/TS frontend.
- **Node (fnm):** anything that explicitly targets Node, tooling/extensions/MCP servers not yet validated on Bun, and **production services where you need the most battle-tested runtime** — Bun is dev-ready but, by maintainers' own framing, still shakes out occasional production bugs versus Node's decade of footprint.
- **Note:** your browser automation in 13 is *Python* Playwright via `uv`, so it's unaffected by the Node/Bun choice either way.

Practical pattern for a JS/TS subproject: `bun install` for deps, `bun run dev`/`bun test` in the loop, and pin the toolchain in `package.json`. For mixed monorepos, Bun's workspace catalogs and isolated installs (1.3 defaults) pair well with the uv-workspaces approach in 5.

---

### 5. Project Folder Structure

Everything under `~/projects` on ext4. Don't commit data, weights, logs, or notebook outputs.

**Minimal Python project**
```
mylib/
- .python-version  pyproject.toml  uv.lock   # commit uv.lock
- .venv/                                      # gitignored
- src/mylib/__init__.py                       # src layout
- tests/  README.md  .gitignore
```
**Production-adjacent FastAPI service**
```
api/
- pyproject.toml  uv.lock  .python-version
- src/api/{main.py, routers/, models/, db/, core/config.py}
- tests/  migrations/        # alembic
- Dockerfile  docker-compose.yml  .dockerignore
- .env.example  .envrc  .github/workflows/ci.yml
```
**ML / agent project**
```
ml/
- src/ml/{data/, models/, train.py, infer.py}
- notebooks/   # jupytext-paired, outputs stripped
- experiments/ # configs, NOT outputs
- data/  models/  artifacts/    # all gitignored
- scripts/  infra/
```
**Mixed monorepo (uv workspaces)**
```
platform/
- pyproject.toml   # [tool.uv.workspace] members = ["packages/*","services/*"]
- uv.lock          # ONE lockfile for the whole workspace
- packages/core/  services/api/  services/worker/  notebooks/
```

**Commit vs not:** commit code, `pyproject.toml`, `uv.lock`, configs, `.env.example`. **Never commit** `.env`, `data/`, `models/`, `*.ckpt`/`*.safetensors`, logs, `.venv/`, notebook outputs. For notebooks use **jupytext** (pair `.ipynb` with a `.py` percent script — diffable, review-friendly) plus **nbstripout** (a git filter that strips outputs on commit).

---

### 6. Python with uv

uv is your default for **everything** Python. The current stable is **uv 0.11.21 (2026-06-11)**. It's a single static binary that manages Python versions, venvs, deps, lockfiles, tools, and scripts. (OpenAI announced its acquisition of Astral on 2026-03-19, joining the Codex division; uv/Ruff/ty stay MIT-licensed open source.)

#### 6.1 Install
```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
uv self update     # self-updates thereafter
```
#### 6.2 Python versions
System Python is 3.12.3, but **prefer uv-managed interpreters**:
```bash
uv python install 3.12 3.13
uv python pin 3.12      # writes .python-version
```
#### 6.3 Daily loop
```bash
uv init myproj && cd myproj
uv add fastapi "uvicorn[standard]"           # runtime deps -> pyproject + uv.lock + .venv
uv add --dev pytest ruff                     # dev tools
uv add --group notebook jupyterlab ipykernel # PEP 735 dependency group
uv run pytest                                # runs in the venv, no activate needed
uv run uvicorn api.main:app --reload
```
- `.venv` is created in-project; editors auto-detect it.
- Commit `uv.lock`. In CI use `uv sync --locked` (fails if lock is stale) or `--frozen` (use lock as-is).
- Dependency groups (PEP 735): `[dependency-groups]` for `dev`, `test`, `notebook`, `ml`; runtime extras go in `[project.optional-dependencies]`.

#### 6.4 Tools (replaces pipx)
```bash
uv tool install ruff      # global isolated CLI
uvx ruff check .          # ephemeral run
```
Your audit shows pipx absent and pip3 not installed — fine; **uv replaces both**. Don't install pipx.

#### 6.5 Editors, Jupyter, Docker
- **VS Code/Cursor:** point the interpreter at `.venv/bin/python` (14).
- **Jupyter:** `uv add --group notebook jupyterlab ipykernel`, then `uv run python -m ipykernel install --user --name myproj` (or just pick the `.venv` kernel in VS Code).
- **Docker:** 10.4 — `UV_COMPILE_BYTECODE=1`, `UV_LINK_MODE=copy`, `uv sync --locked --no-dev`, cache mounts.

#### 6.6 When conda/poetry/pipx still matter (honest take)
- **conda/mamba:** only for exotic non-Python native deps lacking wheels (some geospatial/bioinformatics stacks). With today's wheels (including CUDA-bundled torch) you almost never need it — and definitely not for GPU PyTorch, where the `cu128` wheel is simpler.
- **poetry:** superseded by uv for your needs.
- **pipx:** replaced by `uv tool`.
- **plain venv/pip:** only inside throwaway Docker stages or for debugging.

Example `pyproject.toml` is in 16.

---

### 7. Code Quality and Automation

#### 7.1 Ruff (must-have) — format + lint, replaces black/isort/flake8
```bash
uv add --dev ruff
uv run ruff format .       # formatter (black-compatible)
uv run ruff check --fix .  # linter + import sorting
```

#### 7.2 Type checking (opinionated)
- **Recommendation: Pyright** (via the Pylance extension) for daily editor feedback — mature, fast enough, already integrated in VS Code/Cursor. Run it in CI too for consistency.
- **Frontier options (verify before adopting):** Astral's **ty** and Meta's **pyrefly** are Rust type-checkers, 10–60x faster than mypy/Pyright. **Pyrefly reached stable 1.0.0 on 2026-05-12** with strong typing-spec conformance (~92% vs mypy ~60%, pyright ~96%); **ty is still beta (~67% conformance)** but has the best editor latency and pairs with ruff/uv. **Verdict:** use Pyright now; pilot **pyrefly** in CI if type-check speed becomes a pain; adopt **ty** once it hits 1.0. Stay on mypy only if you depend on its plugins (Django, SQLAlchemy, pydantic v1).

#### 7.3 Tests
```bash
uv add --dev pytest pytest-cov
uv run pytest --cov=src
```
Add `hypothesis` for property-based tests where logic is tricky (optional).

#### 7.4 pre-commit (must-have) + secret scanning
```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.11.x
    hooks: [{id: ruff, args: [--fix]}, {id: ruff-format}]
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.x
    hooks: [{id: gitleaks}]
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v5.0.0
    hooks: [{id: check-added-large-files}, {id: end-of-file-fixer}, {id: trailing-whitespace}]
```
**Secret-scan pick: gitleaks** (fast, good defaults) over trufflehog for local hooks; pair with **GitHub push protection** server-side (15).

#### 7.5 Task runner (opinionated): just
You have `make`. Make works, but **just** is cleaner (no `.PHONY` noise, better args). Use **just** for new projects; keep Make where a project already uses it.
```
default: lint test
lint: ; uv run ruff check . && uv run ruff format --check .
test: ; uv run pytest
dev:  ; uv run uvicorn api.main:app --reload
```

#### 7.6 CI alignment
```yaml
- uses: astral-sh/setup-uv@v6
  with: {enable-cache: true}
- run: uv sync --locked
- run: uv run ruff check . && uv run ruff format --check .
- run: uv run pytest --cov=src
```

---

### 8. Secrets and Environment Variables

**The section you most wanted answered. Verdict: yes — make the 1Password Windows app your source of truth for long-lived secrets and SSH keys.** You already have it with Windows Hello, making it the lowest-friction secure option.

#### 8.1 Decision framework

| Kind of value | Source of truth | How it reaches your process |
|---|---|---|
| SSH keys | 1Password (Windows app) | SSH agent forwards to `ssh.exe`; key never on WSL disk |
| Long-lived API keys (Anthropic, OpenAI) | 1Password | `op run` / `op inject` at runtime |
| AWS credentials | **AWS SSO (nothing stored)** | short-lived tokens via `aws sso login` |
| GitHub auth | `gh` + 1Password SSH key | `gh auth`, SSH for git |
| Non-secret config (ports, flags, region) | `.env` / committed config | `direnv`, plain env |
| Team shared secrets | 1Password **shared vault** | same `op` patterns |

**Principle:** 1Password is the vault for anything long-lived and secret. AWS SSO is *better than any stored secret* because nothing persists. `.env` files hold only non-secret config plus runtime-injected values — never committed.

#### 8.2 1Password CLI in WSL (the practical reality)
The native Linux `op` CLI **cannot** use the desktop app's biometric unlock across the WSL boundary. The documented workaround aliases to the Windows binary:
```bash
alias op="op.exe"   # uses the Windows desktop app + Windows Hello for unlock
```
`op.exe vault list`, `op.exe read`, and `op.exe inject` then work and prompt via Windows Hello. **Caveat:** `op run -- <cmd>` via `op.exe` won't wrap a *Linux* child process correctly (the command after `--` runs on the Windows side). To wrap Linux processes, use the native Linux `op` with a **service-account token** (non-interactive, vault-scoped) or use `op inject` to render a file. Shell plugins are **not** supported in WSL.

#### 8.3 Patterns
**Secret references:** `op://Vault/Item/field`.

**`op inject`** renders a template (commit the template, never the output):
```bash
# .env.tpl (committed)
ANTHROPIC_API_KEY=op://Dev/anthropic/credential
DATABASE_URL=postgresql://app:dev@localhost:5432/app
# render locally (output gitignored):
op inject -i .env.tpl -o .env
```
**`op run`** injects env vars per-process, nothing on disk (best for real secrets):
```bash
op run --env-file .env.tpl -- uv run uvicorn api.main:app
```
**direnv + 1Password** (`.envrc`, committed, contains no secrets — only references):
```bash
layout uv
dotenv_if_exists .env
export ANTHROPIC_API_KEY=$(op.exe read "op://Dev/anthropic/credential")
export AWS_PROFILE=dev
```
Run `direnv allow` once. Tradeoff: `op.exe read` on each directory entry adds a Hello prompt/latency; for frequently-entered dirs prefer `op run` at command time.

#### 8.4 CI and team
- **GitHub Actions:** use **1Password service accounts** + `1password/load-secrets-action@v4` with `OP_SERVICE_ACCOUNT_TOKEN` as the *only* GitHub secret; everything else resolves from `op://...` references. For AWS, prefer **OIDC** (12) over any stored key.
- **Team (coming soon):** put shared secrets in a **1Password shared vault**; onboarding becomes "install 1Password -> get vault access -> `chezmoi init` -> `uv sync`." Scope service accounts to specific vaults (least privilege).

#### 8.5 Coding agents and secrets (critical)
**Never paste secrets into agent context.** Use `op run -- <cmd>` so the *child process* gets env vars while the **model never sees the values**. Give agents the `.env.example` (placeholders), never `.env`. Scope tokens minimally. Add `.env`, `data/`, and secret dirs to `.cursorignore`/`.cursorindexingignore` (14). The agent reads *structure*, not *values*.

Examples of `.env.example` and `.envrc` are in 16.

---

### 9. Git and GitHub

#### 9.1 Set identity and good defaults (your name/email are UNSET)
```bash
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"   # consider your GitHub no-reply
git config --global pull.rebase true
git config --global fetch.prune true
git config --global push.autoSetupRemote true
git config --global rerere.enabled true
git config --global diff.algorithm histogram
git config --global init.defaultBranch main        # already set
git config --global core.autocrlf input            # already set — correct for WSL
```
`core.autocrlf=input` is **right** for WSL: it strips CRLF on commit and never adds them, keeping the repo LF-clean. Keep it.

#### 9.2 SSH keys via 1Password (opinionated — do this)
You have 1Password + Windows Hello, so **use the 1Password SSH agent**; keys never touch the WSL disk and every use is biometric-authorized per session.
1. In the **1Password Windows app**: Settings -> Developer -> **Use the SSH agent**. Create or import an **ed25519** key.
2. Configure WSL git to forward to `ssh.exe`: open the key -> **Configure Commit Signing** -> check **Configure for Windows Subsystem for Linux (WSL)** -> **Copy Snippet** -> paste into `~/.gitconfig`.
3. SSH config changes go in **Windows** `%USERPROFILE%\.ssh\config`, not the WSL one (requests forward to Windows).

The traditional `~/.ssh/ed25519` + `ssh-agent` keeps a private key file on disk; given your hardware, the 1Password approach is **more secure and lower-friction** — recommended.

#### 9.3 Commit signing via SSH through 1Password
The "Configure Commit Signing (WSL)" snippet sets:
```ini
[gpg]
  format = ssh
[gpg "ssh"]
  program = "/mnt/c/Users/<you>/AppData/Local/1Password/app/8/op-ssh-sign-wsl"
[user]
  signingkey = ssh-ed25519 AAAA...
[commit]
  gpgsign = true
```
Upload the **public key** to GitHub as both a *Signing key* and an *Authentication key*. For local verification:
```bash
echo "$(git config --global user.email) $(git config --global user.signingkey)" > ~/.allowed_signers
git config --global gpg.ssh.allowedSignersFile "$HOME/.allowed_signers"
```
**Known wrinkle:** some users see local `git log --show-signature` report "Could not verify" while GitHub shows "Verified" — a known WSL signer-path quirk; GitHub verification still works.

#### 9.4 GitHub CLI
```bash
gh auth login          # choose SSH (you have the 1P key)
gh auth setup-git
```
With the 1Password SSH agent, use **SSH** for git remotes and `gh` for API/PR work. Use minimal token scopes.

#### 9.5 `.gitignore` / `.gitattributes`
Full `.gitignore` is in 16. `.gitattributes` essentials:
```
* text=auto eol=lf
*.ipynb linguist-documentation
*.safetensors filter=lfs diff=lfs merge=lfs -text   # only if you actually use LFS
```

#### 9.6 Branching, LFS, history protection
- **Solo now:** trunk-based with short-lived branches; protect `main` (require PR + CI) once the team arrives.
- **LFS vs external storage (opinionated):** **don't** put datasets/weights in LFS. Use **S3** (versioned) or **Hugging Face Hub** for weights, **DVC** if you need data versioning tied to git. LFS is acceptable only for a handful of moderate binary assets.
- **If a secret leaks:** **rotate the secret first**, then scrub history with `git filter-repo`/BFG, force-push, and have collaborators re-clone. Enable **push protection** so it's blocked pre-push.

#### 9.7 Agent-safe git
Agents work on **dedicated branches**, never push to `main`, never get broad-scope push credentials. Review diffs before merge; CI is the gate. Consider **git worktrees** to isolate agent work.

---

### 10. Docker (you're new to Docker)

#### 10.1 What it's for / when NOT
**Docker packages an app + its environment into an image** that runs identically anywhere. Use it for: **service dependencies** (Postgres, Redis), **prod parity**, **reproducible training/CI images**, **isolating risky agent work**. **Don't** use it for plain Python libs (uv venv suffices), GUI apps, or wrapping every script. Rule: if `uv run` solves it, you don't need Docker.

#### 10.2 Docker Desktop & WSL2 integration (what you have)
Docker Desktop runs its engine in a managed VM and exposes the `docker` CLI into Ubuntu via the WSL integration (the `docker-desktop` distro you saw). You run `docker` in Ubuntu; it executes in Desktop's backend. **Licensing:** Docker Desktop is free for small businesses (**fewer than 250 employees AND less than $10M annual revenue**) and personal/education use; larger orgs need a paid subscription (Pro from ~$9/month). You're fine now; revisit when your team/company crosses that threshold. **Docker Engine in WSL** (install `docker-ce` directly, license-free) is the leaner alternative. **Recommendation: keep Docker Desktop now** for simplicity and GPU handling; revisit Engine-in-WSL if licensing or overhead bites.

#### 10.3 Core concepts (newcomer mental models)
**Image** = read-only snapshot (a class). **Container** = a running instance (an object). **Volume** = persistent storage that outlives containers (your Postgres data). **Network** = how containers talk (compose makes one automatically). **Registry** = where images live (Docker Hub, AWS ECR). **Compose** = a YAML file describing a multi-container app you bring up with `docker compose up`.

#### 10.4 Dockerfile for a uv project (multi-stage, current best practice)
```dockerfile
# syntax=docker/dockerfile:1
FROM python:3.12-slim AS builder
COPY --from=ghcr.io/astral-sh/uv:0.11 /uv /uvx /bin/
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=0
WORKDIR /app
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --locked --no-install-project --no-dev
COPY . /app
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-dev

FROM python:3.12-slim
RUN groupadd -r app && useradd -r -g app -d /app app
COPY --from=builder --chown=app:app /app /app
ENV PATH="/app/.venv/bin:$PATH"
USER app
WORKDIR /app
EXPOSE 8000
CMD ["uvicorn", "api.main:app", "--host", "0.0.0.0", "--port", "8000"]
```
Copy `uv` from the official `ghcr.io/astral-sh/uv` image, two-stage `uv sync` (deps cached separately from source), `--locked --no-dev`, cache mount, non-root user.

#### 10.5 Compose — full `app + Postgres + Redis + MinIO` file in 16.

#### 10.6 Dev containers
VS Code **devcontainers** are worth it for **team onboarding** (one-click reproducible env) and **agent sandboxing** (a hard boundary for risky work). Overkill for a solo quick project where uv suffices. Adopt when the team arrives or to isolate agents.

#### 10.7 Beginner mistakes to avoid
`latest` tags (pin versions); secrets baked into images (use build secrets / runtime env); running as root (create a user); huge build contexts (add `.dockerignore`); treating containers as pets (persist data in volumes).

---

### 11. Databases and Local Services

**Decision framework:** SQLite for tiny/local single-user; DuckDB for analytics; Postgres for production-adjacent; Redis for cache/queues; pgvector for vectors. Run per-project services via **Docker Compose** rather than always-on installs.

- **SQLite** — zero-config file DB; perfect for small apps, tests, local tools.
- **DuckDB** (recommended for your data pipelines) — in-process analytics over Parquet/CSV; pairs with pandas/polars; great in notebooks/ETL.
- **PostgreSQL** (production-adjacent default) — run via compose with a **named volume**; compose-per-project beats a system-wide apt install for reproducibility.
- **Redis** — cache/queues/rate-limits via compose.
- **Vectors: pgvector** (recommended default) — add vector search to the Postgres you already run; one fewer system. Reach for **Qdrant/Chroma/LanceDB** only at scale or for specific features (LanceDB for embedded local use; Qdrant for large dedicated workloads).
- **Object storage:** **MinIO** locally when you need the S3 API offline/in CI; otherwise use a real **S3 dev bucket** (simpler, matches prod).
- **Migrations:** **Alembic** for SQLAlchemy; dbmate/raw SQL if you prefer SQL-first.
- **Connection strings:** `DATABASE_URL`. Dev creds can be simple (`app:dev@localhost`); **prod creds via 1Password/secrets manager**, never committed.
- **Backups:** `pg_dump` before risky ops + scheduled; volume snapshots for convenience (15).

---

### 12. AWS and Cloud (you're new to AWS; you use SSO)

#### 12.1 Mental model
**Account** = billing/isolation boundary (you may have dev/prod). **IAM Identity Center (SSO)** = your login, federating into accounts/roles. **Role** = a permission set you assume. **Profile** = a named local config pointing at account+role. **Region** = where resources live.

#### 12.2 Install AWS CLI v2 in WSL
```bash
cd /tmp && curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install
aws --version   # expect v2.x
```
Use the official installer (not apt/snap) for the current v2.

#### 12.3 Configure SSO with the modern `sso-session` syntax
```bash
aws configure sso
# SSO session name: my-org
# SSO start URL: https://my-org.awsapps.com/start
# SSO region: us-east-1
# scopes: sso:account:access
```
This writes the reusable `sso-session` block (CLI **v2.22.0+** gives automatic token refresh). Example `~/.aws/config`:
```ini
[sso-session my-org]
sso_start_url = https://my-org.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access

[profile dev]
sso_session = my-org
sso_account_id = 111111111111
sso_role_name = PowerUserAccess
region = us-east-1
output = json

[profile prod-ro]
sso_session = my-org
sso_account_id = 222222222222
sso_role_name = ReadOnlyAccess
region = us-east-1
```
Daily use:
```bash
aws sso login --sso-session my-org   # browser once; covers all profiles on the session
export AWS_PROFILE=dev
aws sts get-caller-identity           # sanity check: who am I?
```

#### 12.4 Why no long-lived keys
SSO gives **short-lived, auto-refreshed credentials**. **Never create IAM user access keys** when SSO exists — they're long-lived secrets that leak. Don't put them in `.env` or images.

#### 12.5 boto3, Docker, CI
- **boto3:** resolves `AWS_PROFILE`/region automatically and refreshes the SSO token; just `export AWS_PROFILE=dev`.
- **Docker:** mount `~/.aws` read-only (`-v ~/.aws:/root/.aws:ro`) or inject env; for ECR, `aws ecr get-login-password | docker login --username AWS --password-stdin <acct>.dkr.ecr.<region>.amazonaws.com`.
- **GitHub Actions:** use **OIDC** — no stored keys. Create an IAM identity provider for `token.actions.githubusercontent.com` and a role with a scoped trust policy:
```yaml
permissions: {id-token: write, contents: read}
steps:
  - uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: arn:aws:iam::111111111111:role/github-deploy
      aws-region: us-east-1
```

#### 12.6 Services for your use cases
- **S3** — datasets, artifacts, model weights (versioned bucket).
- **ECR** — container images. **ECS/Fargate** — serverless services. **Lambda** — small APIs/automation/cron.
- **EC2 GPU (G6/G6e/P5)** — burst training; use **Spot**; **auto-stop**. **Batch** — queued training jobs.
- **SageMaker** — powerful but heavy; for a solo dev, **DIY on EC2/Batch is usually simpler and cheaper** until you need managed training/endpoints at scale.
- **Bedrock vs direct Anthropic/OpenAI APIs** — Bedrock keeps everything in AWS (IAM, no extra key); direct APIs are simplest and first to new models. For your local-dev + cloud-API pattern, **direct APIs via `op run`** are the low-friction default; consider Bedrock for unified AWS billing/governance.

#### 12.7 Cost controls (must-have)
Set a **Budget + alert** immediately. The classic failure mode is a **forgotten GPU instance** burning money overnight — always `aws ec2 stop-instances` (or auto-stop) and prefer Spot. Tag resources; watch S3 egress. Everyday commands: `aws s3 cp/sync`, `aws s3 ls`, `aws sso login`, `aws sts get-caller-identity`.

---

### 13. Browser and Agent-Coding Workflows

#### 13.1 Playwright with uv
```bash
uv add --group test playwright
uv run playwright install --with-deps chromium   # pulls Ubuntu 24.04 system libs
```
`--with-deps` installs the system libraries (libnss3, libatk, etc.) Playwright needs on Ubuntu 24.04 — without it you get "Host system is missing dependencies." Headless is the default and best for agents/CI. **Headed mode works on your build via WSLg** (you have WSLg 1.0.73) — just run headed; no XLaunch needed on modern WSL.

#### 13.2 Where browsers run (opinionated)
**Default: Playwright Chromium native in WSL** for dev and agents. For **CI parity**, use the `mcr.microsoft.com/playwright` container. Drive **Windows browsers via CDP** only for niche cases. Channels: `playwright install chrome msedge` if you need branded channels; bundled chromium is fine otherwise.

#### 13.3 How agents (Cursor/Claude Code) should access things
- **Files:** workspace-scoped only. **Shell:** the WSL shell, project venv via `uv run`. **Browsers:** Playwright (MCP or built-in), headed via WSLg for debugging.
- **Git:** branch-scoped; no force-push; no direct `main` commits.
- **Docs/rules:** point agents at the `README`, `CLAUDE.md`/`AGENTS.md`, or `.cursor/rules`.
- **Secrets:** **never in agent context** — use `op run` so child processes get env vars without the model seeing values; agent reads `.env.example`, not `.env`; scoped tokens only.

#### 13.4 Sandboxing & safe patterns
For risky agent work, use **devcontainers or throwaway git worktrees**; Docker is the harder boundary (filesystem + network scoping). Avoid "YOLO mode" on anything with credentials or deploy access. Safe loop: **small scoped task -> frequent commits on an agent branch -> human reviews the diff -> CI gates -> protected `main`.** No deploy creds locally — deploys go through CI (OIDC).

#### 13.5 Observability
Use **Playwright traces, screenshots, video, and the trace viewer** to see what a browser agent did; log agent actions for reproducibility.

---

### 14. VS Code and Cursor

#### 14.1 Connect correctly (must-have)
- **Always open from inside WSL:** `cd ~/projects/x && code .` (or `cursor .`). The UI runs on Windows; the **server runs in Linux** for native performance. Look for the green **WSL: Ubuntu-24.04** indicator.
- **Never open `/mnt/c/...` paths** as projects (reintroduces 9p slowdown).
- **Cursor WSL:** Cursor uses VS Code's remote infrastructure. Install the **WSL extension**, then bottom-left **Connect to WSL**. Known caveats: Cursor attaches only to the **default** distro (yours is Ubuntu-24.04 — good); if `cursor .` fails, make sure Cursor is on your Windows PATH (with `appendWindowsPath=true` it's then reachable from WSL automatically) and that Ubuntu-24.04 is your default distro; Cursor's WSL support occasionally breaks across updates — keep the WSL extension current.

#### 14.2 Extensions that earn their place
Python, **Pylance** (Pyright), **Ruff** (charliermarsh.ruff), **Jupyter**, **Docker**, **Even Better TOML**, **YAML**, and **AWS Toolkit** (honest take: handy for browsing S3/logs and SSO sign-in, but you'll do most AWS work in the CLI — install only if you want a GUI). Built-in Git is fine; add GitLens only for richer blame/history.

#### 14.3 uv interpreter, Jupyter, format-on-save — `.vscode/settings.json`:
```json
{
  "python.defaultInterpreterPath": "${workspaceFolder}/.venv/bin/python",
  "python.terminal.activateEnvironment": true,
  "editor.formatOnSave": true,
  "editor.defaultFormatter": "charliermarsh.ruff",
  "[python]": {
    "editor.codeActionsOnSave": {"source.organizeImports.ruff": "explicit"}
  },
  "ruff.importStrategy": "fromEnvironment",
  "terminal.integrated.defaultProfile.linux": "zsh",
  "jupyter.notebookFileRoot": "${workspaceFolder}",
  "files.eol": "\n"
}
```

#### 14.4 Cursor safety with context and secrets
Add `.cursorignore` / `.cursorindexingignore` to keep `.env`, `data/`, `models/`, and large dirs out of model context and indexing. Use **rules files** (`.cursor/rules` or `AGENTS.md`/`CLAUDE.md`) to teach conventions (use `uv run`, branch workflow, never touch secrets). Review **privacy mode** so code isn't retained. Keep workspace settings in-repo, user settings personal.

---

### 15. Security, Maintenance, Reliability

#### 15.1 Update strategy
- **OS:** `unattended-upgrades` (running) + weekly `sudo apt update && sudo apt full-upgrade`.
- **WSL platform:** `wsl --update` (PowerShell) monthly.
- **uv tools:** `uv tool upgrade --all`; `uv self update`.
- **Node (fnm):** `fnm install --lts && fnm use --lts` periodically.
- **Bun:** `bun upgrade` periodically (skip if you installed Bun via brew/npm — upgrade through that instead).
- **brew:** `brew update && brew upgrade` occasionally.
- **Windows Update** drives the GPU platform — stay current for Blackwell driver fixes.

#### 15.2 Dependency & secret auditing
- **Python:** `uvx pip-audit`; **Dependabot/Renovate** on repos.
- **JS (via fnm):** `npm audit` / `pnpm audit` where Node deps exist.
- **Secrets:** **gitleaks** locally (pre-commit) + **GitHub push protection** + **secret scanning**.
- **GitHub security:** enable Dependabot alerts, push protection, 2FA now; branch protection when the team arrives.

#### 15.3 Network/firewall
WSL NAT means services aren't LAN-exposed unless you bind `0.0.0.0` and forward. **Bind dev servers to `127.0.0.1`.** In Docker, publish to `127.0.0.1:PORT:PORT` unless you intend LAN access. Windows Defender Firewall governs inbound to the host.

#### 15.4 Layered backup strategy (must-have)
- **Code:** GitHub (source of truth). **Dotfiles:** chezmoi repo. **Secrets/keys:** 1Password (cloud-synced). **Data:** per policy -> S3/DVC/HF Hub.
- **Convenience snapshot:** `wsl --export` monthly (2.6).
- **Docker volumes:**
```bash
docker run --rm -v pgdata:/data -v "$PWD":/backup alpine \
  tar czf /backup/pgdata-$(date +%F).tar.gz -C /data .
```
- **DB:** `pg_dump` cron or just-in-time.
- **Does NOT need backup:** anything reproducible (`.venv`, rebuildable images, cached models).

#### 15.5 SSH hygiene & least privilege
1Password agent = **no key files on disk**; per-session biometric auth is a feature. Manage `known_hosts` normally. Minimize GitHub token scopes, AWS role permissions, and agent permissions.

#### 15.6 Recovery runbook (test it once)
Laptop dies -> new machine: install WSL + Ubuntu -> `wsl --import` snapshot **or** rebuild: install uv + fnm, run `chezmoi init --apply <repo>` (restores dotfiles, git config, and the `wopen` helper), sign into 1Password (restores SSH keys/secrets), `gh auth login`, `aws configure sso`, then `git clone` + `uv sync` each project. Because everything reproducible lives in GitHub/1Password/chezmoi, rebuild is ~30 minutes. **Do a dry run once.**

#### 15.7 Every project README should document
setup (`uv sync`), run, test, env vars needed (referencing `.env.example`), data provenance, deploy notes.

---

### 16. Final Recommended Architecture

#### 16.1 The golden path (one page)
Windows hosts the GPU driver + 1Password + Docker Desktop + editor UI, with global WSL limits set in the **WSL Settings app**. WSL2 Ubuntu on ext4 holds all code under `~/projects`, managed by **uv** (Python), **fnm** (Node), **zsh + starship + direnv** (shell), **git + gh with 1Password SSH** (vcs), **Docker Desktop** (services/containers), **AWS SSO** (cloud). Secrets live in 1Password; AWS uses short-lived SSO creds; CI mirrors local checks via `setup-uv` and authenticates to AWS via OIDC. PyTorch (`cu128`) is the ML stack.

#### 16.2 The 5-command new-project bootstrap
```bash
uv init myproj && cd myproj
uv add fastapi "uvicorn[standard]" && uv add --dev ruff pytest pre-commit
echo 'layout uv' > .envrc && direnv allow
git init && gh repo create myproj --private --source=. --remote=origin
pre-commit install && git add -A && git commit -m "chore: bootstrap" && git push -u origin main
```

#### 16.3 Advanced ML/agent bootstrap
```bash
uv init ml && cd ml
uv add torch torchvision torchaudio    # with the cu128 index block in pyproject (3.2)
uv add --group ml transformers datasets accelerate
uv add --group notebook jupyterlab ipykernel
uv add --group test pytest playwright
uv run playwright install --with-deps chromium
```

#### 16.4 Example complete `.zshrc`
```bash
# ---------- PATH ----------
export PATH="$HOME/.local/bin:$PATH"                      # uv, uv tools, wopen
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"    # Homebrew
typeset -U PATH path                                       # dedupe (audit showed dup brew entries)
path=("${(@)path:#*/nvm4w/*}")                             # drop Windows node from PATH
path=("${(@)path:#*/AppData/Roaming/npm}")                 # drop Windows global npm shims

# ---------- Tools ----------
eval "$(fnm env --use-on-cd)"      # Linux Node (wins over Windows node sitting at PATH tail)
export BUN_INSTALL="$HOME/.bun"; export PATH="$BUN_INSTALL/bin:$PATH"   # Bun (fast JS/TS layer)
[ -s "$BUN_INSTALL/_bun" ] && source "$BUN_INSTALL/_bun"                # bun completions
eval "$(starship init zsh)"        # prompt
eval "$(zoxide init zsh)"          # smart cd -> 'z'
eval "$(direnv hook zsh)"          # per-dir envs
command -v fzf >/dev/null && source <(fzf --zsh)

# ---------- Aliases / env ----------
alias op="op.exe"                  # 1Password via Windows Hello
alias open="wopen"                 # open URLs/files in Windows (replaces wslview)
export BROWSER="$HOME/.local/bin/wopen"
alias ls="eza --group-directories-first"
alias cat="bat --paging=never"
alias gs="git status -sb"
alias ll="eza -lah --git"

# ---------- History ----------
HISTSIZE=100000; SAVEHIST=100000
setopt SHARE_HISTORY HIST_IGNORE_ALL_DUPS HIST_REDUCE_BLANKS
```

#### 16.5 Example `~/.config/direnv/direnvrc` (uv layout)
```bash
layout_uv() {
  if [[ ! -d ".venv" ]]; then uv venv; fi
  PATH_add ".venv/bin"
  export VIRTUAL_ENV="$PWD/.venv" UV_ACTIVE=1
}
```

#### 16.6 Example `.envrc`
```bash
layout uv
dotenv_if_exists .env
export AWS_PROFILE=dev
export ANTHROPIC_API_KEY=$(op.exe read "op://Dev/anthropic/credential")
```

#### 16.7 Example `.env.example`
```bash
# Non-secret config (safe to commit as example)
APP_ENV=local
LOG_LEVEL=debug
DATABASE_URL=postgresql://app:dev@localhost:5432/app
REDIS_URL=redis://localhost:6379/0
# Secrets are injected via op/direnv at runtime — do NOT put real values here
ANTHROPIC_API_KEY=
AWS_PROFILE=dev
```

#### 16.8 Example `.gitignore`
```gitignore
.venv/
__pycache__/
*.py[cod]
.env
.env.*
!.env.example
.direnv/
data/
models/
artifacts/
*.ckpt
*.safetensors
*.log
.ipynb_checkpoints/
.DS_Store
dist/
build/
.coverage
.pytest_cache/
.ruff_cache/
node_modules/
```

#### 16.9 Example `pyproject.toml`
```toml
[project]
name = "myproj"
version = "0.1.0"
requires-python = ">=3.12"
dependencies = ["fastapi", "uvicorn[standard]", "pydantic-settings"]

[dependency-groups]
dev = ["ruff", "pre-commit"]
test = ["pytest", "pytest-cov", "playwright"]
notebook = ["jupyterlab", "ipykernel"]
ml = ["torch", "torchvision", "transformers", "datasets", "accelerate"]

[tool.uv.sources]
torch = { index = "pytorch-cu128" }
torchvision = { index = "pytorch-cu128" }

[[tool.uv.index]]
name = "pytorch-cu128"
url = "https://download.pytorch.org/whl/cu128"
explicit = true

[tool.ruff]
line-length = 100
target-version = "py312"
[tool.ruff.lint]
select = ["E", "F", "I", "UP", "B", "SIM"]

[tool.pytest.ini_options]
addopts = "-q"
testpaths = ["tests"]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"
```

#### 16.10 Example `docker-compose.yml`
```yaml
services:
  app:
    build: .
    ports: ["127.0.0.1:8000:8000"]
    environment:
      DATABASE_URL: postgresql://app:dev@db:5432/app
      REDIS_URL: redis://redis:6379/0
    depends_on: [db, redis]
  db:
    image: postgres:17
    environment:
      POSTGRES_USER: app
      POSTGRES_PASSWORD: dev
      POSTGRES_DB: app
    ports: ["127.0.0.1:5432:5432"]
    volumes: ["pgdata:/var/lib/postgresql/data"]
  redis:
    image: redis:7
    ports: ["127.0.0.1:6379:6379"]
  minio:
    image: minio/minio
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: minio
      MINIO_ROOT_PASSWORD: minio12345
    ports: ["127.0.0.1:9000:9000", "127.0.0.1:9001:9001"]
    volumes: ["miniodata:/data"]
volumes:
  pgdata:
  miniodata:
```

#### 16.11 Example README skeleton
```markdown
# Project
## Setup
uv sync && pre-commit install
## Run
op run --env-file .env.tpl -- uv run uvicorn api.main:app --reload
## Test
uv run pytest
## Env vars
See .env.example. Secrets via 1Password (op://Dev/...).
## Data
Source + license. Stored in s3://.../  (not in git).
## Deploy
Via GitHub Actions (OIDC to AWS). No local deploy creds.
```

#### 16.12 Maintenance checklist
- **Weekly:** `apt full-upgrade`; `uv tool upgrade --all`; review Dependabot PRs; `pre-commit autoupdate`.
- **Monthly:** `wsl --update`; `wsl --export` snapshot; `docker system prune`; `fnm install --lts`; rotate aging tokens; test a project rebuild.

#### 16.13 Security checklist
1Password SSH + signing on; push protection + secret scanning on; AWS SSO only (no keys); services bound to `127.0.0.1`; gitleaks pre-commit; minimal token scopes; agents on branches without deploy creds.

#### 16.14 Troubleshooting checklist
- **GPU not visible:** update Windows NVIDIA driver; confirm `ls /usr/lib/wsl/lib`; never install a Linux driver; `wsl --shutdown` then retry `nvidia-smi`.
- **torch sees no GPU / "no kernel image":** you're on a pre-2.7 or `cu126` wheel — reinstall from `cu128`.
- **DNS broken:** `wsl --shutdown`; if persistent, set a static `resolv.conf` (2.4).
- **Clock skew (auth/TLS errors):** `sudo hwclock -s` or `wsl --shutdown`.
- **Memory ballooning:** set a Memory cap + Automatic memory reclaim in the **WSL Settings app** (2.1).
- **Interop/.exe fails ("Exec format error"):** binfmt issue — `wsl --shutdown`; keep `op.exe`/`explorer.exe` reachable on the Windows filesystem.
- **Docker integration disabled:** Docker Desktop -> Settings -> Resources -> WSL Integration -> enable for Ubuntu-24.04.
- **Port conflict:** find with `ss -ltnp`; change the published port.
- **Windows Node still resolving:** confirm Linux Node is installed — `which node` should point under `~/.local/share/fnm/...`, not `/mnt/c/...`; re-source `.zshrc` and check the prune lines applied.
- **`open`/`wopen` does nothing:** ensure `~/.local/bin` is on PATH and `~/.local/bin/wopen` is executable; test directly with `explorer.exe .`.

## Recommendations

**Do this first (day 1, in order):**
1. Set your global limits (Memory/CPU/Swap, memory reclaim, sparse VHD) in the **WSL Settings app** (2.1); tune `/etc/wsl.conf` keeping `appendWindowsPath=true` (2.2); `wsl --shutdown`.
2. Set git identity + defaults; wire up the 1Password SSH agent + commit signing (9).
3. Install uv (`uv python install 3.12`) and **fnm** (`fnm install --lts`) to end the Windows-Node leak, then **Bun** (`curl -fsSL https://bun.sh/install | bash`) as the fast JS/TS layer; install starship/zoxide/direnv; add the **`wopen`** helper (4.1, 4.6, 4.7, 6).
4. Verify GPU: `nvidia-smi`, then a torch `cu128` venv with the `(12,0)` check (3.2).
5. Export and remove the leftover `Ubuntu` distro (2.6).

**Week 1:** adopt the 5-command bootstrap; set up pre-commit + gitleaks + CI with `setup-uv`; configure AWS SSO + a Budget alert; stand up a Postgres/Redis compose.

**When the team arrives:** shared 1Password vault, devcontainers for onboarding, branch protection on `main`, OIDC for CI->AWS, service accounts for CI secrets.

**Framework stance:** PyTorch (`cu128`) is your ML stack and works now. TensorFlow is intentionally out of scope. Develop on the 12 GB GPU; burst to AWS Spot GPUs for anything bigger and stop them immediately.

**Thresholds that change the advice:** if Docker Desktop licensing/overhead bites (company >250 staff or >$10M revenue) -> move to Docker Engine in WSL. If type-check speed hurts -> pilot pyrefly (stable 1.0 since May 2026); adopt ty at 1.0. If you hit VPN/localhost pain -> consider mirrored networking but expect to fix Docker port-binding.

## Caveats
- **Fast-moving versions:** uv (0.11.21, 2026-06-11) and PyTorch (2.12.0 stable, 2026-05-13) change frequently — re-verify exact pins at setup time. The Blackwell/`cu128` guidance is current as of June 2026.
- **TensorFlow excluded by choice:** if you ever add it, stable TF has no native Blackwell/sm_120 kernels (it JIT-compiles from PTX, slow), and would need a from-source build — keep it in a separate venv to avoid CUDA-runtime conflicts with torch.
- **1Password in WSL** relies on documented-but-interop-based mechanisms (`op.exe` alias, `op-ssh-sign-wsl` path); the MSIX installer has changed the signer path before, and local signature *verification* can show false negatives even when GitHub shows "Verified." Re-run the "Configure Commit Signing (WSL)" snippet if paths break after a 1Password update.
- **Mirrored networking** is improving but still conflicts with Docker Desktop in 2026; the NAT recommendation may relax in future WSL releases.
- **`wslu` is archived upstream** (last release April 2024); the `wopen` helper avoids depending on it. `wslpath` is part of WSL itself and is unaffected.
- **Memory figure:** your 15 GiB-visible reading reflected the absence of any global config; set **Memory** in the WSL Settings app and confirm host physical RAM before settling on 24 GB (lower it if the host has less than ~32 GB).
- **AWS specifics** (account IDs, role names, start URL) are placeholders — substitute your org's real IAM Identity Center values.
