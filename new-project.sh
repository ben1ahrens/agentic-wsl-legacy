#!/usr/bin/env bash
#
# new-project.sh — Scaffold a uv-managed Python project, wired for this WSL2 setup.
#
# Produces (in ./<name>): a pyproject.toml with PyTorch pinned to the CUDA wheel index
# (cu128 by default — correct for RTX 50-series Blackwell on a CUDA 12.8+ driver), a
# dev dependency group (ruff, pre-commit, pytest, pytest-playwright), direnv + 1Password
# secrets scaffolding, VS Code settings, local ruff pre-commit hooks, and verification
# scripts for the GPU (torch sees sm_120 and runs a real kernel) and Playwright.
#
# Run it from INSIDE a profile folder (e.g. ~/projects/work) so the new repo inherits that
# git identity automatically (directory-based includeIf), then it git-inits the project.
#
# Usage:
#   ./new-project.sh <name>                 # full scaffold + install + verify
#   ./new-project.sh <name> --cuda cu129    # match a 12.9 driver exactly (default cu128)
#   ./new-project.sh <name> --no-torch      # skip PyTorch
#   ./new-project.sh <name> --no-playwright # skip Playwright
#   ./new-project.sh <name> --python 3.12   # default 3.13
#   ./new-project.sh <name> --no-install    # write files + git init only (no downloads)
#   ./new-project.sh <name> --github-mcp     # add a per-project GitHub MCP server (token from 1Password)
#   ./new-project.sh <name> --mcp-token-ref op://Work/gh-mcp/token   # set the 1Password ref (implies --github-mcp)
#   ./new-project.sh <name> --dry-run       # preview; write nothing
#
set -uo pipefail

NAME=""; PYVER="3.13"; CUDA="cu128"; TORCH=1; PLAYWRIGHT=1; INSTALL=1; DRY=0; MCP=0; MCP_REF=""
while [ $# -gt 0 ]; do case "$1" in
  --python) PYVER="${2:-}"; shift 2 ;;
  --cuda) CUDA="${2:-}"; shift 2 ;;
  --no-torch) TORCH=0; shift ;;
  --no-playwright) PLAYWRIGHT=0; shift ;;
  --no-install) INSTALL=0; shift ;;
  --github-mcp) MCP=1; shift ;;
  --mcp-token-ref) MCP_REF="${2:-}"; MCP=1; shift 2 ;;
  --dry-run|-n) DRY=1; shift ;;
  -h|--help) sed -n '2,/^set /{/^set /!p;}' "$0"; exit 0 ;;
  -*) echo "Unknown option: $1" >&2; exit 2 ;;
  *) [ -z "$NAME" ] && NAME="$1" || { echo "Unexpected arg: $1" >&2; exit 2; }; shift ;;
esac; done

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; C=$'\033[36m'; Z=$'\033[0m'
else B=""; G=""; Y=""; R=""; D=""; C=""; Z=""; fi
hdr(){ printf '\n%s== %s ==%s\n' "$B" "$1" "$Z"; }
ok(){ printf '  %s✓%s %s\n' "$G" "$Z" "$1"; }
warn(){ printf '  %s!%s %s\n' "$Y" "$Z" "$1"; }
info(){ printf '  %s·%s %s\n' "$D" "$Z" "$1"; }
die(){ printf '  %s✗%s %s\n' "$R" "$Z" "$1"; exit 1; }
ask(){ local __v="$1" __p="$2" __d="${3:-}" __i; if [ -n "$__d" ]; then read -r -p "  $__p [$__d]: " __i; else read -r -p "  $__p: " __i; fi; printf -v "$__v" '%s' "${__i:-$__d}"; }
mcp_summary(){
  [ "$MCP" -eq 1 ] || return 0
  echo "  ${B}GitHub MCP:${Z} wrote ${D}.mcp.json${Z} (remote GitHub server) and a token line in ${D}.envrc${Z}; both are safe to commit."
  if [ "$MCP_REF_PLACEHOLDER" -eq 1 ]; then
    warn "edit .envrc — point  op read 'op://VAULT/ITEM/token'  at your real 1Password item, then run 'direnv allow'."
  else
    echo "  ${D}Token resolves via  op read '$MCP_REF'  (gh ignores this var). Run 'direnv allow', then launch claude from here.${Z}"
  fi
}

