#!/usr/bin/env bash
#
# 40-git-setup.sh — Interactive multi-account git setup for WSL2, 1Password-managed.
#
# For each profile you define, it wires up:
#   - an SSH host alias in ~/.ssh/config pinned to that account's 1Password public key
#   - directory-based identity + commit signing via ~/.gitconfig includeIf (gitdir)
#   - a projects subfolder, and a zsh shortcut that cd's into it
# Plus, once: sensible non-identity git defaults and the 1Password SSH-agent bridge
# (SSH_AUTH_SOCK via socat + npiperelay) so the agent reaches Claude Code's subshells.
#
# Private keys are created by YOU in the 1Password app (biometric, never on disk);
# the script guides each creation and pulls only the PUBLIC key via `op`.
#
# Safe: backs up ~/.ssh/config, ~/.gitconfig, ~/.zshrc before editing; all additions
# live in idempotent marked blocks; re-running replaces them rather than duplicating.
#
# Usage:
#   ./40-git-setup.sh             # interactive setup
#   ./40-git-setup.sh --dry-run   # ask everything, but write nothing (preview)
#
set -uo pipefail

DRY=0
for a in "$@"; do case "$a" in
  --dry-run|-n) DRY=1 ;;
  -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
  *) echo "Unknown option: $a" >&2; exit 2 ;;
esac; done

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; C=$'\033[36m'; Z=$'\033[0m'
else B=""; G=""; Y=""; R=""; D=""; C=""; Z=""; fi
hdr(){ printf '\n%s== %s ==%s\n' "$B" "$1" "$Z"; }
ok(){ printf '  %s✓%s %s\n' "$G" "$Z" "$1"; }
warn(){ printf '  %s!%s %s\n' "$Y" "$Z" "$1"; }
info(){ printf '  %s·%s %s\n' "$D" "$Z" "$1"; }
q(){ printf '%s?%s %s\n' "$C" "$Z" "$1"; }

ask(){ # ask VAR "prompt" "default"
  local __v="$1" __p="$2" __d="${3:-}" __i
  if [ -n "$__d" ]; then read -r -p "  $__p [$__d]: " __i; else read -r -p "  $__p: " __i; fi
  printf -v "$__v" '%s' "${__i:-$__d}"
}
yesno(){ # yesno "prompt" "default y/n"
  local __p="$1" __d="${2:-y}" __i __h; case "$__d" in y|Y) __h="[Y/n]";; *) __h="[y/N]";; esac
  read -r -p "  $__p $__h: " __i; __i="${__i:-$__d}"; case "$__i" in y|Y|yes|YES) return 0;; *) return 1;; esac
}
pause(){ read -r -p "  $1" _; }
backup_file(){  # copy $1 into ~/.local/state/wsl2-dev/backups (newest 5 kept); honours --dry-run
  local src="$1" base dir f i=0; [ -f "$src" ] || return 0
  base="$(basename "$src")"; dir="${XDG_STATE_HOME:-$HOME/.local/state}/wsl2-dev/backups"
  if [ "${DRY:-0}" -eq 1 ]; then printf '  %s· would back up %s%s\n' "${D:-}" "${src/#$HOME/\~}" "${Z:-}"; return 0; fi
  mkdir -p "$dir" && cp -p "$src" "$dir/${base}.$(date +%Y%m%d-%H%M%S).bak" \
    && printf '  %s✓%s backed up %s → %s/\n' "${G:-}" "${Z:-}" "${src/#$HOME/\~}" "${dir/#$HOME/\~}"
  while IFS= read -r f; do i=$((i+1)); [ "$i" -gt 5 ] && rm -f "$f"; done < <(printf '%s\n' "$dir/${base}".*.bak | sort -r)
}

