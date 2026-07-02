#!/usr/bin/env bash
#
# 35-verify-setup.sh — Read-only health check for the WSL2 dev environment built by
#                      10-wsl-base.sh, 20-tooling.sh, and 30-shell.sh.
#
# Checks, in order:
#   A. apt packages           (10-wsl-base.sh)
#   B. toolchain on disk      (20-tooling.sh)  — verified at absolute paths
#   C. shell configuration    (30-shell.sh)    — verified by inspecting ~/.zshrc + files
#   D. LIVE interactive shell (zsh -ic)        — what your real shell actually resolves
#   E. interop & manual steps (informational)  — 1Password/Docker/GPU/git identity
#
# READ-ONLY: makes no changes to anything. Safe to run any time, from any folder.
# Exit code: 0 if all CRITICAL checks pass, 1 if any critical check fails.
#
# Usage:
#   ./35-verify-setup.sh                 # run all checks
#   ./35-verify-setup.sh --open-browser  # also fire a real wopen test (pops your Windows browser)
#
set -uo pipefail

OPEN_BROWSER=0
for a in "$@"; do case "$a" in
  --open-browser) OPEN_BROWSER=1 ;;
  -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
  *) echo "Unknown option: $a" >&2; exit 2 ;;
esac; done

if [ -t 1 ]; then GREEN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; DIM=$'\033[2m'; BLD=$'\033[1m'; Z=$'\033[0m'
else GREEN=""; YEL=""; RED=""; DIM=""; BLD=""; Z=""; fi
P=0; W=0; F=0
pass(){ printf '  %s✓%s %s\n' "$GREEN" "$Z" "$1"; P=$((P+1)); }
warn(){ printf '  %s!%s %s\n' "$YEL" "$Z" "$1"; W=$((W+1)); }
fail(){ printf '  %s✗%s %s\n' "$RED" "$Z" "$1"; F=$((F+1)); }
info(){ printf '  %s·%s %s\n' "$DIM" "$Z" "$1"; }
hdr(){ printf '\n%s== %s ==%s\n' "$BLD" "$1" "$Z"; }

# check a binary at an absolute path (or PATH name); pass if it runs
check_bin(){ # label, path-or-name, version-args(default --version), critical(1/0, default 1)
  local label="$1" target="$2" vflag="${3:---version}" crit="${4:-1}" resolved="" ver=""
  if [ -x "$target" ]; then resolved="$target"
  elif command -v "$target" >/dev/null 2>&1; then resolved="$(command -v "$target")"; fi
  if [ -n "$resolved" ]; then
    ver="$("$resolved" $vflag 2>&1 | head -1 | cut -c1-60)"
    pass "$label  ${DIM}$ver${Z}"
  else
    [ "$crit" -eq 1 ] && fail "$label not found (looked for: $target)" || warn "$label not found (looked for: $target)"
  fi
}

printf '%s%sWSL2 dev environment — verification%s\n' "$BLD" "$GREEN" "$Z"
info "read-only; checks steps 10/20/30 + git-setup pre-flight. $([ "$OPEN_BROWSER" -eq 1 ] && echo 'browser test ENABLED' || echo '(use --open-browser for a live browser test)')"

# locate brew (PATH-independent, since a bash subshell hasn't sourced .zshrc)
BREW=""
for c in "$(command -v brew 2>/dev/null || true)" /home/linuxbrew/.linuxbrew/bin/brew "$HOME/.linuxbrew/bin/brew"; do
  [ -n "$c" ] && [ -x "$c" ] && { BREW="$c"; break; }
done
BREW_PREFIX=""; [ -n "$BREW" ] && BREW_PREFIX="$("$BREW" --prefix 2>/dev/null)"

# ============================================================ A. apt packages
hdr "A. apt packages (10-wsl-base.sh)"
for p in build-essential cmake pkg-config htop tree zip ca-certificates socat bubblewrap; do
  if dpkg -s "$p" 2>/dev/null | grep -q 'Status: install ok installed'; then pass "$p"; else fail "$p NOT installed"; fi
done
command -v bwrap >/dev/null 2>&1 && pass "bwrap (bubblewrap) callable" || warn "bwrap not on PATH"
command -v socat >/dev/null 2>&1 && pass "socat callable" || warn "socat not on PATH"

