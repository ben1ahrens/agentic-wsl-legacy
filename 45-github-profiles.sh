#!/usr/bin/env bash
#
# github-profiles.sh — Per-account GitHub auth + SSH key upload + directory-aware shell hook.
#
# What it does:
#   1. For each profile (detected from ~/.ssh/config, or asked), PAUSES so you can switch the
#      active github.com account in your browser, then authenticates gh for that account.
#   2. Uploads that profile's public key as BOTH an authentication key and a signing key.
#   3. Installs a zsh chpwd hook + guard rails: entering a profile's directory prints a notice,
#      switches the active gh account, and clears any stray GH_TOKEN/GITHUB_TOKEN that would
#      otherwise override gh. Adds `ghwho` to cross-check the active account against the folder.
#      (Your commit identity, signing, and push key already switch by directory via git's
#      includeIf + SSH host aliases — this covers gh, the token trap, and a visible reminder.)
#
# About PATs: a script CANNOT generate personal access tokens (GitHub has no token-creation
# API). You don't need one — '--auth web' uses gh's browser login. With '--auth pat' the script
# instead OPENS a pre-filled token page per profile so you just click Generate and paste it back.
#
# Usage:
#   ./github-profiles.sh                # browser login + uploads + install hook   (recommended)
#   ./github-profiles.sh --auth pat     # paste-a-PAT instead of browser login
#   ./github-profiles.sh --hook-only    # only (re)install the zsh directory hook
#   ./github-profiles.sh --dry-run      # show what it would do; no gh calls, no file changes
#
set -uo pipefail

AUTH="web"; HOOK_ONLY=0; DRY=0
while [ $# -gt 0 ]; do case "$1" in
  --auth) AUTH="${2:-}"; shift 2 ;;
  --auth=*) AUTH="${1#*=}"; shift ;;
  --hook-only) HOOK_ONLY=1; shift ;;
  --dry-run|-n) DRY=1; shift ;;
  -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
  *) echo "Unknown option: $1" >&2; exit 2 ;;
esac; done
[ "$AUTH" = web ] || [ "$AUTH" = pat ] || { echo "--auth must be 'web' or 'pat'" >&2; exit 2; }

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; C=$'\033[36m'; Z=$'\033[0m'
else B=""; G=""; Y=""; R=""; D=""; C=""; Z=""; fi
hdr(){ printf '\n%s== %s ==%s\n' "$B" "$1" "$Z"; }
ok(){ printf '  %s✓%s %s\n' "$G" "$Z" "$1"; }
warn(){ printf '  %s!%s %s\n' "$Y" "$Z" "$1"; }
info(){ printf '  %s·%s %s\n' "$D" "$Z" "$1"; }
q(){ printf '%s?%s %s\n' "$C" "$Z" "$1"; }
ask(){ local __v="$1" __p="$2" __d="${3:-}" __i; if [ -n "$__d" ]; then read -r -p "  $__p [$__d]: " __i; else read -r -p "  $__p: " __i; fi; printf -v "$__v" '%s' "${__i:-$__d}"; }
yesno(){ local __p="$1" __d="${2:-y}" __i __h; case "$__d" in y|Y) __h="[Y/n]";; *) __h="[y/N]";; esac; read -r -p "  $__p $__h: " __i; __i="${__i:-$__d}"; case "$__i" in y|Y|yes|YES) return 0;; *) return 1;; esac; }
pause(){ read -r -p "  $1" _; }
browser_open(){ if command -v wopen >/dev/null 2>&1; then wopen "$1" >/dev/null 2>&1; elif command -v explorer.exe >/dev/null 2>&1; then explorer.exe "$1" >/dev/null 2>&1; else info "open this URL: $1"; fi; }

MS="# >>> gh-profiles (managed by github-profiles.sh) >>>"
ME="# <<< gh-profiles (managed by github-profiles.sh) <<<"

printf '%s%sGitHub profiles — auth, key upload & directory hook%s  %s\n' "$B" "$G" "$Z" \
  "${D}$([ "$DRY" -eq 1 ] && echo '(DRY RUN)')${Z}"

