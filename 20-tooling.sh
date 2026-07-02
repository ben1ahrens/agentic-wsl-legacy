#!/usr/bin/env bash
#
# 20-tooling.sh — Install the dev toolchain for a WSL2 Ubuntu 24.04 environment,
#                 WITHOUT making any permanent change to your shell front-end.
#
# Installs (binaries only — additive, nothing existing is changed or shadowed):
#   - uv            (+ Python 3.12 and 3.13)
#   - fnm           (+ Node LTS)
#   - Bun
#   - AWS CLI v2     (system-wide, /usr/local — the only step that needs sudo)
#   - starship, zoxide, direnv, bat, eza, gitleaks  (via Homebrew, if present)
#   - pre-commit    (via `uv tool`)
#
# ZERO shell-front-end changes, guaranteed:
#   - uv is installed with --no-modify-path, fnm with --skip-shell.
#   - As a backstop, this script SNAPSHOTS ~/.zshrc ~/.bashrc ~/.profile ~/.zprofile
#     at the start and RESTORES them on exit (even on error/Ctrl-C). So whatever any
#     installer tries to append, your shell config ends up byte-for-byte unchanged.
#   - Because PATH is NOT wired here, the new commands appear only after 30-shell.sh.
#     This script prints a one-liner to use them in the current session if you want.
#
# Does NOT touch: /etc/wsl.conf, your login shell, aliases, prompt, or git config.
#
# Usage:
#   chmod +x 20-tooling.sh
#   ./20-tooling.sh --dry-run   # print the exact plan + prereq checks, install nothing
#   ./20-tooling.sh             # install
#
set -uo pipefail

# ---------- options ----------
DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run|-n) DRY=1 ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) echo "Unknown option: $a (use --dry-run or --help)" >&2; exit 2 ;;
  esac
done