# ============================================================ B. toolchain on disk
hdr "B. toolchain on disk (20-tooling.sh)"
check_bin "uv"         "$HOME/.local/bin/uv"        "--version"
# Python versions managed by uv
if [ -x "$HOME/.local/bin/uv" ]; then
  PYS="$("$HOME/.local/bin/uv" python list --only-installed 2>/dev/null || "$HOME/.local/bin/uv" python list 2>/dev/null)"
  # fall back to the install dir so a failed query (e.g. sandboxed run) can't read as "not found"
  has_uv_py(){ echo "$PYS" | grep -q "$1" || ls -d "$HOME/.local/share/uv/python/cpython-${1}"* >/dev/null 2>&1; }
  has_uv_py 3.12 && pass "uv Python 3.12 present" || warn "uv Python 3.12 not found"
  has_uv_py 3.13 && pass "uv Python 3.13 present" || warn "uv Python 3.13 not found"
fi
check_bin "pre-commit" "$HOME/.local/bin/pre-commit" "--version"
# fnm (default vs legacy dir)
FNM=""; for c in "$HOME/.local/share/fnm/fnm" "$HOME/.fnm/fnm"; do [ -x "$c" ] && { FNM="$c"; break; }; done
[ -n "$FNM" ] && check_bin "fnm" "$FNM" "--version" || fail "fnm not found (~/.local/share/fnm/fnm)"
# fnm has a Node version installed?
NVDIR="$HOME/.local/share/fnm/node-versions"; [ -d "$HOME/.fnm/node-versions" ] && NVDIR="$HOME/.fnm/node-versions"
if [ -d "$NVDIR" ] && [ -n "$(ls -A "$NVDIR" 2>/dev/null)" ]; then
  pass "fnm has Node installed  ${DIM}$(ls "$NVDIR" | tr '\n' ' ')${Z}"
else fail "fnm has no Node version installed (run: fnm install --lts)"; fi
check_bin "Bun"        "$HOME/.bun/bin/bun"          "--version"
check_bin "AWS CLI"    "aws"                          "--version"
# Homebrew CLI tools
if [ -n "$BREW_PREFIX" ]; then
  for t in starship zoxide direnv bat eza gitleaks fzf; do
    check_bin "$t" "$BREW_PREFIX/bin/$t" "--version" 1
  done
else
  fail "Homebrew not found — starship/zoxide/direnv/bat/eza/gitleaks/fzf unverified"
fi

# ============================================================ C. shell configuration
hdr "C. shell configuration (30-shell.sh)"
ZRC="$HOME/.zshrc"
if [ -f "$ZRC" ]; then
  grep -qF '>>> wsl2-dev-setup' "$ZRC" && pass "wsl2-dev-setup managed block present" || fail "wsl2-dev-setup block missing from ~/.zshrc"
  grep -qF '>>> comfort-shell'  "$ZRC" && pass "your comfort-shell block still intact" || warn "comfort-shell block not found (yours)"
  grep -q  '\.local/bin:\$PATH' "$ZRC" && pass "~/.local/bin added to PATH" || fail "~/.local/bin PATH line missing"
  grep -q  'fnm env --use-on-cd' "$ZRC" && pass "fnm init line present" || fail "fnm init line missing"
  grep -q  'nvm4w'              "$ZRC" && pass "Windows-node prune line present" || warn "prune line missing"
  grep -q  'alias op="op.exe"'  "$ZRC" && pass 'alias op="op.exe" present' || warn "op alias missing"
  grep -q  'alias open="wopen"' "$ZRC" && pass 'alias open="wopen" present' || warn "open alias missing"
  grep -q  'BROWSER='           "$ZRC" && pass "BROWSER export present" || warn "BROWSER export missing"
  grep -q  'fzf --zsh >/dev/null' "$ZRC" && pass "fzf line is version-robust" || warn "fzf line may be the old bare version"
  BDIR="${XDG_STATE_HOME:-$HOME/.local/state}/wsl2-dev/backups"
  ls "$BDIR"/.zshrc.*.bak >/dev/null 2>&1 && info "backup(s) found: $(ls "$BDIR"/.zshrc.*.bak | wc -l) in ${BDIR/#$HOME/\~}" || info "no ~/.zshrc backups yet (created on first managed edit)"
else
  fail "~/.zshrc does not exist"
fi
# helper files
[ -x "$HOME/.local/bin/wopen" ] && pass "wopen exists and is executable" || fail "~/.local/bin/wopen missing or not executable"
if [ -L "$HOME/.local/bin/xdg-open" ] && [ "$(readlink -f "$HOME/.local/bin/xdg-open" 2>/dev/null)" = "$(readlink -f "$HOME/.local/bin/wopen" 2>/dev/null)" ]; then
  pass "xdg-open -> wopen symlink correct"
else warn "xdg-open symlink not pointing at wopen"; fi
grep -q 'explorer.exe' "$HOME/.local/bin/wopen" 2>/dev/null && pass "wopen uses explorer.exe (expected)" || warn "wopen content unexpected"
[ -f "$HOME/.config/direnv/direnvrc" ] && pass "direnvrc present (layout uv)" || warn "~/.config/direnv/direnvrc missing"

