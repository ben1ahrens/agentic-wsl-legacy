#!/usr/bin/env bash
#
# link-windows-folders.sh — Bridge Windows folders into WSL and add shell conveniences.
#
#   1. Symlinks your Windows Downloads folder to ~/Downloads.
#   2. Finds every OneDrive instance under your Windows profile and asks which to symlink.
#   3. Adds a ~/.zshrc block:
#        dl              cd into Downloads
#        dls [N]         list the N most-recent downloads (default 10)
#        dlcp <name>…    copy item(s) from Downloads into the current dir (tab-completes)
#        dlmv <name>…    move item(s) from Downloads into the current dir (tab-completes)
#        dlput <name>…   copy item(s) from the current dir into Downloads
#      …plus navigation shortcuts for ~/projects and each of its subdirectories
#      (projects, work, personal, … → cd there). Skip these with --no-projects-shortcuts.
#
# Safe: never clobbers a real file/dir; backs up ~/.zshrc; the managed block is idempotent.
#
# Usage:
#   ./link-windows-folders.sh                       # detect + interactive
#   ./link-windows-folders.sh --no-projects-shortcuts
#   ./link-windows-folders.sh --projects-root ~/code
#   ./link-windows-folders.sh --winhome /mnt/c/Users/you   # override autodetection
#   ./link-windows-folders.sh --dry-run             # preview; no symlinks, no file changes
#
set -uo pipefail

WINHOME=""; PROJ_ROOT="$HOME/projects"; DO_PROJ=1; DRY=0
while [ $# -gt 0 ]; do case "$1" in
  --winhome) WINHOME="${2:-}"; shift 2 ;;
  --projects-root) PROJ_ROOT="${2:-}"; shift 2 ;;
  --no-projects-shortcuts) DO_PROJ=0; shift ;;
  --dry-run|-n) DRY=1; shift ;;
  -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
  *) echo "Unknown option: $1" >&2; exit 2 ;;
esac; done
PROJ_ROOT="${PROJ_ROOT/#\~/$HOME}"; PROJ_ROOT="${PROJ_ROOT%/}"

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; C=$'\033[36m'; Z=$'\033[0m'
else B=""; G=""; Y=""; R=""; D=""; C=""; Z=""; fi
hdr(){ printf '\n%s== %s ==%s\n' "$B" "$1" "$Z"; }
ok(){ printf '  %s✓%s %s\n' "$G" "$Z" "$1"; }
warn(){ printf '  %s!%s %s\n' "$Y" "$Z" "$1"; }
info(){ printf '  %s·%s %s\n' "$D" "$Z" "$1"; }
backup_file(){  # copy $1 into ~/.local/state/wsl2-dev/backups (newest 5 kept); honours --dry-run
  local src="$1" base dir f i=0; [ -f "$src" ] || return 0
  base="$(basename "$src")"; dir="${XDG_STATE_HOME:-$HOME/.local/state}/wsl2-dev/backups"
  if [ "${DRY:-0}" -eq 1 ]; then printf '  %s· would back up %s%s\n' "${D:-}" "${src/#$HOME/\~}" "${Z:-}"; return 0; fi
  mkdir -p "$dir" && cp -p "$src" "$dir/${base}.$(date +%Y%m%d-%H%M%S).bak" \
    && printf '  %s✓%s backed up %s → %s/\n' "${G:-}" "${Z:-}" "${src/#$HOME/\~}" "${dir/#$HOME/\~}"
  while IFS= read -r f; do i=$((i+1)); [ "$i" -gt 5 ] && rm -f "$f"; done < <(printf '%s\n' "$dir/${base}".*.bak | sort -r)
}
die(){ printf '  %s✗%s %s\n' "$R" "$Z" "$1"; exit 1; }
ask(){ local __v="$1" __p="$2" __d="${3:-}" __i; if [ -n "$__d" ]; then read -r -p "  $__p [$__d]: " __i; else read -r -p "  $__p: " __i; fi; printf -v "$__v" '%s' "${__i:-$__d}"; }
yesno(){ local __p="$1" __d="${2:-y}" __i __h; case "$__d" in y|Y) __h="[Y/n]";; *) __h="[y/N]";; esac; read -r -p "  $__p $__h: " __i; __i="${__i:-$__d}"; case "$__i" in y|Y|yes|YES) return 0;; *) return 1;; esac; }
tilde(){ printf '%s' "${1/#$HOME/\~}"; }