# ---------- gh presence ----------
HAVE_GH=0; command -v gh >/dev/null 2>&1 && HAVE_GH=1
if [ "$HOOK_ONLY" -eq 0 ] && [ "$HAVE_GH" -eq 0 ] && [ "$DRY" -eq 0 ]; then
  warn "gh (GitHub CLI) not found — install it first (e.g. 'brew install gh' or re-run git-setup.sh), then run this again."
  info "Continuing would only let me install the shell hook; re-run with --hook-only if that's all you want."
  exit 1
fi

# ---------- collect profiles ----------
hdr "profiles"
declare -a LBL USR DIR PUB
SSHCFG="$HOME/.ssh/config"
mapfile -t DETECTED < <(grep -oP '^\s*Host\s+github-\K\S+' "$SSHCFG" 2>/dev/null | awk '!seen[$0]++')
if [ "${#DETECTED[@]}" -gt 0 ]; then
  ok "detected from ~/.ssh/config: ${DETECTED[*]}"
  for lbl in "${DETECTED[@]}"; do
    q "Profile '${lbl}'"
    pub="$HOME/.ssh/${lbl}.pub"
    [ -f "$pub" ] && ok "key: ~/.ssh/${lbl}.pub" || warn "expected ~/.ssh/${lbl}.pub not found — upload will be skipped for this one"
    # derive the directory from the gitconfig includeIf, fall back to ~/projects/<lbl>
    ddir="$(grep -B1 "/.config/git/${lbl}\.gitconfig" "$HOME/.gitconfig" 2>/dev/null | grep -oP 'gitdir:\K[^"]+' | head -1)"
    ddir="${ddir%/}"; [ -z "$ddir" ] && ddir="$HOME/projects/${lbl}"
    local_user=""
    while [ -z "$local_user" ]; do ask local_user "  GitHub username for '${lbl}'" ""; done
    ask ddir "  directory that maps to '${lbl}'" "$ddir"
    ddir="${ddir/#\~/$HOME}"; ddir="${ddir%/}"
    LBL+=("$lbl"); USR+=("$local_user"); DIR+=("$ddir"); PUB+=("$pub")
  done
else
  warn "no 'Host github-*' entries in ~/.ssh/config — enter profiles manually."
  ask NPROF "How many profiles?" "1"; [[ "$NPROF" =~ ^[1-9][0-9]*$ ]] || NPROF=1
  for ((i=1;i<=NPROF;i++)); do
    q "Profile $i of $NPROF"
    lbl=""; while [ -z "$lbl" ]; do ask lbl "  label (e.g. work)" ""; done
    local_user=""; while [ -z "$local_user" ]; do ask local_user "  GitHub username" ""; done
    ask ddir "  directory that maps to '${lbl}'" "$HOME/projects/${lbl}"
    ddir="${ddir/#\~/$HOME}"; ddir="${ddir%/}"
    LBL+=("$lbl"); USR+=("$local_user"); DIR+=("$ddir"); PUB+=("$HOME/.ssh/${lbl}.pub")
  done
fi
N="${#LBL[@]}"
[ "$N" -gt 0 ] || { warn "no profiles to process."; exit 1; }