BLOCK_NAME="git-profiles"
MS="# >>> ${BLOCK_NAME} (managed by 40-git-setup.sh) >>>"
ME="# <<< ${BLOCK_NAME} (managed by 40-git-setup.sh) <<<"
# Strip is keyed on the block NAME (prefix match): blocks written under an older
# script name are still replaced, and a missing end marker can't eat the blocks
# that follow — stripping stops at the next '# >>> ' opener or EOF.
strip_block(){ # file → stdout minus the named block
  awk -v sp="# >>> ${BLOCK_NAME} " -v ep="# <<< ${BLOCK_NAME} " '
    k && index($0,ep)==1       {k=0; next}
    k && index($0,"# >>> ")==1 {k=0; print; next}
    k                          {next}
    index($0,sp)==1            {k=1; next}
    {print}' "$1"
}
insert_block(){ # file, block-content
  local file="$1" block="$2" tmp
  if [ "$DRY" -eq 1 ]; then printf '\n%s--- would write managed block into %s ---%s\n%s\n' "$D" "$file" "$Z" "$block"; return; fi
  backup_file "$file"; mkdir -p "$(dirname "$file")"; tmp="$(mktemp)"
  if [ -f "$file" ] && grep -q "^# >>> ${BLOCK_NAME} " "$file"; then
    grep -q "^# <<< ${BLOCK_NAME} " "$file" || warn "existing ${BLOCK_NAME} block had no end marker — repairing"
    strip_block "$file" > "$tmp"
  elif [ -f "$file" ]; then cp "$file" "$tmp"; fi
  printf '\n%s\n' "$block" >> "$tmp"; mv "$tmp" "$file"
}
write_file(){ # path, content, mode
  local path="$1" content="$2" mode="${3:-644}"
  if [ "$DRY" -eq 1 ]; then printf '\n%s--- would write %s ---%s\n%s\n' "$D" "$path" "$Z" "$content"; return; fi
  mkdir -p "$(dirname "$path")"; printf '%s\n' "$content" > "$path"; chmod "$mode" "$path"
}

printf '%s%sInteractive git setup (1Password-managed, multi-account)%s  %s\n' "$B" "$G" "$Z" \
  "${D}$([ "$DRY" -eq 1 ] && echo '(DRY RUN — writes nothing)' || echo '')${Z}"

# ---------- prerequisites ----------
hdr "prerequisites"
for t in git ssh zsh awk; do command -v "$t" >/dev/null 2>&1 && ok "$t" || { warn "$t missing"; }; done
command -v socat >/dev/null 2>&1 && ok "socat (for the agent bridge)" || warn "socat missing — run 10-wsl-base.sh (bridge won't work without it)"
HAVE_OP=0; command -v op.exe >/dev/null 2>&1 && { HAVE_OP=1; ok "op.exe reachable (public keys auto-fetched)"; } || warn "op.exe not reachable — you'll paste public keys manually"
HAVE_NPIPE=0; command -v npiperelay.exe >/dev/null 2>&1 && { HAVE_NPIPE=1; ok "npiperelay.exe present"; } || warn "npiperelay.exe not found — install it on Windows for the agent bridge (added to checklist)"

# ---------- GitHub CLI (gh) ----------
hdr "GitHub CLI (gh)"
BREW=""
for c in "$(command -v brew 2>/dev/null || true)" /home/linuxbrew/.linuxbrew/bin/brew "$HOME/.linuxbrew/bin/brew"; do
  [ -n "$c" ] && [ -x "$c" ] && { BREW="$c"; break; }
done
GHBIN=""; [ -n "$BREW" ] && GHBIN="$("$BREW" --prefix 2>/dev/null)/bin/gh"
if command -v gh >/dev/null 2>&1 || { [ -n "$GHBIN" ] && [ -x "$GHBIN" ]; }; then
  GHVER="$( { command -v gh >/dev/null 2>&1 && gh --version || "$GHBIN" --version; } 2>/dev/null | head -1)"
  ok "gh already installed  ${D}$GHVER${Z}"
elif [ -z "$BREW" ]; then
  warn "gh not installed and Homebrew not found — install later: brew install gh"
elif [ "$DRY" -eq 1 ]; then
  info "would install gh via: $BREW install gh"
