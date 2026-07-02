#!/usr/bin/env bash
#
# 65-agent-fleet.sh — Wire the agent fleet (Claude Code · Codex · Claude Science) together.
#
# What it configures (all user-level, all idempotent):
#   1. Claude Code sandbox (~/.claude/settings.json) — enables the native bubblewrap sandbox
#      with a seeded network allowlist and credential blocking (~/.ssh, ~/.aws, gh tokens).
#      This script OWNS the "sandbox" key (re-runs replace it, like a managed block).
#   2. A global PreToolUse hook (~/.claude/hooks/protect-managed-configs.sh) that stops any
#      agent editing ~/.zshrc / ~/.gitconfig / ~/.ssh/config directly — those are assembled
#      from managed blocks; the owning script must be edited and re-run instead.
#   3. Codex: MCP servers (playwright, context7) in a managed block in ~/.codex/config.toml,
#      and a global environment brief in ~/.codex/AGENTS.md (Codex reads it natively).
#   4. A 'codexr' shell function (managed 'agent-fleet' block in ~/.zshrc): Codex as the
#      second-opinion REVIEWER — always launched with --sandbox read-only, so it can never
#      write; no arguments = review the uncommitted diff.
#
# Safe: backs up every file it edits to ~/.local/state/wsl2-dev/backups (newest 5 kept).
#
# Usage:
#   ./65-agent-fleet.sh             # apply
#   ./65-agent-fleet.sh --dry-run   # preview everything; write nothing
#
set -uo pipefail

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

BLOCK_NAME="agent-fleet"
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
insert_block(){ # file, block-content (block already includes its markers)
  local file="$1" block="$2" tmp
  if [ "$DRY" -eq 1 ]; then printf '\n%s--- would write managed block into %s ---%s\n%s\n' "$D" "${file/#$HOME/\~}" "$Z" "$block"; return; fi
  backup_file "$file"; mkdir -p "$(dirname "$file")"; tmp="$(mktemp)"
  if [ -f "$file" ] && grep -q "^# >>> ${BLOCK_NAME} " "$file"; then
    grep -q "^# <<< ${BLOCK_NAME} " "$file" || warn "existing ${BLOCK_NAME} block had no end marker — repairing"
    strip_block "$file" > "$tmp"
  elif [ -f "$file" ]; then cp "$file" "$tmp"; fi
  printf '\n%s\n' "$block" >> "$tmp"; mv "$tmp" "$file"
  ok "managed block written to ${file/#$HOME/\~}"
}

printf '%s%sAgent fleet setup (Claude Code · Codex · Claude Science)%s  %s\n' "$B" "$G" "$Z" \
  "${D}$([ "$DRY" -eq 1 ] && echo '(DRY RUN — writes nothing)')${Z}"

# ---------- prerequisites ----------
hdr "prerequisites"
command -v jq >/dev/null 2>&1 || die "jq is required (apt install jq) — settings.json is merged with it"
command -v claude >/dev/null 2>&1 && ok "claude $( claude --version 2>/dev/null | head -1)" || warn "claude not on PATH (sandbox config will still be written)"
command -v codex  >/dev/null 2>&1 && ok "codex $(codex --version 2>/dev/null | tail -1)"  || warn "codex not on PATH (its config will still be written)"