# ---------- auth + upload ----------
if [ "$HOOK_ONLY" -eq 0 ]; then
  hdr "authenticate & upload keys ($AUTH)"
  info "For each profile you'll switch the github.com account in your browser, then gh authenticates it."
  SCOPES="admin:public_key,admin:ssh_signing_key"
  PAT_SCOPES="repo,read:org,${SCOPES}"
  for ((i=0;i<N;i++)); do
    lbl="${LBL[i]}"; user="${USR[i]}"; pub="${PUB[i]}"
    q "Profile '${lbl}' (@${user})"
    pause "→ Sign in to github.com as @${user} in your browser. Press Enter when ready…"
    if [ "$DRY" -eq 1 ]; then
      if [ "$AUTH" = web ]; then info "would run: gh auth login --hostname github.com --git-protocol https --web --scopes \"$SCOPES\""
      else info "would open: https://github.com/settings/tokens/new?scopes=${PAT_SCOPES}&description=WSL-${lbl}  then: gh auth login --with-token"; fi
      info "would run: gh auth switch --user ${user}"
      info "would run: gh ssh-key add ${pub/#$HOME/\~} -t '${lbl} (WSL)' --type authentication"
      info "would run: gh ssh-key add ${pub/#$HOME/\~} -t '${lbl} signing' --type signing"
      continue
    fi
    # --- authenticate ---
    if [ "$AUTH" = web ]; then
      gh auth login --hostname github.com --git-protocol https --web --scopes "$SCOPES" || { warn "gh auth login failed for ${lbl} — skipping"; continue; }
    else
      url="https://github.com/settings/tokens/new?scopes=${PAT_SCOPES}&description=WSL-${lbl}"
      info "opening a pre-filled token page (scopes already selected)…"; browser_open "$url"
      info "Click 'Generate token' at the bottom, copy it, then paste below."
      TOKEN=""; read -rs -p "  Paste token for @${user} (hidden): " TOKEN; echo
      [ -n "$TOKEN" ] || { warn "no token entered for ${lbl} — skipping"; continue; }
      printf '%s' "$TOKEN" | gh auth login --hostname github.com --git-protocol https --with-token || { warn "token login failed for ${lbl} — skipping"; unset TOKEN; continue; }
      unset TOKEN
    fi
    # --- make sure this account is active ---
    gh auth switch --user "$user" >/dev/null 2>&1 || true
    # --- upload key as both types ---
    if [ ! -f "$pub" ]; then warn "no $pub — skipping key upload for ${lbl}"; continue; fi
    gh ssh-key add "$pub" -t "${lbl} (WSL)" --type authentication && ok "uploaded ${lbl} authentication key" || warn "auth-key upload failed for ${lbl}"
    if gh ssh-key add "$pub" -t "${lbl} signing" --type signing; then ok "uploaded ${lbl} signing key"
    else warn "signing-key upload failed for ${lbl} — likely a scope issue. Fix: gh auth switch --user ${user} && gh auth refresh -h github.com -s admin:ssh_signing_key, then retry"; fi
  done
fi