MS="# >>> win-shortcuts (managed by link-windows-folders.sh) >>>"
ME="# <<< win-shortcuts (managed by link-windows-folders.sh) <<<"

printf '%s%sWindows folder bridges + shell shortcuts%s  %s\n' "$B" "$G" "$Z" "${D}$([ "$DRY" -eq 1 ] && echo '(DRY RUN)')${Z}"

# ---------- locate the Windows user profile ----------
hdr "Windows profile"
if [ -z "$WINHOME" ]; then
  if [ -d /mnt/c ] && command -v cmd.exe >/dev/null 2>&1; then
    WINHOME="$( (cd /mnt/c && cmd.exe /c "echo %USERPROFILE%" 2>/dev/null) | tr -d '\r' )"
    command -v wslpath >/dev/null 2>&1 && [ -n "$WINHOME" ] && WINHOME="$(wslpath "$WINHOME" 2>/dev/null)"
  fi
fi
[ -n "$WINHOME" ] && [ -d "$WINHOME" ] || ask WINHOME "Path to your Windows profile (e.g. /mnt/c/Users/you)" ""
[ -d "$WINHOME" ] || die "Windows profile not found: '$WINHOME'"
WINHOME="${WINHOME%/}"
ok "using $WINHOME"

make_link(){ # make_link TARGET LINK LABEL
  local target="$1" link="$2" label="$3"
  [ -e "$target" ] || { warn "$label source missing: $target — skipping"; return 1; }
  if [ "$DRY" -eq 1 ]; then info "would link $(tilde "$link") → $target"; return 0; fi
  if [ -L "$link" ]; then
    [ "$(readlink "$link")" = "$target" ] && { ok "$label already linked: $(tilde "$link")"; return 0; }
    warn "$(tilde "$link") points elsewhere — replacing"; rm -f "$link"
  elif [ -e "$link" ]; then
    warn "$(tilde "$link") exists as a real file/dir — leaving untouched (skipping $label)"; return 1
  fi
  ln -s "$target" "$link" && ok "$label linked: $(tilde "$link") → $target"
}

# ---------- Downloads ----------
hdr "Downloads"
DL_SRC="$WINHOME/Downloads"
if [ ! -d "$DL_SRC" ]; then
  warn "no Downloads at $DL_SRC (it may be redirected)."
  ask DL_SRC "Path to your Windows Downloads folder" "$DL_SRC"
  DL_SRC="${DL_SRC/#\~/$HOME}"
fi
make_link "$DL_SRC" "$HOME/Downloads" "Downloads"
DL_FOR_ZSHRC="$DL_SRC"   # bake the real path into the helpers so they work regardless of the symlink

# ---------- OneDrive(s) ----------
hdr "OneDrive"
mapfile -t ONEDRIVES < <(find "$WINHOME" -maxdepth 1 -type d -name 'OneDrive*' 2>/dev/null | sort)
if [ "${#ONEDRIVES[@]}" -eq 0 ]; then
  info "no OneDrive folders found under $WINHOME"
else
  ok "found ${#ONEDRIVES[@]} OneDrive folder(s)"
  for od in "${ONEDRIVES[@]}"; do
    base="$(basename "$od")"
    if yesno "Link '$base'?" "y"; then
      defname="${base// /-}"
      ask linkname "  symlink name under ~/" "$defname"
      make_link "$od" "$HOME/$linkname" "$base"
    else
      info "skipped $base"
    fi
  done
fi

