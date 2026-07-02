#!/usr/bin/env bash
#
# 50-shortcuts.sh — Install workflow shortcuts for the WSL2 dev environment.
#
# Adds a managed '# >>> dev-shortcuts >>>' block to ~/.zshrc (helper functions) and
# installs a standalone 'docs' command into ~/.local/bin. Complements the existing
# blocks (comfort-shell, wsl2-dev-setup, git-profiles, gh-profiles, win-shortcuts) —
# it touches ONLY its own block and leaves the others alone.
#
# What you get:
#   1Password   opget <ref>      print a secret to stdout (CR-stripped)
#               opcp  <ref>      copy a secret straight to the Windows clipboard
#               opadd <title>    create an API credential (hidden prompt — nothing in history)
#   Project env openv            render ./.env from ./.env.tpl (one Hello prompt, once/session)
#               oprun <cmd...>   run a process with secrets injected — zero plaintext on disk
#   Nav         mkcd <dir>       mkdir -p + cd
#               pj               fuzzy-jump to any project under ~/projects (needs fzf)
#   Docs        docs [query]     condensed reference of ALL your custom commands
#
# Properties: idempotent (re-run replaces its block), backs up ~/.zshrc first, --dry-run safe.
# Reads/writes secrets only via op.exe; never writes a private key or token to disk itself.
#
# Usage:
#   ./50-shortcuts.sh --dry-run                # preview the block + ~/.zshrc diff; write nothing
#   ./50-shortcuts.sh                          # apply (backs up ~/.zshrc, installs ~/.local/bin/docs)
#   ./50-shortcuts.sh --vault "Private"        # bake an OP_VAULT default for opadd
#
set -uo pipefail

# ---------- options ----------
DRY=0
VAULT=""
while [ "$#" -gt 0 ]; do case "$1" in
  --dry-run|-n)  DRY=1; shift ;;
  --vault)       VAULT="${2:-}"; shift 2 ;;
  --vault=*)     VAULT="${1#*=}"; shift ;;
  -h|--help)     sed -n '2,/^set /{/^set /!p;}' "$0"; exit 0 ;;
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
LBIN="$HOME/.local/bin"
BLOCK_NAME="dev-shortcuts"
MSTART="# >>> ${BLOCK_NAME} (managed by 50-shortcuts.sh) >>>"
MEND="# <<< ${BLOCK_NAME} (managed by 50-shortcuts.sh) <<<"
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

printf '%s%sWorkflow shortcuts%s  %s(%s)%s\n' "$B" "$G" "$Z" "$D" \
  "$([ "$DRY" -eq 1 ] && echo 'DRY RUN — writes nothing' || echo 'live run')" "$Z"

# ---------- OP_VAULT line (baked into the block) ----------
if [ -n "$VAULT" ]; then VAULT_LINE="export OP_VAULT=\"$VAULT\""
else VAULT_LINE='# export OP_VAULT="Private"   # default vault for opadd — run `op vault list` to see names'; fi

# ---------- the managed zsh block ----------
BLOCK="$(cat <<'BLK'
# >>> dev-shortcuts (managed by 50-shortcuts.sh) >>>
# Workflow helpers. Functions call op.exe directly (not the `op` alias) so they
# behave predictably, and strip the CR that the Windows 1Password CLI emits.
__OPVAULT__

# --- 1Password: read / copy / create secrets (no plaintext on disk or in history) ---
opget() {  # opget op://Vault/Item/field   — print one secret (CR-stripped)
  [ -n "${1:-}" ] || { echo "usage: opget op://Vault/Item/field" >&2; return 1; }
  op.exe read "$1" 2>/dev/null | tr -d '\r'
}
opcp() {   # opcp op://Vault/Item/field    — copy a secret to the Windows clipboard
  [ -n "${1:-}" ] || { echo "usage: opcp op://Vault/Item/field" >&2; return 1; }
  command -v clip.exe >/dev/null 2>&1 || { echo "opcp: clip.exe not found" >&2; return 1; }
  op.exe read "$1" 2>/dev/null | tr -d '\r\n' | clip.exe && echo "copied to clipboard"
}
opadd() {  # opadd "Title" [vault]         — create an API credential; secret prompt is hidden
  local title="${1:-}" vault="${2:-${OP_VAULT:-}}" secret
  [ -n "$title" ] || { echo "usage: opadd <title> [vault]" >&2; return 1; }
  printf 'secret value (hidden): '
  stty -echo 2>/dev/null; IFS= read -r secret; stty echo 2>/dev/null; printf '\n'
  [ -n "$secret" ] || { echo "opadd: empty secret, aborted" >&2; return 1; }
  op.exe item create --category="API Credential" --title="$title" \
    ${vault:+--vault="$vault"} "credential=$secret" >/dev/null \
    && echo "created '$title'${vault:+ in $vault}"
}

