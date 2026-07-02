#!/usr/bin/env bash
#
# 60-github-mcp.sh — Make the GitHub MCP plugin work, securely, with multi-account git.
#
# The 'github' MCP plugin authenticates with a header: "Authorization: Bearer
# ${GITHUB_PERSONAL_ACCESS_TOKEN}". Claude expands that from its OWN process env at
# launch — so the token must be present when you start Claude, and it stays fixed for
# the whole session. This script installs a managed '# >>> github-mcp >>>' block in
# ~/.zshrc that:
#   • wraps `claude` to read the RIGHT account's PAT from 1Password at launch (based on
#     which ~/projects/<profile> you're in) and pass it to that one process only; and
#   • adds `ghmcp`, an on-demand health check that proves each token still works —
#     which account it authenticates as, its expiry date, and whether it matches the
#     profile (catches expired / revoked / mislabeled tokens before they confuse you).
#
# Result: 1Password owns every token; one Windows Hello prompt per session; the token is
# never exported or written to disk; two sessions in different projects can't mix tokens.
#
# Profiles are auto-detected from ~/.ssh/config (Host github-<label>), falling back to
# work/personal/imperial. The expected GitHub login per profile is read from the
# gh-profiles block in ~/.zshrc when present (used by ghmcp's mismatch check).
#
# Runtime knobs (set in your env, no re-run needed):
#   GH_MCP_DEFAULT      profile to use when launched outside ~/projects (default: --default)
#   GH_MCP_OP_TIMEOUT   seconds to wait for the 1Password read (default: --op-timeout / 60)
#
# Properties: idempotent (re-run replaces its block), backs up ~/.zshrc, --dry-run safe.
#
# Usage:
#   ./60-github-mcp.sh --dry-run                       # preview the block + ~/.zshrc diff
#   ./60-github-mcp.sh                                 # apply (vault 'Private', field 'credential')
#   ./60-github-mcp.sh --vault "Dev" --field token     # match your 1Password vault/field
#   ./60-github-mcp.sh --default personal              # token to use outside a project dir
#   ./60-github-mcp.sh --check                         # also verify reads now (prompts Hello)
#
set -uo pipefail

# ---------- options ----------
DRY=0; CHECK=0
VAULT="Private"          # 1Password vault holding the per-account PATs
FIELD="credential"       # field name in each item ('credential' matches the opadd helper)
PREFIX="github-mcp-"     # item title prefix → <prefix>work, <prefix>personal, ...
DEFAULT_PROFILE=""       # profile used when launched outside ~/projects ('' = none)
OP_TIMEOUT="60"          # seconds to wait on the 1Password read
PROFILES_OVERRIDE=""
while [ "$#" -gt 0 ]; do case "$1" in
  --dry-run|-n)   DRY=1; shift ;;
  --check)        CHECK=1; shift ;;
  --vault)        VAULT="${2:-$VAULT}"; shift 2 ;;
  --vault=*)      VAULT="${1#*=}"; shift ;;
  --field)        FIELD="${2:-$FIELD}"; shift 2 ;;
  --field=*)      FIELD="${1#*=}"; shift ;;
  --prefix)       PREFIX="${2:-$PREFIX}"; shift 2 ;;
  --prefix=*)     PREFIX="${1#*=}"; shift ;;
  --default)      DEFAULT_PROFILE="${2:-}"; shift 2 ;;
  --default=*)    DEFAULT_PROFILE="${1#*=}"; shift ;;
  --op-timeout)   OP_TIMEOUT="${2:-$OP_TIMEOUT}"; shift 2 ;;
  --op-timeout=*) OP_TIMEOUT="${1#*=}"; shift ;;
  --profiles)     PROFILES_OVERRIDE="${2:-}"; shift 2 ;;
  --profiles=*)   PROFILES_OVERRIDE="${1#*=}"; shift ;;
  -h|--help)      sed -n '2,/^set /{/^set /!p;}' "$0"; exit 0 ;;
  *) echo "Unknown option: $1 (use --help)" >&2; exit 2 ;;
