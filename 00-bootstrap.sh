#!/usr/bin/env bash
#
# 00-bootstrap.sh — run the whole provisioning pipeline in order, on a fresh machine
# or to converge an existing one. Every child script is idempotent, so this is safe
# to re-run; a failed step can be fixed and the bootstrap simply run again.
#
# Order:
#   10-wsl-base.sh        apt base layer (needs sudo)
#   20-tooling.sh         uv / fnm+Node / Bun / AWS CLI / brew tools / pre-commit
#   30-shell.sh           wsl2-dev-setup ~/.zshrc block (+ wopen, direnvrc)
#   40-git-setup.sh       multi-account git (INTERACTIVE: 1Password key creation)
#   45-github-profiles.sh gh auth per account (INTERACTIVE: browser logins)
#   48-win-folders.sh     Windows Downloads/OneDrive bridges (interactive prompts)
#   50-shortcuts.sh       dev-shortcuts block + docs/notify/lab/onboard commands
#   60-github-mcp.sh      per-profile GitHub-MCP tokens (claude wrapper + ghmcp)
#   65-agent-fleet.sh     Claude sandbox + hooks, Codex config, codexr, skills
#   70-claude-science.sh  Claude Science install + science launcher
#   35-verify-setup.sh    final health check (A–J)
#
# Each step asks before running (Enter = yes). Between 30 and 40 the shell must be
# reloaded — the bootstrap handles that by continuing in the same run (children
# don't depend on the live shell), but run `exec zsh` yourself when it finishes.
#
# Usage:
#   ./00-bootstrap.sh             # interactive, step by step
#   ./00-bootstrap.sh --dry-run   # every mutating child in --dry-run; verify runs read-only
#
set -uo pipefail
cd "$(dirname "$0")" || exit 1

DRY=0
for a in "$@"; do case "$a" in
  --dry-run|-n) DRY=1 ;;
  -h|--help) sed -n '2,/^set /{/^set /!p;}' "$0"; exit 0 ;;
  *) echo "Unknown option: $a" >&2; exit 2 ;;
esac; done

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; Z=$'\033[0m'
else B=""; G=""; Y=""; R=""; D=""; Z=""; fi
hdr(){ printf '\n%s== %s ==%s\n' "$B" "$1" "$Z"; }
ok(){ printf '  %s✓%s %s\n' "$G" "$Z" "$1"; }
warn(){ printf '  %s!%s %s\n' "$Y" "$Z" "$1"; }
yesno(){ local __p="$1" __i; read -r -p "  $__p [Y/n]: " __i; case "${__i:-y}" in y|Y|yes|YES) return 0;; *) return 1;; esac; }

STEPS=(
  "10-wsl-base.sh|apt base layer (sudo; full-upgrade + essentials + GL diagnostics)"
  "20-tooling.sh|uv · fnm/Node · Bun · AWS CLI · brew tools · pre-commit"
  "30-shell.sh|wsl2-dev-setup ~/.zshrc block, wopen, direnvrc"
  "40-git-setup.sh|multi-account git — INTERACTIVE (1Password key creation)"
  "45-github-profiles.sh|gh auth per account — INTERACTIVE (browser logins)"
  "48-win-folders.sh|Windows Downloads/OneDrive bridges"
  "50-shortcuts.sh|dev shortcuts + docs/notify/lab/onboard"
  "60-github-mcp.sh|per-profile GitHub-MCP tokens (claude wrapper, ghmcp)"
  "65-agent-fleet.sh|Claude sandbox + hooks · Codex config · codexr"
  "70-claude-science.sh|Claude Science install + science launcher"
)

printf '%s%sWSL2 research-environment bootstrap%s  %s\n' "$B" "$G" "$Z" \
  "${D}$([ "$DRY" -eq 1 ] && echo '(DRY RUN — children run with --dry-run)')${Z}"

RAN=0; SKIPPED=0; FAILED=0
for entry in "${STEPS[@]}"; do
  script="${entry%%|*}"; desc="${entry#*|}"
  hdr "$script — $desc"
  [ -x "./$script" ] || { warn "missing or not executable — skipped"; SKIPPED=$((SKIPPED+1)); continue; }
  if ! yesno "run $script$([ "$DRY" -eq 1 ] && echo ' --dry-run')?"; then
    echo "  ${D}skipped${Z}"; SKIPPED=$((SKIPPED+1)); continue
  fi
  if [ "$DRY" -eq 1 ]; then "./$script" --dry-run; else "./$script"; fi
  rc=$?
  if [ "$rc" -eq 0 ]; then ok "$script done"; RAN=$((RAN+1))
  else
    warn "$script exited $rc"
    FAILED=$((FAILED+1))
    yesno "continue with the remaining steps?" || { warn "bootstrap stopped — fix the step above and re-run (everything is idempotent)"; break; }
  fi
done

hdr "final health check (35-verify-setup.sh)"
if yesno "run the read-only verify now?"; then ./35-verify-setup.sh || warn "verify reported failures — see above"; fi

hdr "summary"
printf '  %s%d ran%s   %s%d skipped%s   %s%d failed%s\n' "$G" "$RAN" "$Z" "$D" "$SKIPPED" "$Z" "$R" "$FAILED" "$Z"
echo "  ${B}Finish:${Z}  exec zsh   — then try:  ${D}docs · lab · new-project.sh <name> --ml${Z}"