# ---------- projects shortcuts ----------
declare -a SUBS
if [ "$DO_PROJ" -eq 1 ]; then
  hdr "projects navigation shortcuts"
  if [ ! -d "$PROJ_ROOT" ]; then
    warn "$PROJ_ROOT doesn't exist."
    if yesno "Create it?" "y" && [ "$DRY" -eq 0 ]; then mkdir -p "$PROJ_ROOT" && ok "created $(tilde "$PROJ_ROOT")"; fi
  fi
  # eligible subdirs = simple names only (valid as alias/command names)
  mapfile -t ALLSUBS < <(find "$PROJ_ROOT" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
  for s in "${ALLSUBS[@]}"; do
    if [[ "$s" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then SUBS+=("$s"); else warn "skipping '$s' (not a valid shortcut name)"; fi
  done
  if [ "${#SUBS[@]}" -eq 0 ]; then
    info "no subdirectories to make shortcuts for yet (just 'projects' will be added)"
  else
    info "subdirectories: ${SUBS[*]}"
    if ! yesno "Create a shortcut for all of these?" "y"; then
      local_keep=()
      for s in "${SUBS[@]}"; do yesno "  shortcut '$s'?" "y" && local_keep+=("$s"); done
      SUBS=("${local_keep[@]}")
    fi
  fi
  # collision check
  COLL=""
  for nm in projects dl dls dlcp dlmv dlput "${SUBS[@]}"; do command -v "$nm" >/dev/null 2>&1 && COLL+=" $nm"; done
  [ -n "$COLL" ] && warn "these names already resolve to a command and will be shadowed:$COLL"
fi

# ---------- build the ~/.zshrc block ----------
hdr "~/.zshrc block"
read -r -d '' HELPERS <<'EOF' || true
# --- Windows Downloads helpers ---
alias dl='cd "$WIN_DOWNLOADS"'
dls() {  # list the N most-recent downloads (default 10)
  local n="${1:-10}"
  command ls -lht --time-style=long-iso "$WIN_DOWNLOADS" 2>/dev/null | command grep -v '^total ' | command head -n "$n"
}
dlcp() {  # copy item(s) from Downloads into the current directory
  (( $# )) || { print "usage: dlcp <name>...   (copy from Downloads into .)"; return 1; }
  local f; for f in "$@"; do command cp -rv "$WIN_DOWNLOADS/$f" . || return 1; done
}
dlmv() {  # move item(s) from Downloads into the current directory
  (( $# )) || { print "usage: dlmv <name>...   (move from Downloads into .)"; return 1; }
  local f; for f in "$@"; do command mv -v "$WIN_DOWNLOADS/$f" . || return 1; done
}
dlput() {  # copy item(s) from the current directory into Downloads
  (( $# )) || { print "usage: dlput <name>...   (copy from . into Downloads)"; return 1; }
  command cp -rv "$@" "$WIN_DOWNLOADS/"
}
(( $+functions[compdef] )) && { _dl_from_downloads() { _files -W "$WIN_DOWNLOADS" }; compdef _dl_from_downloads dlcp dlmv 2>/dev/null }
EOF

BLOCK="$MS"$'\n'"export WIN_DOWNLOADS=\"$DL_FOR_ZSHRC\""$'\n'"$HELPERS"$'\n'
if [ "$DO_PROJ" -eq 1 ]; then
  BLOCK+=$'\n'"# --- projects navigation ---"$'\n'"alias projects='cd \"$PROJ_ROOT\"'"$'\n'
  for s in "${SUBS[@]}"; do BLOCK+="alias ${s}='cd \"$PROJ_ROOT/${s}\"'"$'\n'; done
fi
BLOCK+="$ME"

if [ "$DRY" -eq 1 ]; then
  printf '\n%s--- would write this block into ~/.zshrc ---%s\n%s\n' "$D" "$Z" "$BLOCK"
else
  ZRC="$HOME/.zshrc"
  backup_file "$ZRC"
  tmp="$(mktemp)"
  if [ -f "$ZRC" ] && grep -qF "$MS" "$ZRC"; then
    awk -v s="$MS" -v e="$ME" 'index($0,s){k=1} !k{print} index($0,e){k=0}' "$ZRC" > "$tmp"
  elif [ -f "$ZRC" ]; then cp "$ZRC" "$tmp"; fi
  printf '\n%s\n' "$BLOCK" >> "$tmp"; mv "$tmp" "$ZRC"
  ok "wrote managed block (dl, dls, dlcp, dlmv, dlput$([ "$DO_PROJ" -eq 1 ] && echo ', projects nav'))"
fi

# ---------- summary ----------
hdr "summary"
[ "$DRY" -eq 1 ] && { printf '\n%sDry run complete.%s Re-run without --dry-run to apply.\n' "$G$B" "$Z"; exit 0; }
echo "  ${B}1.${Z} Reload your shell:  ${D}exec zsh${Z}"
echo "  ${B}2.${Z} Try it:  ${D}dls${Z} (recent downloads) · ${D}dlcp <file>${Z} (grab one into the current dir, Tab to complete)"
[ "$DO_PROJ" -eq 1 ] && echo "  ${B}3.${Z} Navigate:  ${D}projects${Z}$(for s in "${SUBS[@]}"; do printf ' · %s' "$s"; done)"
echo
info "~/Downloads and any OneDrive links point at the live Windows folders (changes sync both ways)."
[ "$DO_PROJ" -eq 1 ] && info "If you ran git-setup.sh, some of these projects shortcuts duplicate its block — harmless, since they're identical."