esac; done

# ---------- pretty ----------
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; Z=$'\033[0m'
else B=""; G=""; Y=""; R=""; D=""; Z=""; fi
hdr(){ printf '\n%s== %s ==%s\n' "$B" "$1" "$Z"; }
ok(){ printf '  %s✓%s %s\n' "$G" "$Z" "$1"; }
warn(){ printf '  %s!%s %s\n' "$Y" "$Z" "$1"; }
note(){ printf '  %s%s%s\n' "$D" "$1" "$Z"; }
backup_file(){  # copy $1 into ~/.local/state/wsl2-dev/backups (newest 5 kept); honours --dry-run
  local src="$1" base dir f i=0; [ -f "$src" ] || return 0
  base="$(basename "$src")"; dir="${XDG_STATE_HOME:-$HOME/.local/state}/wsl2-dev/backups"
  if [ "${DRY:-0}" -eq 1 ]; then printf '  %s· would back up %s%s\n' "${D:-}" "${src/#$HOME/\~}" "${Z:-}"; return 0; fi
  mkdir -p "$dir" && cp -p "$src" "$dir/${base}.$(date +%Y%m%d-%H%M%S).bak" \
    && printf '  %s✓%s backed up %s → %s/\n' "${G:-}" "${Z:-}" "${src/#$HOME/\~}" "${dir/#$HOME/\~}"
  while IFS= read -r f; do i=$((i+1)); [ "$i" -gt 5 ] && rm -f "$f"; done < <(printf '%s\n' "$dir/${base}".*.bak | sort -r)
}

ZSHRC="$HOME/.zshrc"
BLOCK_NAME="github-mcp"
MSTART="# >>> ${BLOCK_NAME} (managed by 60-github-mcp.sh) >>>"
MEND="# <<< ${BLOCK_NAME} (managed by 60-github-mcp.sh) <<<"
# Name-keyed strip: replaces blocks written under older script names and stops
# at the next '# >>> ' opener (or EOF) if the end marker is missing.
strip_block(){ # file → stdout minus the named block
  awk -v sp="# >>> ${BLOCK_NAME} " -v ep="# <<< ${BLOCK_NAME} " '
    k && index($0,ep)==1       {k=0; next}
    k && index($0,"# >>> ")==1 {k=0; print; next}
    k                          {next}
    index($0,sp)==1            {k=1; next}
    {print}' "$1"
}

printf '%s%sGitHub MCP — 1Password-backed token%s  %s(%s)%s\n' "$B" "$G" "$Z" "$D" \
  "$([ "$DRY" -eq 1 ] && echo 'DRY RUN — writes nothing' || echo 'live run')" "$Z"

# ---------- detect profiles ----------
PROFILES=()
if [ -n "$PROFILES_OVERRIDE" ]; then
  read -r -a PROFILES <<< "$PROFILES_OVERRIDE"
elif [ -f "$HOME/.ssh/config" ]; then
  while IFS= read -r p; do [ -n "$p" ] && PROFILES+=("$p"); done < <(
    grep -oE '^Host[[:space:]]+github-[A-Za-z0-9_-]+' "$HOME/.ssh/config" 2>/dev/null \
      | sed -E 's/^Host[[:space:]]+github-//' | sort -u)
fi
[ "${#PROFILES[@]}" -gt 0 ] || PROFILES=(work personal imperial)
note "profiles: ${PROFILES[*]}   vault: $VAULT   field: $FIELD   default: ${DEFAULT_PROFILE:-none}   op-timeout: ${OP_TIMEOUT}s"

# ---------- generate token map, dir cases, and expected-login map ----------
TOKMAP=""; CASES=""
for p in "${PROFILES[@]}"; do
  printf -v _line '  %-10s%s' "$p" "'op://$VAULT/$PREFIX$p/$FIELD'"
  TOKMAP+="$_line"$'\n'
  CASES+='    "$HOME/projects/'"$p"'/"*) print -r -- '"$p"' ;;'$'\n'