[ -z "$NAME" ] && ask NAME "Project name" ""
[ -n "$NAME" ] || die "a project name is required"
case "$CUDA" in cpu|cu118|cu126|cu128|cu129|cu130) ;; *) die "--cuda must be one of: cpu cu118 cu126 cu128 cu129 cu130" ;; esac
# normalized distribution name for pyproject
PKG="$(printf '%s' "$NAME" | tr '[:upper:] ' '[:lower:]-' | tr -cs 'a-z0-9-' '-' | sed 's/^-//; s/-$//')"
ROOT="$NAME"
MCP_REF_PLACEHOLDER=0
if [ "$MCP" -eq 1 ] && [ -z "$MCP_REF" ]; then MCP_REF="op://VAULT/ITEM/token"; MCP_REF_PLACEHOLDER=1; fi

printf '%s%sNew project: %s%s  %s\n' "$B" "$G" "$NAME" "$Z" \
  "${D}python ${PYVER}$([ "$TORCH" -eq 1 ] && echo " · torch ${CUDA}")$([ "$PLAYWRIGHT" -eq 1 ] && echo " · playwright")$([ "$MCP" -eq 1 ] && echo " · github-mcp")$([ "$DRY" -eq 1 ] && echo " · DRY RUN")${Z}"

# tool checks (these come from your shell PATH; the script inherits it when run from zsh)
if [ "$INSTALL" -eq 1 ] && [ "$DRY" -eq 0 ]; then
  command -v uv >/dev/null 2>&1 || die "uv not found on PATH — run this from your normal shell (exec zsh) so uv is available."
fi

# refuse to clobber a non-empty existing dir
if [ -e "$ROOT" ] && [ -n "$(ls -A "$ROOT" 2>/dev/null)" ]; then die "'$ROOT' already exists and is not empty."; fi

write(){ # write PATH CONTENT [MODE]
  local p="$ROOT/$1" content="$2" mode="${3:-644}"
  if [ "$DRY" -eq 1 ]; then printf '\n%s--- would write %s ---%s\n%s\n' "$D" "$p" "$Z" "$content"; return; fi
  mkdir -p "$(dirname "$p")"; printf '%s\n' "$content" > "$p"; chmod "$mode" "$p"; ok "$1"
}

hdr "scaffold files"

# ---------- pyproject.toml ----------
DEPS=""; TORCH_INDEX=""; TORCH_SOURCES=""
if [ "$TORCH" -eq 1 ]; then
  DEPS=$'\n    "torch>=2.9.1",\n    "torchvision>=0.24.1",'
  if [ "$CUDA" != cpu ]; then
    TORCH_INDEX=$'\n[[tool.uv.index]]\nname = "pytorch-'"$CUDA"$'"\nurl = "https://download.pytorch.org/whl/'"$CUDA"$'"\nexplicit = true\n'
    TORCH_SOURCES=$'\n[tool.uv.sources]\ntorch = [{ index = "pytorch-'"$CUDA"$'", marker = "sys_platform == \'linux\' or sys_platform == \'win32\'" }]\ntorchvision = [{ index = "pytorch-'"$CUDA"$'", marker = "sys_platform == \'linux\' or sys_platform == \'win32\'" }]\n'
  fi
fi
DEVGROUP='"ruff", "pre-commit", "pytest"'
[ "$PLAYWRIGHT" -eq 1 ] && DEVGROUP="$DEVGROUP"', "pytest-playwright"'

write "pyproject.toml" "[project]
name = \"$PKG\"
version = \"0.1.0\"
description = \"\"
readme = \"README.md\"
requires-python = \">=$PYVER\"
dependencies = [$DEPS
]

[dependency-groups]
dev = [$DEVGROUP]

[tool.uv]
package = false
$TORCH_INDEX$TORCH_SOURCES
[tool.ruff]
line-length = 100
target-version = \"py${PYVER//./}\"