# --- project env: resolve secrets once per session, never per-cd ---
openv() {  # render ./.env from ./.env.tpl  (one Windows Hello prompt; CR-stripped)
  [ -f .env.tpl ] || { echo "openv: no .env.tpl in $(pwd)" >&2; return 1; }
  op.exe inject -i .env.tpl 2>/dev/null | tr -d '\r' > .env \
    && echo ".env rendered ($(grep -c . .env) entries)"
}
oprun() {  # oprun <cmd...>  — run a process with .env.tpl secrets injected (zero on disk)
  [ -f .env.tpl ] || { echo "oprun: no .env.tpl in $(pwd)" >&2; return 1; }
  op.exe run --env-file=.env.tpl -- "$@"
}

# --- navigation niceties ---
mkcd() { [ -n "${1:-}" ] || { echo "usage: mkcd <dir>" >&2; return 1; }; mkdir -p "$1" && cd "$1"; }
pj() {   # fuzzy-jump to any project under ~/projects (complements zoxide's z)
  command -v fzf >/dev/null 2>&1 || { echo "pj: fzf not found" >&2; return 1; }
  local d; d="$(find "$HOME/projects" -mindepth 1 -maxdepth 2 -type d 2>/dev/null | fzf)" && cd "$d"
}
# <<< dev-shortcuts (managed by 50-shortcuts.sh) <<<
BLK
)"
BLOCK="${BLOCK//__OPVAULT__/$VAULT_LINE}"

# ---------- the docs command (installed to ~/.local/bin/docs) ----------
# A condensed, self-contained cheatsheet of the custom commands this environment defines.
# Edit the reference below and re-run this script to update it.
DOCS="$(cat <<'DOCS'
#!/usr/bin/env bash
# docs — condensed reference for your custom WSL2 dev commands.
#
#   docs              show the full command reference (paged)
#   docs <query>      show only entries matching <query>   (e.g. docs op, docs download)
#
set -uo pipefail
case "${1:-}" in -h|--help) sed -n '2,/^set /{/^set /!p;}' "$0"; exit 0 ;; esac

REF="$(cat <<'REF'
CUSTOM COMMANDS — quick reference
Secrets are read live from 1Password via op.exe; nothing is written to disk.
Filter with: docs <query>   (e.g. `docs op`, `docs download`, `docs token`)

1PASSWORD & SECRETS                                           [dev-shortcuts]
  opget <op://Vault/Item/field>   print one secret to stdout (CR-stripped)
  opcp  <op://Vault/Item/field>   copy a secret to the Windows clipboard (not printed)
  opadd "<Title>" [vault]         create an API Credential; secret typed at a hidden prompt
  op <args...>                    the 1Password CLI itself (alias -> op.exe)

PROJECT ENVIRONMENT                                           [dev-shortcuts]
  openv                           render ./.env from ./.env.tpl, once per session
  oprun <cmd...>                  run <cmd> with .env.tpl secrets injected (zero on disk)

GITHUB / CLAUDE MCP                                 [github-mcp / gh-profiles]
  claude                          launch Claude; injects the project account's GitHub PAT
                                  from 1Password (one Hello prompt). --version / update /
                                  config / doctor / mcp* skip the token fetch.
  ghwho                           check gh's active account matches the current folder

NAVIGATION                                     [git-profiles / dev-shortcuts]
  proj | work | pers | icl        cd to ~/projects[ /work | /personal | /imperial ]
  pj                              fuzzy-pick any project under ~/projects (fzf)
  mkcd <dir>                      mkdir -p <dir> and cd into it
  home                            cd ~
  z <term>                        zoxide: jump to a frecent directory