done
TOKMAP="${TOKMAP%$'\n'}"; CASES="${CASES%$'\n'}"

# Expected GitHub login per profile — parsed from the gh-profiles block if present.
EXPECTMAP=""
if [ -f "$ZSHRC" ]; then
  while IFS=' ' read -r _lbl _usr; do
    [ -n "$_lbl" ] && [ -n "$_usr" ] || continue
    printf -v _line '  %-10s%s' "$_lbl" "'$_usr'"
    EXPECTMAP+="$_line"$'\n'
  done < <(grep -oE "_GHP_LABEL='[^']+'; _GHP_USER='[^']+'" "$ZSHRC" 2>/dev/null \
            | sed -E "s/_GHP_LABEL='([^']+)'; _GHP_USER='([^']+)'/\1 \2/")
fi
EXPECTMAP="${EXPECTMAP%$'\n'}"
[ -n "$EXPECTMAP" ] && note "expected logins detected from gh-profiles block" || note "no gh-profiles mapping found — ghmcp will report logins without a match check"

# ---------- the managed zsh block ----------
BLOCK="$(cat <<'BLK'
# >>> github-mcp (managed by 60-github-mcp.sh) >>>
# `claude` is wrapped so each session launches with the GitHub PAT for the project's
# account, read from 1Password at launch (one Hello prompt) and scoped to that process
# only — never exported, never on disk. `ghmcp` validates the tokens on demand.
# Knobs: GH_MCP_DEFAULT (profile when outside ~/projects), GH_MCP_OP_TIMEOUT (read seconds).
typeset -gA GH_MCP_TOKENS
GH_MCP_TOKENS=(
__TOKMAP__
)
typeset -gA GH_MCP_EXPECT          # profile -> expected GitHub login (for ghmcp's match check)
GH_MCP_EXPECT=(
__EXPECTMAP__
)
: "${GH_MCP_DEFAULT:=__DEFAULTPROFILE__}"
: "${GH_MCP_OP_TIMEOUT:=__OPTIMEOUT__}"

__mcp_profile_for_pwd() {   # echo the profile for $PWD ('' if none); prefers gh-profiles' resolver
  if typeset -f _ghprofile_for_pwd >/dev/null 2>&1; then
    _ghprofile_for_pwd; print -r -- "${_GHP_LABEL:-}"
  else
    case "$PWD/" in
__CASES__
      *) print -r -- '' ;;
    esac
  fi
}

claude() {
  local prof ref tok
  # Token is only needed to start a session — skip the 1Password read (Hello prompt +
  # interop latency) for quick management commands. ('mcp' is NOT skipped so `claude mcp
  # list` reports github accurately.)
  case "${1:-}" in
    --version|-v|--help|-h|update|install|migrate-installer|config|doctor)
      command claude "$@"; return $? ;;
  esac
  prof="$(__mcp_profile_for_pwd)"
  [[ -z "$prof" && -n "${GH_MCP_DEFAULT:-}" ]] && prof="$GH_MCP_DEFAULT"
  ref="${GH_MCP_TOKENS[$prof]:-}"
  if [[ -n "$ref" ]]; then
    tok="$(timeout "${GH_MCP_OP_TIMEOUT:-60}" op.exe read "$ref" 2>/dev/null | tr -d '\r\n')"
    if [[ -n "$tok" ]]; then
      GITHUB_PERSONAL_ACCESS_TOKEN="$tok" command claude "$@"
      return $?
    fi
    print -u2 -- "claude: couldn't read the GitHub token for '$prof' — run 'ghmcp' to diagnose. Launching without GitHub MCP."
  elif [[ -n "$prof" ]]; then
    print -u2 -- "claude: no GH_MCP_TOKENS entry for '$prof' — launching without GitHub MCP."
  fi
  command claude "$@"
}