[tool.ruff.lint]
select = [\"E\", \"F\", \"I\", \"UP\", \"B\", \"SIM\"]

[tool.pytest.ini_options]
testpaths = [\"tests\"]"

# ---------- .python-version ----------
write ".python-version" "$PYVER"

# ---------- .gitignore ----------
write ".gitignore" "# Python
__pycache__/
*.py[cod]
.venv/
.pytest_cache/
.ruff_cache/
*.egg-info/

# Secrets — never commit the resolved .env; templates are kept
.env
.env.*
!.env.example
!.env.tpl

# Playwright
test-results/
playwright-report/
.cache/

# OS / editor
.DS_Store"

# ---------- direnv ----------
ENVRC="# uv-managed venv on PATH, plus session secrets if you've generated .env
layout uv
dotenv_if_exists .env"
if [ "$MCP" -eq 1 ]; then
  ENVRC="$ENVRC

# GitHub MCP token — resolved from 1Password into THIS folder's env only (never written to disk).
# .mcp.json references \${GITHUB_PERSONAL_ACCESS_TOKEN}; direnv populates it here on cd.
# gh does NOT read this variable, so it never interferes with your per-folder gh account.
export GITHUB_PERSONAL_ACCESS_TOKEN=\"\$(op read '$MCP_REF')\""
fi
write ".envrc" "$ENVRC"

# ---------- 1Password secrets scaffolding ----------
write ".env.tpl" "# 1Password template. Generate the real (gitignored) .env once per session with:
#   op inject -i .env.tpl -o .env
# Each value is an op:// secret reference, e.g.:
# OPENAI_API_KEY=op://Private/OpenAI/api_key
# DATABASE_URL=op://Private/$PKG/database_url"

write ".env.example" "# Non-secret example of the variables this project expects.
# Copy to .env and fill in, or use .env.tpl + 'op inject'.
# OPENAI_API_KEY=
# DATABASE_URL="

# ---------- GitHub MCP server (optional) ----------
# Remote HTTP server (no Docker). The token is NOT stored here: Claude Code expands
# \${GITHUB_PERSONAL_ACCESS_TOKEN} from the environment, which .envrc resolves from 1Password.
# Safe to commit — it references the token, it doesn't contain it.
if [ "$MCP" -eq 1 ]; then
  write ".mcp.json" "{
  \"mcpServers\": {
    \"github\": {
      \"type\": \"http\",
      \"url\": \"https://api.githubcopilot.com/mcp/\",
      \"headers\": {
        \"Authorization\": \"Bearer \${GITHUB_PERSONAL_ACCESS_TOKEN}\"
      }
    }
  }
}"
fi

# ---------- VS Code ----------
write ".vscode/settings.json" "{
  \"python.defaultInterpreterPath\": \"\${workspaceFolder}/.venv/bin/python\",
  \"python.terminal.activateEnvironment\": true,
  \"[python]\": {
    \"editor.defaultFormatter\": \"charliermarsh.ruff\",
    \"editor.formatOnSave\": true,
    \"editor.codeActionsOnSave\": { \"source.organizeImports\": \"explicit\" }
  },
  \"ruff.importStrategy\": \"fromEnvironment\"
}"

# ---------- pre-commit (local ruff hooks — always match the project's ruff) ----------
write ".pre-commit-config.yaml" "repos:
  - repo: local
    hooks:
      - id: ruff-check
        name: ruff check
        entry: uv run ruff check --fix
        language: system
        types: [python]
        require_serial: true
      - id: ruff-format
        name: ruff format
        entry: uv run ruff format
        language: system
        types: [python]
        require_serial: true"