# ---------- 1. Claude Code sandbox (owns the "sandbox" key) ----------
hdr "Claude Code sandbox (~/.claude/settings.json)"
CSET="$HOME/.claude/settings.json"
HOOKSH="$HOME/.claude/hooks/protect-managed-configs.sh"
SANDBOX_JSON='{
  "enabled": true,
  "network": {
    "allowedDomains": [
      "github.com", "*.github.com", "*.githubusercontent.com",
      "api.anthropic.com", "*.anthropic.com", "claude.ai", "*.claude.com",
      "pypi.org", "files.pythonhosted.org", "astral.sh", "*.astral.sh",
      "download.pytorch.org", "huggingface.co", "*.huggingface.co",
      "registry.npmjs.org", "nodejs.org", "example.com"
    ]
  },
  "credentials": {
    "files": [
      { "path": "~/.config/gh", "mode": "deny" }
    ],
    "envVars": [
      { "name": "GITHUB_PERSONAL_ACCESS_TOKEN", "mode": "deny" },
      { "name": "GH_TOKEN",     "mode": "deny" },
      { "name": "GITHUB_TOKEN", "mode": "deny" }
    ]
  }
}'
NEWHOOK="$(jq -n --arg cmd "$HOOKSH" '{matcher:"Edit|Write|NotebookEdit",hooks:[{type:"command",command:$cmd}]}')"
CUR="{}"; [ -f "$CSET" ] && CUR="$(cat "$CSET")"
MERGED="$(jq --argjson sandbox "$SANDBOX_JSON" --argjson newhook "$NEWHOOK" --arg cmd "$HOOKSH" '
  .sandbox = $sandbox
  | .hooks.PreToolUse = ((.hooks.PreToolUse // []) | map(select(([.hooks[]?.command] | index($cmd)) | not))) + [$newhook]
' <<<"$CUR")" || die "jq merge failed — ~/.claude/settings.json left untouched"
if [ "$DRY" -eq 1 ]; then
  printf '%s--- would merge into ~/.claude/settings.json ---%s\n' "$D" "$Z"
  diff <(jq -S . <<<"$CUR") <(jq -S . <<<"$MERGED") | sed 's/^/  /' || true
else
  # Deny-masked paths must EXIST as real dirs or bwrap fails to start any command
  # (it mounts tmpfs over each one; symlinks into /mnt/c break it). On this machine
  # only ~/.config/gh holds an on-disk credential — SSH keys live in 1Password
  # (masking ~/.ssh would only hide the agent socket) and ~/.aws is a Windows symlink.
  mkdir -p "$HOME/.config/gh"
  backup_file "$CSET"; mkdir -p "$(dirname "$CSET")"
  printf '%s\n' "$MERGED" > "$CSET" && ok "sandbox enabled + credential blocking + protect-hook registered"
fi
info "this script owns the 'sandbox' key — tune domains here and re-run (backups keep the last 5 versions)"

# ---------- 2. the protect-managed-configs hook ----------
hdr "global hook: protect managed configs"
HOOK_BODY='#!/usr/bin/env bash
# Claude Code PreToolUse hook (installed by 65-agent-fleet.sh):
# ~/.zshrc, ~/.gitconfig and ~/.ssh/config are assembled from managed blocks —
# direct edits get overwritten on the next script run. Block them with guidance.
set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0
f="$(jq -r '"'"'.tool_input.file_path // empty'"'"' 2>/dev/null)" || exit 0
[ -n "$f" ] || exit 0
case "$f" in
  "$HOME/.zshrc"|"$HOME/.gitconfig"|"$HOME/.ssh/config")
    echo "Blocked: $f is assembled from managed blocks. Edit the owning script in the agentic-wsl repo and re-run it (each block header names its owner)." >&2
    exit 2 ;;
esac
exit 0'
if [ "$DRY" -eq 1 ]; then
  printf '%s--- would write %s ---%s\n%s\n' "$D" "${HOOKSH/#$HOME/\~}" "$Z" "$HOOK_BODY"
else
  mkdir -p "$(dirname "$HOOKSH")"; printf '%s\n' "$HOOK_BODY" > "$HOOKSH"; chmod 755 "$HOOKSH"
  ok "hook script installed at ${HOOKSH/#$HOME/\~}"
fi

# ---------- 3. Codex: MCP servers + global AGENTS.md ----------
hdr "Codex (~/.codex)"
insert_block "$HOME/.codex/config.toml" "# >>> ${BLOCK_NAME} (managed by 65-agent-fleet.sh) >>>
# MCP servers shared with Claude Code's standard set (stdio via npx; no secrets involved).
[mcp_servers.playwright]
command = \"npx\"
args = [\"-y\", \"@playwright/mcp@latest\"]

[mcp_servers.context7]
command = \"npx\"
args = [\"-y\", \"@upstash/context7-mcp\"]
# <<< ${BLOCK_NAME} (managed by 65-agent-fleet.sh) <<<"

insert_block "$HOME/.codex/AGENTS.md" "# >>> ${BLOCK_NAME} (managed by 65-agent-fleet.sh) >>>
# Environment brief — WSL2 workstation (applies to every repo unless its own AGENTS.md overrides)

- Python is uv-managed: \`uv sync\`, \`uv run\`, \`uv add\` — never pip or system python.
  Node comes from fnm; Bun is available. Never install tools with apt without being asked.
- Git identity, signing key, and GitHub account follow the directory
  (~/projects/{work,personal,imperial}). Never set a global git identity;
  commits are SSH-signed — do not disable signing.
- Secrets live in 1Password only. They reach processes via a gitignored .env
  (\`op inject -i .env.tpl -o .env\`) or \`op run\`. Never write a secret into
  code, logs, or a committed file.
- Code lives on ext4 under ~/projects — never under /mnt/c.
- ~/.zshrc, ~/.gitconfig, ~/.ssh/config are assembled from managed blocks by
  scripts in ~/projects/personal/agentic-wsl/agentic-wsl — edit the owning
  script and re-run it; never edit those files directly.
# <<< ${BLOCK_NAME} (managed by 65-agent-fleet.sh) <<<"

# ---------- 4. codexr reviewer function (managed ~/.zshrc block) ----------
hdr "codexr (~/.zshrc block)"
insert_block "$HOME/.zshrc" "# >>> ${BLOCK_NAME} (managed by 65-agent-fleet.sh) >>>
# Codex as second-opinion reviewer — always read-only sandboxed, so it can never write.
#   codexr                  review the uncommitted diff in the current repo
#   codexr \"<question>\"     ask for a read-only second opinion on anything
codexr() {
  if [ \$# -gt 0 ]; then
    command codex --sandbox read-only \"\$*\"
  else
    command codex --sandbox read-only \\
      'Review the uncommitted changes in this repo (git diff HEAD; include untracked files via git status). Report correctness bugs, risky patterns, and simpler alternatives — concise, highest severity first.'
  fi
}
# <<< ${BLOCK_NAME} (managed by 65-agent-fleet.sh) <<<"

# ---------- summary ----------
hdr "summary"
[ "$DRY" -eq 1 ] && { printf '\n%sDry run complete.%s Re-run without --dry-run to apply.\n' "$G$B" "$Z"; exit 0; }
echo "  ${B}1.${Z} Claude Code: sandbox on (network allowlist + credential blocking); managed-config guard hook active."
echo "  ${B}2.${Z} Codex: playwright + context7 MCP servers; global AGENTS.md brief; ${D}codexr${Z} = read-only reviewer."
echo "  ${B}3.${Z} Reload:  ${D}exec zsh${Z}   · verify:  ${D}./35-verify-setup.sh${Z} (section H)"
echo "  ${D}Rollback: restore ~/.claude/settings.json / ~/.codex/* from ~/.local/state/wsl2-dev/backups${Z}"
