#!/usr/bin/env bash
#
# tidy-backups.sh — sweep scattered "<file>.bak.<timestamp>" config backups out of your home
# directory into one tidy, self-pruning location.
#
# Older script versions backed a file up before editing by copying it to
# "<file>.bak.<timestamp>" next to the original — which piled up in ~. Current
# scripts already back up centrally; this sweeps any legacy strays into:
#       ${XDG_STATE_HOME:-~/.local/state}/wsl2-dev/backups/
# renamed to "<file>.<timestamp>.bak", keeps only the newest N of each, and deletes the rest.
#
# Scans: ~ (top level), ~/.ssh, ~/.config/git.  Safe: only touches names matching *.bak.* —
# never your live configs. Re-runnable: run it anytime to tidy new strays.
#
# Usage:
#   ./tidy-backups.sh                 # migrate strays, keep newest 5 of each, prune older
#   ./tidy-backups.sh --keep 3        # keep newest 3 per file instead
#   ./tidy-backups.sh --purge         # just delete all strays (keep none); never moves
#   ./tidy-backups.sh --dry-run       # show what would happen; touch nothing
#
set -uo pipefail

KEEP=5; DRY=0; PURGE=0
while [ $# -gt 0 ]; do case "$1" in
  --keep) KEEP="${2:-}"; shift 2 ;;
  --keep=*) KEEP="${1#*=}"; shift ;;
  --purge) PURGE=1; shift ;;
  --dry-run|-n) DRY=1; shift ;;
  -h|--help) sed -n '2,/^set /{/^set /!p;}' "$0"; exit 0 ;;
  *) echo "Unknown option: $1" >&2; exit 2 ;;
esac; done
[[ "$KEEP" =~ ^[0-9]+$ ]] || { echo "--keep must be a number" >&2; exit 2; }

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; Z=$'\033[0m'
else B=""; G=""; Y=""; R=""; D=""; Z=""; fi
hdr(){ printf '\n%s== %s ==%s\n' "$B" "$1" "$Z"; }
ok(){ printf '  %s✓%s %s\n' "$G" "$Z" "$1"; }
warn(){ printf '  %s!%s %s\n' "$Y" "$Z" "$1"; }
info(){ printf '  %s·%s %s\n' "$D" "$Z" "$1"; }
tilde(){ printf '%s' "${1/#$HOME/\~}"; }

BACKDIR="${XDG_STATE_HOME:-$HOME/.local/state}/wsl2-dev/backups"
SCAN_DIRS=("$HOME" "$HOME/.ssh" "$HOME/.config/git")

printf '%s%sTidy backups%s  %s\n' "$B" "$G" "$Z" \
  "${D}$([ "$PURGE" -eq 1 ] && echo 'purge mode · ')keep ${KEEP}$([ "$DRY" -eq 1 ] && echo ' · DRY RUN')${Z}"

# ---------- gather strays ----------
hdr "scan"
declare -a STRAYS=()
for dir in "${SCAN_DIRS[@]}"; do
  [ -d "$dir" ] || continue
  while IFS= read -r -d '' f; do STRAYS+=("$f"); done \
    < <(find "$dir" -maxdepth 1 -type f -name '*.bak.*' -print0 2>/dev/null)
done
if [ "${#STRAYS[@]}" -eq 0 ]; then
  ok "no scattered *.bak.* files in ~, ~/.ssh, or ~/.config/git — already tidy."
  exit 0
fi
info "found ${#STRAYS[@]} stray backup file(s):"
for f in "${STRAYS[@]}"; do info "    $(tilde "$f")"; done

# ---------- move (or purge) ----------
hdr "$([ "$PURGE" -eq 1 ] && echo 'delete' || echo 'move')"
moved=0; removed=0
for f in "${STRAYS[@]}"; do
  if [ "$PURGE" -eq 1 ]; then
    if [ "$DRY" -eq 1 ]; then info "would delete $(tilde "$f")"; else rm -f "$f" && removed=$((removed+1)); fi
    continue
  fi
  bname="$(basename "$f")"
  orig="${bname%.bak.*}"          # e.g. .zshrc.bak.20260623-114412 -> .zshrc
  ts="${bname##*.bak.}"           #                                  -> 20260623-114412
  [ -n "$ts" ] && [ "$ts" != "$bname" ] || ts="$(date -r "$f" +%Y%m%d-%H%M%S 2>/dev/null || date +%Y%m%d-%H%M%S)"
  dest="$BACKDIR/${orig}.${ts}.bak"
  n=1; while [ -e "$dest" ]; do dest="$BACKDIR/${orig}.${ts}-${n}.bak"; n=$((n+1)); done
  if [ "$DRY" -eq 1 ]; then
    info "would move $(tilde "$f") → $(tilde "$dest")"
  else
    mkdir -p "$BACKDIR" && mv "$f" "$dest" && { moved=$((moved+1)); ok "$(tilde "$f")  →  $(tilde "$dest")"; }
  fi
done

# ---------- prune per original ----------
pruned=0
if [ "$PURGE" -eq 0 ] && [ "$DRY" -eq 0 ] && [ -d "$BACKDIR" ]; then
  hdr "prune (keep newest $KEEP of each)"
  declare -A seen=()
  while IFS= read -r -d '' bf; do
    bn="$(basename "$bf")"; og="${bn%.*.bak}"
    [ -n "${seen[$og]:-}" ] && continue; seen[$og]=1
    mapfile -t all < <(printf '%s\n' "$BACKDIR/${og}".*.bak | sort -r)   # newest first (timestamp in name)
    if [ "${#all[@]}" -gt "$KEEP" ]; then
      for old in "${all[@]:$KEEP}"; do rm -f "$old" && pruned=$((pruned+1)); done
      info "${og}: kept $KEEP, removed $(( ${#all[@]} - KEEP ))"
    else
      info "${og}: ${#all[@]} kept (within limit)"
    fi
  done < <(find "$BACKDIR" -maxdepth 1 -type f -name '*.bak' -print0 2>/dev/null)
fi

# ---------- summary ----------
hdr "summary"
if [ "$DRY" -eq 1 ]; then
  printf '\n%sDry run complete.%s Re-run without --dry-run to apply.\n' "$G$B" "$Z"; exit 0
fi
if [ "$PURGE" -eq 1 ]; then
  ok "deleted $removed stray backup file(s); your home directory is clean."
else
  ok "moved $moved file(s) into $(tilde "$BACKDIR")$([ "$pruned" -gt 0 ] && echo ", pruned $pruned older one(s)")"
  echo "  ${D}Browse them:  ls -t $(tilde "$BACKDIR")${Z}"
  info "current setup scripts back up straight to this location — strays only come from pre-migration runs."
fi