# ---------- source + tests + verification ----------
write "main.py" "def main() -> None:
    print(\"hello from $PKG\")


if __name__ == \"__main__\":
    main()"

if [ "$TORCH" -eq 1 ]; then
  write "scripts/verify_gpu.py" "\"\"\"Verify PyTorch sees the GPU and actually runs a kernel on it.\"\"\"
import torch

print(\"torch:\", torch.__version__)
print(\"cuda build:\", torch.version.cuda)
print(\"cuda available:\", torch.cuda.is_available())
assert torch.cuda.is_available(), \"CUDA not available — check the NVIDIA driver and that $CUDA wheels installed\"

name = torch.cuda.get_device_name(0)
cap = torch.cuda.get_device_capability(0)
print(\"device:\", name)
print(\"capability: sm_%d%d\" % cap)

# Real kernel execution — this is what fails if the wheel lacks Blackwell (sm_120) kernels.
x = torch.randn(4096, 4096, device=\"cuda\")
torch.cuda.synchronize()
s = (x @ x).sum().item()
print(\"matmul on GPU ok (checksum %.3e)\" % s)

if cap == (12, 0):
    print(\"OK: Blackwell sm_120 detected and kernels execute\")
else:
    print(\"NOTE: capability is sm_%d%d (expected sm_120 for an RTX 50-series card)\" % cap)"
fi

if [ "$PLAYWRIGHT" -eq 1 ]; then
  write "tests/test_smoke.py" "\"\"\"Smoke test: Playwright can drive headless Chromium.\"\"\"
import pytest


@pytest.mark.parametrize(\"url\", [\"https://example.com\"])
def test_chromium_loads(page, url):
    page.goto(url)
    assert \"Example\" in page.title()"
fi

# ---------- README ----------
README_BODY="# $NAME

## Setup
\`\`\`bash
uv sync                 # create .venv and install everything
direnv allow            # auto-activate the venv on cd (and load .env if present)
op inject -i .env.tpl -o .env   # resolve secrets once per session (optional)
\`\`\`

## Run / test
\`\`\`bash
uv run python main.py$([ "$TORCH" -eq 1 ] && printf '\nuv run python scripts/verify_gpu.py   # confirm the GPU works')
uv run pytest$([ "$PLAYWRIGHT" -eq 1 ] && printf '            # runs the Playwright smoke test')
\`\`\`

PyTorch is pinned to the \`$CUDA\` wheel index in \`pyproject.toml\`."

if [ "$MCP" -eq 1 ]; then
  README_BODY="$README_BODY

## GitHub MCP server
This repo carries a project-scoped \`.mcp.json\` with the GitHub MCP server. The token is **not**
in the repo: Claude Code expands \`\${GITHUB_PERSONAL_ACCESS_TOKEN}\`, which \`.envrc\` resolves from
1Password (\`op read '$MCP_REF'\`) into this folder's environment only. \`gh\` never reads this
variable, so it can't disturb your per-folder \`gh\` account.

Setup:
1. Create a GitHub PAT with the scopes you want the agent to have (e.g. \`repo\`, \`read:org\`) and
   store it in 1Password. Point the \`op read\` reference in \`.envrc\` at that item.
2. \`direnv allow\` so the token loads on \`cd\`.
3. Launch \`claude\` from this folder — it picks up \`.mcp.json\` and the token from the environment.

Uses the remote HTTP server (no Docker). To run it locally via Docker instead, replace the
\`.mcp.json\` server block with:
\`\`\`json
{ \"mcpServers\": { \"github\": { \"command\": \"docker\",
  \"args\": [\"run\",\"-i\",\"--rm\",\"-e\",\"GITHUB_PERSONAL_ACCESS_TOKEN\",\"ghcr.io/github/github-mcp-server\"],
  \"env\": { \"GITHUB_PERSONAL_ACCESS_TOKEN\": \"\${GITHUB_PERSONAL_ACCESS_TOKEN}\" } } } }
\`\`\`"
fi
write "README.md" "$README_BODY"

# ---------- git init ----------
if [ "$DRY" -eq 0 ]; then
  hdr "git"
  ( cd "$ROOT" && git init -b main >/dev/null 2>&1 && ok "git initialised (identity comes from this directory's profile)" ) \
    || warn "git init skipped (git missing?)"
fi

# ---------- install + verify ----------
if [ "$DRY" -eq 1 ]; then hdr "summary"; mcp_summary; printf '\n%sDry run complete.%s Re-run without --dry-run to create it.\n' "$G$B" "$Z"; exit 0; fi

if [ "$INSTALL" -eq 0 ]; then
  hdr "summary"
  ok "files written and git initialised in ./$ROOT (installs skipped)"
  echo "  Next:  ${D}cd '$ROOT' && uv sync$([ "$PLAYWRIGHT" -eq 1 ] && echo " && uv run playwright install --with-deps chromium") && uv run pre-commit install && direnv allow${Z}"
  mcp_summary
  exit 0
fi

cd "$ROOT" || die "cannot enter $ROOT"
hdr "install (this downloads packages — first run can take a while)"
uv sync && ok "uv sync complete (.venv ready)" || warn "uv sync failed — see output above"
if [ "$PLAYWRIGHT" -eq 1 ]; then
  info "installing Chromium + system deps (may prompt for sudo for the OS libraries)…"
  uv run playwright install --with-deps chromium && ok "Playwright Chromium installed" || warn "playwright install failed — you can retry: uv run playwright install --with-deps chromium"
fi
command -v pre-commit >/dev/null 2>&1 || uv run pre-commit --version >/dev/null 2>&1
uv run pre-commit install >/dev/null 2>&1 && ok "pre-commit git hook installed" || warn "pre-commit install skipped"
if command -v direnv >/dev/null 2>&1; then direnv allow . >/dev/null 2>&1 && ok "direnv allowed (.envrc active on next cd)"; else info "direnv not found — skipping 'direnv allow'"; fi

# ---------- verification ----------
if [ "$TORCH" -eq 1 ]; then
  hdr "GPU verification"
  uv run python scripts/verify_gpu.py || warn "GPU check did not pass — review the output (driver / $CUDA wheels)"
fi
if [ "$PLAYWRIGHT" -eq 1 ]; then
  hdr "Playwright verification"
  uv run pytest -q tests/test_smoke.py && ok "Playwright drove headless Chromium" || warn "Playwright smoke test failed — review the output"
fi

hdr "summary"
ok "project ready in ./$ROOT"
echo "  ${D}cd '$ROOT'${Z}, then your venv auto-activates via direnv. Edit ${D}.env.tpl${Z} and run ${D}op inject -i .env.tpl -o .env${Z} for secrets."
mcp_summary
echo "  Make your first commit — it'll be signed with this directory's profile and show as Verified on GitHub."