# ============================================================ D. live interactive shell
hdr "D. live interactive resolution (what your real zsh sees)"
if command -v zsh >/dev/null 2>&1; then
  LIVE="$(zsh -ic '
    print -r -- "node=$(command -v node 2>/dev/null)"
    print -r -- "node_v=$(node -v 2>/dev/null)"
    print -r -- "npm=$(command -v npm 2>/dev/null)"
    print -r -- "npm_v=$(npm -v 2>/dev/null)"
    print -r -- "uv=$(command -v uv 2>/dev/null)"
    print -r -- "bun=$(command -v bun 2>/dev/null)"
    print -r -- "browser=$BROWSER"
    print -r -- "aliop=$(alias op 2>/dev/null)"
    print -r -- "aliopen=$(alias open 2>/dev/null)"
    print -r -- "wa_node=$(which -a node 2>/dev/null | tr "\n" ";")"
    print -r -- "wa_npm=$(which -a npm 2>/dev/null | tr "\n" ";")"
    print -r -- "starship=$(command -v starship 2>/dev/null)"
    print -r -- "direnv=$(command -v direnv 2>/dev/null)"
    print -r -- "zoxide=$(command -v zoxide 2>/dev/null)"
    print -r -- "fzfzsh=$(fzf --zsh >/dev/null 2>&1 && echo yes || echo no)"
  ' 2>/dev/null)"
  live(){ printf '%s\n' "$LIVE" | grep "^$1=" | head -1 | cut -d= -f2-; }

  NODE="$(live node)"; NODEV="$(live node_v)"; WANODE="$(live wa_node)"
  if [ -n "$NODEV" ]; then
    case "$NODE" in *fnm_multishells*|*"/.local/share/fnm/"*|*"/.fnm/"*) pass "node -> fnm ($NODEV)  ${DIM}$NODE${Z}";; *) warn "node runs ($NODEV) but not via fnm: $NODE";; esac
  else fail "node does not run in your shell (fnm default may be unset: fnm default lts-latest)"; fi
  case "$WANODE" in *"/mnt/c/"*) fail "Windows node still on PATH (leak): $WANODE";; *) [ -n "$NODEV" ] && pass "no Windows-node leak in PATH";; esac

  NPMV="$(live npm_v)"; WANPM="$(live wa_npm)"
  [ -n "$NPMV" ] && pass "npm runs ($NPMV)  ${DIM}$(live npm)${Z}" || fail "npm does not run in your shell"
  case "$WANPM" in *"/mnt/c/"*) fail "Windows npm still on PATH (leak): $WANPM";; *) [ -n "$NPMV" ] && pass "no Windows-npm leak in PATH";; esac

  UVL="$(live uv)";  case "$UVL" in *"/.local/bin/uv") pass "uv -> ~/.local/bin/uv";; "") fail "uv not on live PATH";; *) warn "uv resolves elsewhere: $UVL";; esac
  BUNL="$(live bun)"; case "$BUNL" in *"/.bun/bin/bun") pass "bun -> ~/.bun/bin/bun";; "") fail "bun not on live PATH";; *) warn "bun resolves elsewhere: $BUNL";; esac

  BR="$(live browser)"; case "$BR" in *"/.local/bin/wopen") pass "\$BROWSER -> wopen";; "") fail "\$BROWSER not set in your shell";; *) warn "\$BROWSER set to: $BR";; esac
  case "$(live aliop)"   in *op.exe*) pass "alias op active";; *) warn "op alias not active in shell";; esac
  case "$(live aliopen)" in *wopen*)  pass "alias open active";; *) warn "open alias not active in shell";; esac

  [ -n "$(live starship)" ] && pass "starship active (your prompt)" || warn "starship not resolving live"
  [ -n "$(live direnv)" ]   && pass "direnv active" || warn "direnv not resolving live"
  [ -n "$(live zoxide)" ]   && pass "zoxide active (z command)" || warn "zoxide not resolving live"
  [ "$(live fzfzsh)" = "yes" ] && pass "fzf --zsh works (no startup error)" || warn "fzf --zsh unsupported live — block falls back to apt files"
else
  fail "zsh not found — cannot check live shell"
fi