ghmcp() {  # ghmcp [profile|all] — validate the GitHub MCP token(s): account, expiry, scopes, match
  emulate -L zsh
  local arg="${1:-}" profs p ref tok hdr body login expiry scopes expect rc tmpb mark suffix
  command -v curl >/dev/null 2>&1 || { print -u2 -- "ghmcp: needs curl"; return 1; }
  if [[ "$arg" == all ]]; then
    profs=(${(ok)GH_MCP_TOKENS})
  elif [[ -n "$arg" ]]; then
    profs=("$arg")
  else
    p="$(__mcp_profile_for_pwd)"; [[ -z "$p" && -n "${GH_MCP_DEFAULT:-}" ]] && p="$GH_MCP_DEFAULT"
    [[ -n "$p" ]] || { print -- "ghmcp: not inside a project profile — try: ghmcp all"; return 1; }
    profs=("$p")
  fi
  for p in $profs; do
    ref="${GH_MCP_TOKENS[$p]:-}"
    if [[ -z "$ref" ]]; then print -P "%F{yellow}!%f %B$p%b: no token reference configured"; continue; fi
    tok="$(timeout "${GH_MCP_OP_TIMEOUT:-60}" op.exe read "$ref" 2>/dev/null | tr -d '\r\n')"
    if [[ -z "$tok" ]]; then print -P "%F{red}✗%f %B$p%b ($ref): 1Password read failed — item/field missing, vault locked, or not authorised"; continue; fi
    tmpb="$(mktemp)"
    hdr="$(curl -fsS --max-time 15 -D - -o "$tmpb" -H "Authorization: Bearer $tok" https://api.github.com/user 2>/dev/null)"; rc=$?
    body="$(<"$tmpb")"; command rm -f "$tmpb"
    if [[ $rc -ne 0 ]]; then
      if [[ $rc -eq 22 ]]; then print -P "%F{red}✗%f %B$p%b: token rejected by GitHub (expired, revoked, or invalid)"
      else print -P "%F{red}✗%f %B$p%b: couldn't reach GitHub (curl rc=$rc — network/timeout)"; fi
      continue
    fi
    login="$(print -r -- "$body" | command grep -oE '"login"[[:space:]]*:[[:space:]]*"[^"]+"' | command head -1 | command sed -E 's/.*"([^"]+)"$/\1/')"
    expiry="$(print -r -- "$hdr" | tr -d '\r' | command grep -i '^github-authentication-token-expiration:' | command sed -E 's/^[^:]+:[[:space:]]*//')"
    scopes="$(print -r -- "$hdr" | tr -d '\r' | command grep -i '^x-oauth-scopes:' | command sed -E 's/^[^:]+:[[:space:]]*//')"
    expect="${GH_MCP_EXPECT[$p]:-}"
    mark="%F{green}✓%f"; suffix=""
    if [[ -n "$expect" && "$login" != "$expect" ]]; then mark="%F{red}✗%f"; suffix=" %F{red}(expected @$expect — MISMATCH)%f"; fi
    print -P "$mark %B$p%b → @${login}${suffix}"
    print -P "    expires: ${expiry:-none set}    scopes: ${scopes:-(fine-grained or none reported)}"
  done
}
# <<< github-mcp (managed by 60-github-mcp.sh) <<<
BLK
)"
BLOCK="${BLOCK//__TOKMAP__/$TOKMAP}"
BLOCK="${BLOCK//__EXPECTMAP__/$EXPECTMAP}"
BLOCK="${BLOCK//__CASES__/$CASES}"
BLOCK="${BLOCK//__DEFAULTPROFILE__/$DEFAULT_PROFILE}"
BLOCK="${BLOCK//__OPTIMEOUT__/$OP_TIMEOUT}"

# ---------- assemble ~/.zshrc (strip old block, append fresh) ----------
assemble() {
  local tmp; tmp="$(mktemp)"
  if [ -f "$ZSHRC" ] && grep -q "^# >>> ${BLOCK_NAME} " "$ZSHRC"; then
    grep -q "^# <<< ${BLOCK_NAME} " "$ZSHRC" || warn "existing ${BLOCK_NAME} block had no end marker — repairing"
    strip_block "$ZSHRC" > "$tmp"
  elif [ -f "$ZSHRC" ]; then
    cp "$ZSHRC" "$tmp"
  fi
  printf '\n%s\n' "$BLOCK" >> "$tmp"
  cat "$tmp"; rm -f "$tmp"
}

