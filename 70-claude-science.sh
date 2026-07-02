#!/usr/bin/env bash
#
# 70-claude-science.sh — Install Claude Science (Anthropic's AI research workbench) on WSL2.
#
# Claude Science runs as a local daemon serving a web UI on 127.0.0.1 — under WSL2 the URL
# opens in your Windows browser via localhost forwarding (and $BROWSER=wopen). Requires a
# paid Claude plan (Pro/Max/Team/Enterprise) at sign-in. Official WSL2 requirements:
# WSL 2 (not 1), Ubuntu 24.04+ (its sandbox needs bubblewrap >= 0.8), socat, curl —
# and installation from INSIDE the distro (not a Windows-side download).
# Docs: claude.com/docs/claude-science/run-on-windows-wsl
#
# What it does:
#   1. Checks the prerequisites above (10-wsl-base.sh already provides bubblewrap + socat).
#   2. Runs the official installer if claude-science isn't already in ~/.local/bin
#      (--update re-runs the app's self-updater instead).
#   3. Adds a managed 'claude-science' block to ~/.zshrc with the `science` launcher:
#      start-or-reuse the daemon and open the UI in your Windows browser.
#
# Usage:
#   ./70-claude-science.sh             # install (no-op if present) + launcher block
#   ./70-claude-science.sh --update    # also run claude-science update
#   ./70-claude-science.sh --dry-run   # preview; write nothing
#
set -uo pipefail

DRY=0; UPDATE=0
for a in "$@"; do case "$a" in
  --dry-run|-n) DRY=1 ;;
  --update) UPDATE=1 ;;
  -h|--help) sed -n '2,/^set /{/^set /!p;}' "$0"; exit 0 ;;
  *) echo "Unknown option: $a" >&2; exit 2 ;;
esac; done

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; Z=$'\033[0m'
else B=""; G=""; Y=""; R=""; D=""; Z=""; fi
hdr(){ printf '\n%s== %s ==%s\n' "$B" "$1" "$Z"; }
ok(){ printf '  %s✓%s %s\n' "$G" "$Z" "$1"; }
warn(){ printf '  %s!%s %s\n' "$Y" "$Z" "$1"; }
info(){ printf '  %s·%s %s\n' "$D" "$Z" "$1"; }
die(){ printf '  %s✗%s %s\n' "$R" "$Z" "$1"; exit 1; }
backup_file(){ # copy $1 into ~/.local/state/wsl2-dev/backups (newest 5 kept); honours --dry-run
  local src="$1" base dir f i=0; [ -f "$src" ] || return 0
  base="$(basename "$src")"; dir="${XDG_STATE_HOME:-$HOME/.local/state}/wsl2-dev/backups"
  if [ "${DRY:-0}" -eq 1 ]; then printf '  %s· would back up %s%s\n' "${D:-}" "${src/#$HOME/\~}" "${Z:-}"; return 0; fi
  mkdir -p "$dir" && cp -p "$src" "$dir/${base}.$(date +%Y%m%d-%H%M%S).bak" \
    && printf '  %s✓%s backed up %s → %s/\n' "${G:-}" "${Z:-}" "${src/#$HOME/\~}" "${dir/#$HOME/\~}"
  while IFS= read -r f; do i=$((i+1)); [ "$i" -gt 5 ] && rm -f "$f"; done < <(printf '%s\n' "$dir/${base}".*.bak | sort -r)
}

BLOCK_NAME="claude-science"
strip_block(){ # file → stdout minus the named block (name-keyed; tolerates missing end marker)
  awk -v sp="# >>> ${BLOCK_NAME} " -v ep="# <<< ${BLOCK_NAME} " '
    k && index($0,ep)==1       {k=0; next}
    k && index($0,"# >>> ")==1 {k=0; print; next}
    k                          {next}
    index($0,sp)==1            {k=1; next}
    {print}' "$1"
}

printf '%s%sClaude Science — install + launcher%s  %s\n' "$B" "$G" "$Z" \
  "${D}$([ "$DRY" -eq 1 ] && echo '(DRY RUN — writes nothing)')${Z}"

# ---------- prerequisites ----------
hdr "prerequisites"
grep -qi microsoft /proc/version 2>/dev/null && ok "running under WSL" || warn "doesn't look like WSL — Claude Science works on plain Linux too, continuing"
. /etc/os-release 2>/dev/null || true
case "${VERSION_ID:-0}" in 2[4-9].*|[3-9][0-9].*) ok "Ubuntu ${VERSION_ID}" ;; *) warn "Ubuntu ${VERSION_ID:-unknown} — docs require 24.04+ (bubblewrap >= 0.8)" ;; esac
BWV="$(bwrap --version 2>/dev/null | awk '{print $2}')"
if [ -n "$BWV" ]; then
  case "$BWV" in 0.[0-7].*) die "bubblewrap $BWV < 0.8 — the sandbox won't run (Ubuntu 24.04 ships 0.9)" ;;
                 *)         ok "bubblewrap $BWV (>= 0.8)" ;; esac
