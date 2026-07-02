#!/usr/bin/env bash
#
# 10-wsl-base.sh — Base apt setup for a WSL2 Ubuntu 24.04 dev environment.
#
# Does three things, nothing more:
#   1. apt update + full-upgrade
#   2. install the essential dev package set
#        build-essential cmake pkg-config htop tree zip ca-certificates socat bubblewrap
#        mesa-utils glmark2   (GL diagnostics: glxinfo renderer check + benchmark for WSLg)
#   3. mask getty@tty1.service (cosmetic; silences the harmless failed-unit noise in WSL)
#
# Properties:
#   - Idempotent: safe to re-run (apt installs are no-ops if already present; masking is too).
#   - Reversible: the only system change is masking getty@tty1, undone with
#       sudo systemctl unmask getty@tty1.service
#   - No secrets, no account/auth, no Windows-side actions.
#   - Assumes /etc/wsl.conf is already in place (it is) — this script does NOT touch it.
#
# Usage:
#   chmod +x 10-wsl-base.sh
#   ./10-wsl-base.sh            # run for real
#   ./10-wsl-base.sh --dry-run  # preview only: simulate the apt actions, change nothing
#
set -uo pipefail

# ---------- options ----------
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg (use --dry-run or --help)" >&2; exit 2 ;;
  esac
done

# ---------- pretty ----------
if [ -t 1 ]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; Z=$'\033[0m'
else B=""; G=""; Y=""; R=""; D=""; Z=""; fi
say()  { printf '\n%s== %s ==%s\n' "$B" "$1" "$Z"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$Z" "$1"; }
warn() { printf '  %s!%s %s\n' "$Y" "$Z" "$1"; }
err()  { printf '  %s✗%s %s\n' "$R" "$Z" "$1"; }
note() { printf '  %s%s%s\n' "$D" "$1" "$Z"; }

# ---------- preconditions ----------
if ! command -v apt-get >/dev/null 2>&1; then
  err "apt-get not found — this script targets Debian/Ubuntu (your distro is Ubuntu 24.04)."
  exit 1
fi
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  err "Not running as root and 'sudo' is not installed. Re-run as root or install sudo first."
  exit 1
fi

APT="$SUDO env DEBIAN_FRONTEND=noninteractive apt-get"
PKGS=(build-essential cmake pkg-config htop tree zip ca-certificates socat bubblewrap mesa-utils glmark2)

printf '%s%sWSL2 base setup%s  %s(%s)%s\n' "$B" "$G" "$Z" "$D" \
  "$([ "$DRY_RUN" -eq 1 ] && echo 'DRY RUN — nothing will be changed' || echo 'live run')" "$Z"
note "packages: ${PKGS[*]}"

# ---------- 1. update ----------
say "apt update"
if [ "$DRY_RUN" -eq 1 ]; then
  # 'update' refreshes the package index; harmless and needed even to simulate accurately.
  if $SUDO apt-get update; then ok "package index refreshed"; else
    err "apt-get update failed — check connectivity (and your WSL network settings if offline)."; exit 1
  fi
else
  if $APT update; then ok "package index refreshed"; else
    err "apt-get update failed — check connectivity (and your WSL network settings if offline)."; exit 1
  fi
fi

# ---------- 2. full-upgrade ----------
say "apt full-upgrade"
UPGRADABLE="$(apt-get -s full-upgrade 2>/dev/null | grep -c '^Inst' || true)"
note "${UPGRADABLE} package(s) would be upgraded"
if [ "$DRY_RUN" -eq 1 ]; then
  note "(dry run) skipping the actual upgrade"
else
  if $APT -y full-upgrade; then ok "system upgraded"; else
    err "full-upgrade reported an error — review the output above."; exit 1
  fi
fi

# ---------- 3. install essentials ----------
say "install essential dev packages"
if [ "$DRY_RUN" -eq 1 ]; then
  # -s simulates: shows what would be installed without touching the system.
  $SUDO apt-get -s install "${PKGS[@]}" >/tmp/_10base_sim 2>&1
  NEW="$(grep -c '^Inst' /tmp/_10base_sim || true)"
  if grep -q 'Unable to locate package' /tmp/_10base_sim; then
    err "One or more package names did not resolve:"; grep 'Unable to locate package' /tmp/_10base_sim | sed 's/^/    /'
    rm -f /tmp/_10base_sim; exit 1
  fi
  ok "all ${#PKGS[@]} package names resolve; ${NEW} would be newly installed"
  rm -f /tmp/_10base_sim
else
  if $APT -y install "${PKGS[@]}"; then ok "essential packages installed"; else
    err "package install failed — review the output above."; exit 1
  fi
fi

# ---------- 4. mask getty@tty1 ----------
say "mask getty@tty1.service (cosmetic)"
if [ ! -d /run/systemd/system ]; then
  warn "systemd is not the active init here — skipping mask (nothing to silence)."
elif systemctl is-enabled getty@tty1.service 2>/dev/null | grep -q masked; then
  ok "already masked — nothing to do"
else
  if [ "$DRY_RUN" -eq 1 ]; then
    note "(dry run) would run: systemctl mask getty@tty1.service"
  elif $SUDO systemctl mask getty@tty1.service >/dev/null 2>&1; then
    ok "getty@tty1.service masked (undo with: sudo systemctl unmask getty@tty1.service)"
  else
    warn "could not mask getty@tty1.service (non-fatal)."
  fi
fi

# ---------- summary ----------
say "summary"
MISSING=0
for p in "${PKGS[@]}"; do
  if dpkg -s "$p" 2>/dev/null | grep -q 'Status: install ok installed'; then
    ok "$p"
  else
    if [ "$DRY_RUN" -eq 1 ]; then note "$p (not yet installed — dry run)"; else err "$p MISSING"; MISSING=1; fi
  fi
done
echo
if [ "$DRY_RUN" -eq 1 ]; then
  printf '%sDry run complete.%s Re-run without --dry-run to apply.\n' "$G$B" "$Z"
elif [ "$MISSING" -eq 0 ]; then
  printf '%sBase setup complete.%s Next: 20-tooling.sh (uv, fnm+node, Bun, AWS CLI, shell tools).\n' "$G$B" "$Z"
else
  printf '%sFinished with some packages missing — see ✗ above.%s\n' "$Y$B" "$Z"; exit 1
fi