# ---------- install the zsh directory hook ----------
hdr "zsh directory hook"
CASE_ARMS=""
for ((i=0;i<N;i++)); do CASE_ARMS+="    \"${DIR[i]}/\"*) _GHP_LABEL='${LBL[i]}'; _GHP_USER='${USR[i]}' ;;"$'\n'; done
CASE_ARMS="${CASE_ARMS%$'\n'}"
read -r -d '' HOOKBODY <<'EOF' || true
# Directory-aware GitHub: keep gh's active account in step with the folder, and make sure a
# stray token can never override it. Your git commit identity, signing key, and SSH push key
# already switch by directory (git includeIf + SSH host aliases); this adds gh + visibility.
#
# Guard rails:
#   - gh resolves auth as GH_TOKEN > GITHUB_TOKEN > stored account, so a token in the
#     environment silently wins over every per-folder switch. Entering a profile dir clears
#     those two vars (with a warning) so the stored, directory-correct account governs gh.
#   - The GitHub-MCP token lives in GITHUB_PERSONAL_ACCESS_TOKEN, which gh does NOT read, so it
#     is deliberately left untouched here.
#   - `ghwho` is an on-demand cross-check: it runs `gh auth status` and tells you whether the
#     active account matches the folder you're standing in. Run it before anything irreversible.
_ghprofile_for_pwd() {   # sets _GHP_LABEL / _GHP_USER for $PWD ('' when outside every profile)
  _GHP_LABEL=''; _GHP_USER=''
  case "$PWD/" in
__CASE_ARMS__
  esac
}
_ghprofile_chpwd() {
  _ghprofile_for_pwd
  [ -z "$_GHP_LABEL" ] && { _GHPROFILE_CURRENT=''; return; }
  # Guard rail: clear stray tokens on every entry into a profile dir (before the change short-circuit).
  if [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
    unset GH_TOKEN GITHUB_TOKEN
    print -P "%F{yellow}!%f cleared a stray GH_TOKEN/GITHUB_TOKEN (it overrides gh's per-folder account)"
  fi
  [ "$_GHP_LABEL" = "$_GHPROFILE_CURRENT" ] && return     # same profile as last time: notice/switch already done
  _GHPROFILE_CURRENT="$_GHP_LABEL"
  print -P "%F{cyan}●%f git profile: %B${_GHP_LABEL}%b (@${_GHP_USER}) — commits, signing & pushes use this account"
  if command -v gh >/dev/null 2>&1; then
    gh auth switch --user "$_GHP_USER" >/dev/null 2>&1 \
      || print -P "%F{yellow}!%f gh isn't signed in as @${_GHP_USER} yet — run: gh auth login   (then: ghwho)"
  fi
}
ghwho() {   # cross-check: is gh actually acting as the account this folder expects?
  emulate -L zsh
  _ghprofile_for_pwd
  if [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
    print -P "%F{red}x%f GH_TOKEN/GITHUB_TOKEN is set in this shell — gh uses that token and IGNORES the stored account below."
    print -P "  clear it with:  unset GH_TOKEN GITHUB_TOKEN"
  fi
  if command -v gh >/dev/null 2>&1; then gh auth status; else print "gh not installed"; fi
  if [ -n "$_GHP_USER" ]; then print -P "Expected for this folder: %B${_GHP_LABEL}%b (@${_GHP_USER})"
  else print "This folder isn't inside a known profile directory."; fi
}
(( ${chpwd_functions[(I)_ghprofile_chpwd]} )) || chpwd_functions+=(_ghprofile_chpwd)
EOF
HOOKBODY="${HOOKBODY/__CASE_ARMS__/$CASE_ARMS}"
BLOCK="$MS"$'\n'"$HOOKBODY"$'\n'"$ME"

if [ "$DRY" -eq 1 ]; then
  printf '\n%s--- would write this managed block into ~/.zshrc ---%s\n%s\n' "$D" "$Z" "$BLOCK"
else
  ZRC="$HOME/.zshrc"
  [ -f "$ZRC" ] && cp "$ZRC" "$ZRC.bak.$(date +%Y%m%d-%H%M%S)" && info "backed up ~/.zshrc"
  tmp="$(mktemp)"
  if [ -f "$ZRC" ] && grep -qF "$MS" "$ZRC"; then
    awk -v s="$MS" -v e="$ME" 'index($0,s){k=1} !k{print} index($0,e){k=0}' "$ZRC" > "$tmp"
  elif [ -f "$ZRC" ]; then cp "$ZRC" "$tmp"; fi
  printf '\n%s\n' "$BLOCK" >> "$tmp"; mv "$tmp" "$ZRC"
  ok "installed chpwd hook for: $(for ((i=0;i<N;i++)); do printf '%s ' "${LBL[i]}"; done)"
fi

# ---------- summary ----------
hdr "summary"
[ "$DRY" -eq 1 ] && { printf '\n%sDry run complete.%s Re-run without --dry-run to apply.\n' "$G$B" "$Z"; exit 0; }
echo "  ${B}1.${Z} Reload your shell:  ${D}exec zsh${Z}  (activates the directory hook)"
echo "  ${B}2.${Z} Navigate in and watch the notice:"
for ((i=0;i<N;i++)); do echo "       ${D}cd '${DIR[i]}'${Z}  → ● git profile: ${LBL[i]} (@${USR[i]})"; done
[ "$HOOK_ONLY" -eq 0 ] && {
  echo "  ${B}3.${Z} Confirm the keys landed (per account):  ${D}gh auth switch --user <name> && gh ssh-key list${Z}"
  echo "  ${B}4.${Z} Test SSH auth still greets the right account:"
  for ((i=0;i<N;i++)); do echo "       ${D}ssh -T git@github-${LBL[i]}${Z}  → Hi @${USR[i]}"; done
}
echo
info "Cross-check anytime with ${B}ghwho${Z}${D} — it runs 'gh auth status' and tells you whether the active"
info "account matches the folder you're in (and warns loudly if a stray token is overriding gh)."
info "Guard rail: entering a profile dir clears any GH_TOKEN/GITHUB_TOKEN so the directory account always wins."
info "Your GitHub-MCP token (GITHUB_PERSONAL_ACCESS_TOKEN) is a different var gh ignores — it's left untouched."
echo
info "Note: gh has ONE active account globally, so the hook makes it follow your most-recent cd."
info "Multiple terminals in different profiles will share that active account (git push/commit are unaffected — those switch by directory)."