WINDOWS BRIDGE                              [wsl2-dev-setup / win-shortcuts]
  open <url|file|dir>             open in the default Windows app (alias -> wopen)
  wopen <url|file|dir>            same; handles URLs, browser flags, and paths
  files                           open the current folder in Windows Explorer
  code                            open the current folder in VS Code
  dl                              cd to the Windows Downloads folder
  dls [N]                         list the N most-recent downloads (default 10)
  dlcp <name>...                  copy item(s) from Downloads into .
  dlmv <name>...                  move item(s) from Downloads into .
  dlput <name>...                 copy item(s) from . into Downloads

GIT & MODERN CLI                                            [comfort-shell]
  gs | ga | gc | gp               git status | add | commit | push
  ls | ll | lt                    eza listings (icons | long+git | tree)
  cat | grep | find               bat | ripgrep | fd
  (commit identity, signing & SSH key switch automatically by ~/projects/<profile>)

PROJECT SCAFFOLDING & HEALTH
  new-project.sh <name> [flags]   scaffold a uv project (cu128 torch, ruff, direnv,
                                  Playwright); run inside a profile dir for the right identity
  35-verify-setup.sh              read-only health check of the whole environment
  docs [query]                    this reference

Windows Hello prompts once per session; 1Password's ~10-min window means
back-to-back commands won't re-prompt.
REF
)"

BAT="$(command -v bat || command -v batcat || true)"
PAGER_CMD="cat"; command -v less >/dev/null 2>&1 && PAGER_CMD="less -RFX"

if [ "$#" -eq 0 ]; then
  if [ -n "$BAT" ]; then printf '%s\n' "$REF" | "$BAT" --style=plain --paging=auto
  else printf '%s\n' "$REF" | $PAGER_CMD; fi
else
  if command -v rg >/dev/null 2>&1; then
    printf '%s\n' "$REF" | rg -i --color=always -C1 -- "$*" | $PAGER_CMD || true
  else
    printf '%s\n' "$REF" | grep -i --color=always -C1 -- "$*" | $PAGER_CMD || true
  fi
fi
DOCS
)"

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

# ---------- dry run ----------
if [ "$DRY" -eq 1 ]; then
  hdr "dev-shortcuts block that would be written to ~/.zshrc"
  printf '%s\n' "$BLOCK"
  hdr "diff of ~/.zshrc (current -> after)"
  if [ -f "$ZSHRC" ] && command -v diff >/dev/null 2>&1; then
    diff -u "$ZSHRC" <(assemble) && note "(no change)" || true
  else
    note "~/.zshrc does not exist yet; the block above would be appended."
  fi
  hdr "files that would be created"
  note "$LBIN/docs  (condensed reference of your custom commands)"
  echo; printf '%sDry run complete.%s Re-run without --dry-run to apply.\n' "$G$B" "$Z"; exit 0
fi

# ---------- apply ----------
hdr "back up ~/.zshrc"
if [ -f "$ZSHRC" ]; then backup_file "$ZSHRC"; else warn "no existing ~/.zshrc — a new one will be created"; fi

hdr "write dev-shortcuts block to ~/.zshrc"
assemble > "$ZSHRC.new" && mv "$ZSHRC.new" "$ZSHRC"
ok "block written (between markers; your other blocks left intact)"

hdr "install docs command"
mkdir -p "$LBIN"
[ -f "$LBIN/docs" ] && backup_file "$LBIN/docs"
printf '%s\n' "$DOCS" > "$LBIN/docs"; chmod +x "$LBIN/docs"
ok "$LBIN/docs installed (condensed command reference)"
case ":$PATH:" in *":$LBIN:"*) : ;; *) warn "$LBIN is not on PATH in this shell — your wsl2-dev-setup block adds it for zsh";; esac

hdr "done"
printf '%sShortcuts installed — apply to your current shell with: %sexec zsh%s\n' "$G$B" "$Z$B" "$Z"
echo
note "Try:  docs            (full command reference)      docs op   (filter to matching commands)"
note "      opget op://Private/OpenAI/credential          opadd \"New API key\""
note "Revert: delete the lines between the dev-shortcuts markers in ~/.zshrc, and rm $LBIN/docs"