elif yesno "gh (GitHub CLI) isn't installed. Install it now via Homebrew?" "y"; then
  info "installing gh — this can take a minute…"
  if "$BREW" install gh >/dev/null 2>&1; then ok "gh installed  ${D}$("$GHBIN" --version 2>/dev/null | head -1)${Z}  (on PATH after 'exec zsh')"
  else warn "brew install gh failed — run it manually: brew install gh"; fi
else
  info "skipped — install later with: brew install gh"
fi

# ---------- profiles ----------
hdr "profiles"
ask NPROF "How many git profiles do you want?" "2"
[[ "$NPROF" =~ ^[1-9][0-9]*$ ]] || { echo "  Not a number; defaulting to 2"; NPROF=2; }
declare -a LBL NAME EMAIL GHUSER SUB VAULT ITEM
for ((i=1;i<=NPROF;i++)); do
  q "Profile $i of $NPROF"
  ask "LBL[$i]"    "  label (short, lowercase, e.g. work / personal)" ""
  while [ -z "${LBL[i]}" ]; do ask "LBL[$i]" "  label is required" ""; done
  ask "NAME[$i]"   "  display name for commits (e.g. Jane Doe)" ""
  ask "EMAIL[$i]"  "  commit email (use your @users.noreply.github.com for privacy)" ""
  ask "GHUSER[$i]" "  GitHub username" ""
done

# ---------- projects root ----------
hdr "projects folder"
DEFROOT="$HOME/projects"
if [ -d "$DEFROOT" ]; then
  if yesno "Found $DEFROOT — use it as your projects root?" "y"; then ROOT="$DEFROOT"; else ask ROOT "Path to your projects root" "$DEFROOT"; fi
else
  ask ROOT "No ~/projects found. Path to create" "$DEFROOT"
fi
ROOT="${ROOT/#\~/$HOME}"
if [ -d "$ROOT" ]; then ok "using $ROOT"; else
  if [ "$DRY" -eq 1 ]; then info "would create $ROOT"; else mkdir -p "$ROOT" && ok "created $ROOT"; fi
fi

# ---------- per-profile subfolders ----------
hdr "per-profile subfolders"
for ((i=1;i<=NPROF;i++)); do
  ask "SUB[$i]" "Subfolder under projects for '${LBL[i]}'" "${LBL[i]}"
  local_path="$ROOT/${SUB[i]}"
  if [ -d "$local_path" ]; then ok "${SUB[i]}/ exists"; else
    if [ "$DRY" -eq 1 ]; then info "would create $local_path"; else mkdir -p "$local_path" && ok "created ${SUB[i]}/"; fi
  fi
done

# ---------- SSH keys (1Password) ----------
hdr "SSH keys — created in the 1Password app, public keys pulled here"
info "In 1Password: Settings → Developer → 'Use the SSH agent' must be ON."
[ "$DRY" -eq 0 ] && { mkdir -p "$HOME/.ssh" 2>/dev/null; chmod 700 "$HOME/.ssh" 2>/dev/null; }
for ((i=1;i<=NPROF;i++)); do
  q "Key for '${LBL[i]}'"
  ask "VAULT[$i]" "  1Password vault" "Private"
  ask "ITEM[$i]"  "  1Password item name to create" "GitHub - ${LBL[i]}"
  pause "Create an ed25519 SSH key named '${ITEM[i]}' in 1Password now, then press Enter..."
  PK=""
  if [ "$HAVE_OP" -eq 1 ]; then
    PK="$(op.exe read "op://${VAULT[i]}/${ITEM[i]}/public key" 2>/dev/null | tr -d '\r')"
  fi
  if [ -z "$PK" ]; then
    warn "couldn't auto-fetch the public key."
    info "In 1Password, open the key → 'Copy public key', then paste it below."
    read -r -p "  Paste public key for '${LBL[i]}': " PK; PK="$(printf '%s' "$PK" | tr -d '\r')"
  fi
  if [ -z "$PK" ]; then warn "no public key for '${LBL[i]}' — skipping its key file (you can add ~/.ssh/${LBL[i]}.pub later)"; continue; fi
  write_file "$HOME/.ssh/${LBL[i]}.pub" "$PK" "644"
  ok "wrote ~/.ssh/${LBL[i]}.pub"