# ---------- optional: verify the refs read (prompts Windows Hello) ----------
run_check() {
  hdr "verify 1Password references (this prompts Windows Hello)"
  if ! command -v op.exe >/dev/null 2>&1; then warn "op.exe not reachable — skipping"; return; fi
  for p in "${PROFILES[@]}"; do
    local ref="op://$VAULT/$PREFIX$p/$FIELD" out
    out="$(op.exe read "$ref" 2>/dev/null | tr -d '\r\n')"
    if [ -n "$out" ]; then ok "$p → $ref  (${#out} chars)"; else warn "$p → $ref  (empty / not found — create it in 1Password)"; fi
  done
  note "For full validation (account, expiry, scopes, match) run 'ghmcp all' after exec zsh."
}

# ---------- dry run ----------
if [ "$DRY" -eq 1 ]; then
  hdr "github-mcp block that would be written to ~/.zshrc"
  printf '%s\n' "$BLOCK"
  hdr "diff of ~/.zshrc (current -> after)"
  if [ -f "$ZSHRC" ] && command -v diff >/dev/null 2>&1; then
    diff -u "$ZSHRC" <(assemble) && note "(no change)" || true
  else
    note "~/.zshrc does not exist yet; the block above would be appended."
  fi
  [ "$CHECK" -eq 1 ] && run_check
  echo; printf '%sDry run complete.%s Re-run without --dry-run to apply.\n' "$G$B" "$Z"; exit 0
fi

# ---------- apply ----------
hdr "preflight"
command -v op.exe >/dev/null 2>&1 && ok "op.exe reachable" || warn "op.exe not reachable — the wrapper needs it at launch (enable the 1Password CLI integration)"
grep -q 'GITHUB_PERSONAL_ACCESS_TOKEN' "$HOME/.claude/plugins/cache/claude-plugins-official/github/unknown/.mcp.json" 2>/dev/null \
  && ok "github plugin expects \$GITHUB_PERSONAL_ACCESS_TOKEN (matches this wrapper)" \
  || note "couldn't confirm the github plugin manifest (continuing — the var name is standard)"

hdr "back up ~/.zshrc"
if [ -f "$ZSHRC" ]; then backup_file "$ZSHRC"; else warn "no existing ~/.zshrc — a new one will be created"; fi

hdr "write github-mcp block to ~/.zshrc"
assemble > "$ZSHRC.new" && mv "$ZSHRC.new" "$ZSHRC"
ok "block written (between markers; your other blocks left intact)"

[ "$CHECK" -eq 1 ] && run_check

hdr "done"
printf '%sGitHub MCP wrapper + ghmcp installed.%s\n' "$G$B" "$Z"
echo
note "1) Store one PAT per account in 1Password (scopes: repo, read:org):"
for p in "${PROFILES[@]}"; do note "     op://$VAULT/$PREFIX$p/$FIELD     (e.g.  opadd \"$PREFIX$p\" \"$VAULT\")"; done
note "2) exec zsh, then validate:  ghmcp all   (account + expiry + match per profile)"
note "3) cd ~/projects/<profile> && claude   →   claude mcp list shows github ✔ Connected"
echo
note "Fewer Hello prompts (no token cached): in the 1Password app, Settings → Security,"
note "  enable 'Unlock using system authentication' and lengthen auto-lock; its ~10-min"
note "  session then covers back-to-back launches. Tune waits with GH_MCP_OP_TIMEOUT=<secs>."
note "Off-project default account: ./60-github-mcp.sh --default personal   (or export GH_MCP_DEFAULT)."
note "Revert: delete the lines between the github-mcp markers in ~/.zshrc."