# ---------- pretty ----------
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; Z=$'\033[0m'
else B=""; G=""; Y=""; R=""; D=""; Z=""; fi
hdr()  { printf '\n%s== %s ==%s\n' "$B" "$1" "$Z"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$Z" "$1"; }
warn() { printf '  %s!%s %s\n' "$Y" "$Z" "$1"; }
err()  { printf '  %s✗%s %s\n' "$R" "$Z" "$1"; }
note() { printf '  %s%s%s\n' "$D" "$1" "$Z"; }

# run a shell command string; in dry-run, just print it
step() {  # step "<command string>"
  if [ "$DRY" -eq 1 ]; then printf '    %s$ %s%s\n' "$D" "$1" "$Z"; return 0; fi
  bash -c "$1"
}

# ---------- sudo / prereqs ----------
if [ "$(id -u)" -eq 0 ]; then SUDO=""; elif command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else
  err "Need root or sudo for the AWS CLI step. Re-run as root or install sudo."; exit 1; fi
for bin in curl unzip; do
  command -v "$bin" >/dev/null 2>&1 || { err "'$bin' missing — run 10-wsl-base.sh first."; exit 1; }
done

printf '%s%sDev toolchain install%s  %s(%s)%s\n' "$B" "$G" "$Z" "$D" \
  "$([ "$DRY" -eq 1 ] && echo 'DRY RUN — installs nothing' || echo 'live run')" "$Z"

# ---------- shell-config snapshot + guaranteed restore ----------
RCS=("$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile" "$HOME/.zprofile")
BKP="$(mktemp -d "${TMPDIR:-/tmp}/20tooling-rcbackup.XXXXXX")"
restore_rcs() {
  local changed=0
  for f in "${RCS[@]}"; do
    local saved="$BKP/$(basename "$f")"
    if [ -f "$saved" ]; then
      if ! cmp -s "$saved" "$f" 2>/dev/null; then cp -f "$saved" "$f"; changed=1; fi
    elif [ -f "$f" ] && [ -f "$BKP/.absent_$(basename "$f")" ]; then
      rm -f "$f"; changed=1   # file did not exist before; an installer created it -> remove
    fi
  done
  [ "$changed" -eq 1 ] && printf '  %srestored shell config to its original state%s\n' "$D" "$Z"
  rm -rf "$BKP"
}
if [ "$DRY" -eq 0 ]; then
  for f in "${RCS[@]}"; do
    if [ -f "$f" ]; then cp -f "$f" "$BKP/$(basename "$f")"; else touch "$BKP/.absent_$(basename "$f")"; fi
  done
  trap restore_rcs EXIT INT TERM
  note "snapshotted shell config (will be restored unchanged on exit)"
else
  note "(dry run) would snapshot + restore: ${RCS[*]}"
fi

# ---------- uv (+ Python) ----------
hdr "uv  (+ Python 3.12 / 3.13)"
UV="$HOME/.local/bin/uv"
if command -v uv >/dev/null 2>&1 || [ -x "$UV" ]; then
  [ -x "$UV" ] || UV="$(command -v uv)"; ok "uv present ($("$UV" --version 2>/dev/null))"; step "\"$UV\" self update >/dev/null 2>&1 || true"
else
  step "curl -LsSf https://astral.sh/uv/install.sh | sh -s -- --no-modify-path" && ok "uv installed (PATH untouched)"
fi
step "\"$UV\" python install 3.12 3.13" && ok "Python 3.12 + 3.13 available to uv"

# ---------- fnm (+ Node LTS) ----------
hdr "fnm  (+ Node LTS)"
step "curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell" && ok "fnm installed (--skip-shell: shell config untouched)"
FNM=""
for c in "$HOME/.local/share/fnm/fnm" "$HOME/.fnm/fnm" "$(command -v fnm 2>/dev/null || true)"; do
  [ -n "$c" ] && [ -x "$c" ] && { FNM="$c"; break; }
done
if [ "$DRY" -eq 1 ]; then note "(dry run) would run: <fnm> install --lts && <fnm> default lts-latest"
elif [ -n "$FNM" ]; then
  "$FNM" install --lts && ok "Node LTS installed via fnm"
  "$FNM" default lts-latest >/dev/null 2>&1 || true
else warn "fnm binary not found post-install — Node LTS step skipped (re-run, or check installer output)."; fi

# ---------- Bun ----------
hdr "Bun"
BUN="$HOME/.bun/bin/bun"
if [ -x "$BUN" ] || command -v bun >/dev/null 2>&1; then
  [ -x "$BUN" ] || BUN="$(command -v bun)"; ok "Bun present ($("$BUN" --version 2>/dev/null)); upgrading"; step "\"$BUN\" upgrade >/dev/null 2>&1 || true"
else
  # Bun's installer edits rc files; our EXIT restore reverts that.
  step "curl -fsSL https://bun.sh/install | bash" && ok "Bun installed (its rc edits will be reverted on exit)"
fi

# ---------- AWS CLI v2 ----------
hdr "AWS CLI v2  (system-wide, needs sudo)"
if command -v aws >/dev/null 2>&1; then
  note "existing aws found ($(aws --version 2>&1 | awk '{print $1}')) — updating"
  step "tmp=\$(mktemp -d); cd \"\$tmp\"; curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o a.zip && unzip -q a.zip && $SUDO ./aws/install --update && cd / && rm -rf \"\$tmp\"" && ok "AWS CLI v2 updated"
else
  step "tmp=\$(mktemp -d); cd \"\$tmp\"; curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o a.zip && unzip -q a.zip && $SUDO ./aws/install && cd / && rm -rf \"\$tmp\"" && ok "AWS CLI v2 installed"
fi

# ---------- Homebrew CLI tools ----------
hdr "shell tools via Homebrew  (starship zoxide direnv bat eza gitleaks fzf atuin)"
BREW=""
for c in "$(command -v brew 2>/dev/null || true)" /home/linuxbrew/.linuxbrew/bin/brew "$HOME/.linuxbrew/bin/brew"; do
  [ -n "$c" ] && [ -x "$c" ] && { BREW="$c"; break; }
done
if [ -z "$BREW" ]; then
  warn "Homebrew not found — skipping starship/zoxide/direnv/bat/eza/gitleaks."
  note "30-shell.sh needs starship/zoxide/direnv; install brew or apt-equivalents before running it."
else
  ok "using brew at $BREW"
  # `eval brew shellenv` only affects THIS process (no rc edit).
  [ "$DRY" -eq 0 ] && eval "$("$BREW" shellenv)"
  step "brew install starship zoxide direnv bat eza gitleaks fzf atuin" && ok "shell tools installed (inert until 30-shell.sh adds their init hooks)"
fi

# ---------- pre-commit ----------
hdr "pre-commit  (via uv tool)"
step "\"$UV\" tool install pre-commit" && ok "pre-commit installed (gitleaks runs as its hook, fetched per-repo)"

# ---------- summary ----------
hdr "summary"
check() {  # check "<label>" "<path-or-cmd>"
  if [ "$DRY" -eq 1 ]; then note "$1 (dry run)"; return; fi
  if [ -x "$2" ] || command -v "$2" >/dev/null 2>&1; then ok "$1"; else err "$1 NOT found"; fi
}
check "uv"        "$UV"
check "Python(uv)" "$UV"
check "fnm"       "${FNM:-fnm}"
check "Bun"       "$BUN"
check "aws"       "aws"
[ -n "$BREW" ] && for t in starship zoxide direnv bat eza gitleaks fzf atuin; do check "$t" "$t"; done
check "pre-commit" "$HOME/.local/bin/pre-commit"

echo
if [ "$DRY" -eq 1 ]; then
  printf '%sDry run complete.%s Re-run without --dry-run to install.\n' "$G$B" "$Z"
else
  printf '%sToolchain installed — your shell config was left unchanged.%s\n' "$G$B" "$Z"
  echo
  note "These tools are on disk but NOT on your PATH until 30-shell.sh runs."
  note "To use them in THIS session only (nothing persistent), run:"
  printf '    %sexport PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"%s\n' "$D" "$Z"
  [ -n "$FNM" ] && printf '    %seval "$(%s env)"%s\n' "$D" "$FNM" "$Z"
  echo
  printf '%sNext: 30-shell.sh — wires PATH and tool init into a backed-up, reviewable .zshrc block.%s\n' "$B" "$Z"
fi