else die "bubblewrap not installed — run 10-wsl-base.sh first"; fi
command -v socat >/dev/null 2>&1 && ok "socat present" || die "socat missing — run 10-wsl-base.sh first"
command -v curl  >/dev/null 2>&1 && ok "curl present"  || die "curl missing"

# ---------- install ----------
hdr "install"
CSBIN="$HOME/.local/bin/claude-science"
if [ -x "$CSBIN" ]; then
  ok "already installed  ${D}$("$CSBIN" --version 2>/dev/null | head -1)${Z}"
  if [ "$UPDATE" -eq 1 ]; then
    if [ "$DRY" -eq 1 ]; then info "would run: claude-science update"
    else "$CSBIN" update && ok "self-update complete" || warn "self-update failed — try: claude-science update"; fi
  fi
elif [ "$DRY" -eq 1 ]; then
  info "would run the official installer:  curl -fsSL https://claude.ai/install-claude-science.sh | bash"
else
  info "running the official installer (installs to ~/.local/bin)…"
  curl -fsSL https://claude.ai/install-claude-science.sh | bash || die "installer failed — see output above"
  [ -x "$CSBIN" ] && ok "installed  ${D}$("$CSBIN" --version 2>/dev/null | head -1)${Z}" || die "installer finished but $CSBIN is missing"
fi

# ---------- launcher block ----------
hdr "launcher (~/.zshrc block)"
ZRC="$HOME/.zshrc"
BLOCK="# >>> ${BLOCK_NAME} (managed by 70-claude-science.sh) >>>
# Claude Science — local AI research workbench (web UI on 127.0.0.1, daemon-based).
#   science          start the daemon if needed and open the UI in your Windows browser
#   science <cmd>    passthrough: status · url · logs · stop · update
science() {
  command -v claude-science >/dev/null 2>&1 || { print \"claude-science not installed — run 70-claude-science.sh\"; return 1; }
  if [ \$# -gt 0 ]; then command claude-science \"\$@\"; return; fi
  if ! claude-science status 2>/dev/null | command grep -q '\"running\": *true'; then
    print \"starting the Claude Science daemon…\"
    # Start with a linuxbrew-free PATH: the app's bwrap sandbox doesn't mount
    # /home/linuxbrew, so bash & tools must resolve to system paths that exist
    # inside it (brew's bash otherwise wins and micromamba setup fails).
    local sane_path=\"\${(j.:.)\${(@)path:#*linuxbrew*}}\"
    ( setsid env PATH=\"\$sane_path\" claude-science serve --no-browser >/dev/null 2>&1 & )
    local i
    for i in {1..30}; do
      claude-science status 2>/dev/null | command grep -q '\"running\": *true' && break
      sleep 1
    done
    claude-science status 2>/dev/null | command grep -q '\"running\": *true' \\
      || { print \"daemon didn't come up in 30s — check: claude-science logs\"; return 1; }
  fi
  # Open a fresh single-use login URL in the Windows browser ourselves — the app's
  # own browser-open doesn't reach Windows from WSL.
  local url; url=\"\$(claude-science url 2>/dev/null | command grep -oE 'https?://[^[:space:]]+' | head -1)\"
  if [ -n \"\$url\" ]; then wopen \"\$url\" && print \"opened in your Windows browser (single-use link; 'science' again for a fresh one)\"
  else print \"couldn't get a login URL — run: claude-science url  and paste it into your browser\"; return 1; fi
}
# <<< ${BLOCK_NAME} (managed by 70-claude-science.sh) <<<"
if [ "$DRY" -eq 1 ]; then
  printf '\n%s--- would write managed block into ~/.zshrc ---%s\n%s\n' "$D" "$Z" "$BLOCK"
else
  backup_file "$ZRC"; tmp="$(mktemp)"
  if [ -f "$ZRC" ] && grep -q "^# >>> ${BLOCK_NAME} " "$ZRC"; then
    grep -q "^# <<< ${BLOCK_NAME} " "$ZRC" || warn "existing ${BLOCK_NAME} block had no end marker — repairing"
    strip_block "$ZRC" > "$tmp"
  elif [ -f "$ZRC" ]; then cp "$ZRC" "$tmp"; fi
  printf '\n%s\n' "$BLOCK" >> "$tmp"; mv "$tmp" "$ZRC"
  ok "managed block written (science launcher)"
fi

# ---------- summary ----------
hdr "summary"
[ "$DRY" -eq 1 ] && { printf '\n%sDry run complete.%s Re-run without --dry-run to apply.\n' "$G$B" "$Z"; exit 0; }
echo "  ${B}1.${Z} Reload your shell:  ${D}exec zsh${Z}"
echo "  ${B}2.${Z} Launch:  ${D}science${Z}  — first run signs in via claude.ai (paid plan required)"
echo "  ${B}3.${Z} The UI opens in your Windows browser (localhost forwarding); ${D}science stop${Z} shuts the daemon down"
info "compute connectors (SSH/HPC, Modal) are configured inside the app — that's the designed cloud-burst path"