done

# ---------- ~/.ssh/config ----------
hdr "~/.ssh/config (host aliases)"
SSHCFG="$MS"$'\n'
for ((i=1;i<=NPROF;i++)); do
  SSHCFG+="Host github-${LBL[i]}"$'\n'
  SSHCFG+="    HostName github.com"$'\n'
  SSHCFG+="    User git"$'\n'
  SSHCFG+="    IdentityFile ~/.ssh/${LBL[i]}.pub"$'\n'
  SSHCFG+="    IdentitiesOnly yes"$'\n\n'
done
SSHCFG+="$ME"
insert_block "$HOME/.ssh/config" "$SSHCFG"
[ "$DRY" -eq 0 ] && chmod 600 "$HOME/.ssh/config" 2>/dev/null
ok "host aliases: $(for ((i=1;i<=NPROF;i++)); do printf 'github-%s ' "${LBL[i]}"; done)"

# ---------- per-profile gitconfig + signing ----------
hdr "per-profile identity + commit signing"
OPSIGN="$(ls /mnt/c/Users/*/AppData/Local/1Password/app/*/op-ssh-sign-wsl 2>/dev/null | head -1)"
if [ -z "$OPSIGN" ]; then
  warn "couldn't locate op-ssh-sign-wsl automatically."
  info "In 1Password: open any SSH key → 'Configure Commit Signing' → WSL → Copy Snippet; it contains the path."
  ask OPSIGN "Paste the op-ssh-sign-wsl program path (or leave blank to skip signing)" ""
fi
for ((i=1;i<=NPROF;i++)); do
  CFG="[user]"$'\n'
  CFG+="    name = ${NAME[i]}"$'\n'
  CFG+="    email = ${EMAIL[i]}"$'\n'
  if [ -n "$OPSIGN" ]; then
    CFG+="    signingkey = ~/.ssh/${LBL[i]}.pub"$'\n'
    CFG+="[gpg]"$'\n'"    format = ssh"$'\n'
    CFG+="[gpg \"ssh\"]"$'\n'"    program = \"$OPSIGN\""$'\n'
    CFG+="[commit]"$'\n'"    gpgsign = true"$'\n'
  fi
  CFG+="[url \"git@github-${LBL[i]}:\"]"$'\n'
  CFG+="    insteadOf = git@github.com:"$'\n'
  CFG+="    insteadOf = https://github.com/"$'\n'
  write_file "$HOME/.config/git/${LBL[i]}.gitconfig" "$CFG" "644"
  ok "~/.config/git/${LBL[i]}.gitconfig  (${NAME[i]} <${EMAIL[i]}>$([ -n "$OPSIGN" ] && echo ', signed'))"
done

# ---------- ~/.gitconfig: defaults + includeIf (gitdir) ----------
hdr "~/.gitconfig (defaults + directory-based identity)"
GC="$MS"$'\n'
GC+="[init]"$'\n'"    defaultBranch = main"$'\n'
GC+="[pull]"$'\n'"    rebase = true"$'\n'
GC+="[fetch]"$'\n'"    prune = true"$'\n'
GC+="[push]"$'\n'"    autoSetupRemote = true"$'\n'
GC+="[rerere]"$'\n'"    enabled = true"$'\n'
GC+="[diff]"$'\n'"    algorithm = histogram"$'\n'
GC+="[core]"$'\n'"    autocrlf = input"$'\n'
for ((i=1;i<=NPROF;i++)); do
  GC+="[includeIf \"gitdir:$ROOT/${SUB[i]}/\"]"$'\n'
  GC+="    path = ~/.config/git/${LBL[i]}.gitconfig"$'\n'
done
GC+="$ME"
insert_block "$HOME/.gitconfig" "$GC"
ok "global defaults set; identity switches by folder (gitdir includeIf)"