# ============================================================ E. interop & manual steps
hdr "E. interop & manual steps (informational)"
command -v explorer.exe >/dev/null 2>&1 && pass "explorer.exe reachable (wopen backend)" || warn "explorer.exe not reachable — wopen won't open Windows"
command -v op.exe >/dev/null 2>&1 && info "op.exe reachable (1Password CLI — app must be running/unlocked to use)" || info "op.exe not reachable yet (set up the 1Password app + SSH agent)"
if command -v docker >/dev/null 2>&1; then
  if timeout 6 docker info >/dev/null 2>&1; then pass "docker daemon reachable"; else warn "docker CLI present but daemon unreachable (start Docker Desktop / enable WSL integration)"; fi
else info "docker not on PATH yet (manual: enable Docker Desktop WSL integration)"; fi
if command -v nvidia-smi >/dev/null 2>&1; then
  info "GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
else info "nvidia-smi not found (GPU driver is a Windows-side manual step)"; fi
GN="$(git config --global user.name 2>/dev/null || true)"; GE="$(git config --global user.email 2>/dev/null || true)"
if [ -n "$GN" ] && [ -n "$GE" ]; then info "git identity: $GN <$GE>"; else info "git identity not set yet (expected — that's the next step)"; fi

# ============================================================ F. 40-git-setup.sh pre-flight
hdr "F. 40-git-setup.sh pre-flight (1Password + agent bridge + gh)"
# 1Password CLI — used to auto-pull each profile's public key
if command -v op.exe >/dev/null 2>&1; then
  if timeout 8 op.exe --version >/dev/null 2>&1; then pass "op.exe reachable  ${DIM}$(op.exe --version 2>/dev/null | tr -d '\r')${Z}"
  else warn "op.exe on PATH but not responding — make sure the 1Password app is running"; fi
else warn "op.exe not reachable — 1Password → Settings → Developer → 'Integrate with 1Password CLI' (else you paste public keys manually)"; fi
# 1Password SSH agent pipe + whether the Windows ssh-agent service is competing for it
if command -v powershell.exe >/dev/null 2>&1; then
  PSOUT="$(timeout 12 powershell.exe -NoProfile -Command '$p=[bool]([System.IO.Directory]::GetFiles("\\.\pipe\") -match "openssh-ssh-agent"); $s=(Get-Service ssh-agent -ErrorAction SilentlyContinue).Status; "PIPE=$p AGENTSVC=$s"' 2>/dev/null | tr -d '\r')"
  case "$PSOUT" in
    *PIPE=True*) pass "OpenSSH agent pipe is being served (1Password if you enabled its SSH agent)" ;;
    *PIPE=False*) warn "nothing serving the OpenSSH agent pipe — turn ON 1Password → Settings → Developer → 'Use the SSH agent'" ;;
    *)            info "couldn't read the agent pipe from Windows (skipped)" ;;
  esac
  case "$PSOUT" in
    *AGENTSVC=Running*) warn "Windows 'ssh-agent' service is Running — it competes with 1Password for the same pipe; set it to Disabled if SSH auth misbehaves" ;;
    *AGENTSVC=*)        info "Windows ssh-agent service not running (good — no pipe competition)" ;;
  esac
else
  info "powershell.exe not reachable — skipping the agent-pipe check"
fi
# npiperelay.exe — Windows side of the bridge
command -v npiperelay.exe >/dev/null 2>&1 && pass "npiperelay.exe present (agent bridge ready)" || warn "npiperelay.exe not found — install on Windows: winget install albertony.npiperelay"
# socat — WSL side of the bridge (from 10-wsl-base.sh)
command -v socat >/dev/null 2>&1 && pass "socat present (WSL side of bridge)" || warn "socat missing — re-run 10-wsl-base.sh"
# gh — optional, for PRs / repo management
if command -v gh >/dev/null 2>&1; then pass "gh present  ${DIM}$(gh --version 2>/dev/null | head -1)${Z}"
else info "gh (GitHub CLI) not installed — optional; 'brew install gh' if you want it (SSH already covers push/pull)"; fi

# optional live browser test
if [ "$OPEN_BROWSER" -eq 1 ]; then
  hdr "live browser test"
  if [ -x "$HOME/.local/bin/wopen" ]; then "$HOME/.local/bin/wopen" https://example.com && info "fired wopen https://example.com — check your Windows browser"; else fail "wopen not available"; fi
fi

# ============================================================ summary
hdr "summary"
printf '  %s%d passed%s   %s%d warnings%s   %s%d failed%s\n' "$GREEN" "$P" "$Z" "$YEL" "$W" "$Z" "$RED" "$F" "$Z"
echo
if [ "$F" -eq 0 ]; then
  printf '%sAll critical checks passed.%s Warnings above are non-blocking (manual/future steps).\n' "$GREEN$BLD" "$Z"; exit 0
else
  printf '%s%d critical check(s) failed — see ✗ above.%s\n' "$RED$BLD" "$F" "$Z"; exit 1
fi