# ---------- ~/.zshrc: agent bridge + navigation shortcuts ----------
hdr "~/.zshrc (agent bridge + navigation shortcuts)"
ZB="$MS"$'\n'
ZB+="# --- 1Password SSH agent bridge (needs npiperelay.exe on Windows) ---"$'\n'
ZB+='if command -v npiperelay.exe >/dev/null 2>&1; then'$'\n'
ZB+='  export SSH_AUTH_SOCK="$HOME/.ssh/agent.sock"'$'\n'
ZB+='  if ! ss -lx 2>/dev/null | grep -q "$SSH_AUTH_SOCK"; then'$'\n'
ZB+='    rm -f "$SSH_AUTH_SOCK"'$'\n'
ZB+="    ( setsid socat UNIX-LISTEN:\"\$SSH_AUTH_SOCK\",fork EXEC:'npiperelay.exe -ei -s //./pipe/openssh-ssh-agent',nofork & ) >/dev/null 2>&1"$'\n'
ZB+='  fi'$'\n'
ZB+='fi'$'\n'
ZB+="# --- project navigation shortcuts ---"$'\n'
# 'projects' -> root
ZB+="alias projects='cd \"$ROOT\"'"$'\n'
# collision check + per-profile shortcuts
COLLISIONS=""
for nm in projects; do command -v "$nm" >/dev/null 2>&1 && COLLISIONS+=" $nm"; done
for ((i=1;i<=NPROF;i++)); do
  sc="${LBL[i]}"
  command -v "$sc" >/dev/null 2>&1 && COLLISIONS+=" $sc"
  ZB+="alias ${sc}='cd \"$ROOT/${SUB[i]}\"'"$'\n'
done
ZB+="$ME"
insert_block "$HOME/.zshrc" "$ZB"
ok "shortcuts: projects $(for ((i=1;i<=NPROF;i++)); do printf '%s ' "${LBL[i]}"; done)"
[ -n "$COLLISIONS" ] && warn "these shortcut names already resolve to a command:$COLLISIONS — they'll shadow it interactively; rename in ~/.zshrc if unwanted."

# ---------- summary + checklist ----------
hdr "summary"
ok "$NPROF profile(s) configured; folders under $ROOT; identity is directory-based."
[ "$DRY" -eq 1 ] && { printf '\n%sDry run complete.%s Re-run without --dry-run to apply.\n' "$G$B" "$Z"; exit 0; }

hdr "do these manually to finish"
n=1
echo "  ${B}$((n++)).${Z} Upload each PUBLIC key to its GitHub account (Settings → SSH and GPG keys),"
echo "     adding it as BOTH an Authentication key AND a Signing key:"
for ((i=1;i<=NPROF;i++)); do echo "       ${C}${LBL[i]}${Z} (@${GHUSER[i]:-?}):  cat ~/.ssh/${LBL[i]}.pub"; done
[ "$HAVE_NPIPE" -eq 0 ] && { echo "  ${B}$((n++)).${Z} Install npiperelay.exe on Windows (PowerShell): ${D}winget install albertony.npiperelay${Z}  (the agent bridge needs it)"; }
echo "  ${B}$((n++)).${Z} Authenticate gh per account:  ${D}gh auth login${Z}  (repeat; switch later with ${D}gh auth switch${Z})"
echo "  ${B}$((n++)).${Z} Reload your shell:  ${D}exec zsh${Z}  (loads shortcuts + starts the agent bridge)"
echo "  ${B}$((n++)).${Z} Test each profile:"
for ((i=1;i<=NPROF;i++)); do echo "       ${LBL[i]}: ${D}${LBL[i]} && ssh -T git@github-${LBL[i]}${Z}  → should greet @${GHUSER[i]:-your-${LBL[i]}-account}"; done
echo
echo "  Clone into a profile folder with its alias, e.g.:  ${D}${LBL[1]} && git clone git@github-${LBL[1]}:${GHUSER[1]:-org}/repo.git${Z}"
echo "  Identity, signing, and key are then applied automatically by folder."
