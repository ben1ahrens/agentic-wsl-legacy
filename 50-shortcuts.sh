#!/usr/bin/env bash
#
# 50-shortcuts.sh — Install workflow shortcuts for the WSL2 dev environment.
#
# Adds a managed '# >>> dev-shortcuts >>>' block to ~/.zshrc (helper functions) and
# installs standalone commands into ~/.local/bin: docs, notify, lab, onboard.
# Complements the other managed blocks — it touches ONLY its own block.
#
# What you get:
#   1Password   opget <ref>      print a secret to stdout (CR-stripped)
#               opcp  <ref>      copy a secret straight to the Windows clipboard
#               opadd <title>    create an API credential (hidden prompt — nothing in history)
#   Project env openv            render ./.env from ./.env.tpl (one Hello prompt, once/session)
#               oprun <cmd...>   run a process with secrets injected — zero plaintext on disk
#   Research    train <cmd...>   run in a detached tmux session; Windows toast when it finishes
#               nb               JupyterLab for the current uv project (opens in Windows browser)
#   Nav         mkcd <dir>       mkdir -p + cd
#               pj               fuzzy-jump to any project under ~/projects (needs fzf)
#   Installed   docs [query]     condensed reference of ALL your custom commands
#   (~/.local/  notify [t] [m]   Windows toast from any script, hook, or tmux session
#    bin)       lab              one-screen dashboard: GPU, disk, caches, sessions, docker
#               onboard <repo>   clone into the current profile dir + auto-set-up its env
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

# --- research workflow ---
train() {  # train <cmd...> — run in a detached tmux session; Windows toast when it finishes
  command -v tmux >/dev/null 2>&1 || { echo "train: tmux not installed" >&2; return 1; }
  [ $# -gt 0 ] || { echo "usage: train <command...>   (tmux session + toast on exit)" >&2; return 1; }
  local name="train-$(date +%H%M%S)"
  tmux new-session -d -s "$name" -c "$PWD" \
    "$* ; rc=\$?; notify \"train: $name\" \"exit \$rc — ${PWD##*/}\"; printf '\n[train] finished (exit %s) — press enter to close ' \"\$rc\"; read -r _"
  echo "→ running in tmux session '$name'   (watch: tmux attach -t $name · list: tmux ls)"
}
nb() {  # JupyterLab for the current uv project — opens in the Windows browser (BROWSER=wopen)
  [ -f pyproject.toml ] || { echo "nb: run inside a uv project (no pyproject.toml here)" >&2; return 1; }
  uv run --with jupyter jupyter lab
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

RESEARCH WORKFLOW                                             [dev-shortcuts]
  train <cmd...>                  run in a detached tmux session; Windows toast on finish
  nb                              JupyterLab for the current uv project (Windows browser)
  notify [title] [msg]            Windows toast from any script, hook, or tmux session
  lab                             dashboard: GPU, disk, caches, tmux, docker, Claude Science

AGENT FLEET                            [github-mcp / agent-fleet / claude-science]
  claude                          launch Claude Code; injects the project account's GitHub
                                  PAT from 1Password (one Hello prompt). --version / update /
                                  config / doctor skip the token fetch.
  codexr ["question"]             Codex as read-only reviewer — no args: review the
                                  uncommitted diff (sandboxed; it can never write)
  science [cmd]                   Claude Science workbench — start the daemon + open the UI
                                  in the Windows browser (status · url · logs · stop · update)
  ghmcp [profile|all]             validate GitHub-MCP tokens (account, expiry, scopes)
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
  new-project.sh <name> [flags]   scaffold a uv project (cu130 torch, ruff, direnv, Playwright,
                                  agent config; --ml adds HF stack + trackio + notebooks);
                                  run inside a profile dir for the right identity
  onboard <url|org/repo> [dir]    clone a third-party repo into this profile dir and
                                  auto-set-up its env (uv/npm/bun, direnv, pre-commit)
  35-verify-setup.sh              read-only health check (A-J: base, git, ML/GPU, agents,
                                  GUI, managed-block integrity)
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

# ---------- the notify command (installed to ~/.local/bin/notify) ----------
# Standalone so tmux sessions, Claude hooks, and plain sh scripts can all call it.
NOTIFY="$(cat <<'NTF'
#!/usr/bin/env bash
# notify [title] [message] — Windows toast from WSL (PowerShell WinRT; nothing to install).
set -uo pipefail
case "${1:-}" in -h|--help) echo "usage: notify [title] [message]"; exit 0 ;; esac
title="${1:-WSL}"; msg="${2:-done}"
# strip characters that would break the toast XML
title="${title//[<>&\"\']/ }"; msg="${msg//[<>&\"\']/ }"
command -v powershell.exe >/dev/null 2>&1 || exit 0
powershell.exe -NoProfile -Command "
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
\$x = New-Object Windows.Data.Xml.Dom.XmlDocument
\$x.LoadXml(\"<toast><visual><binding template='ToastGeneric'><text>$title</text><text>$msg</text></binding></visual></toast>\")
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('WSL').Show((New-Object Windows.UI.Notifications.ToastNotification \$x))
" >/dev/null 2>&1 &
exit 0
NTF
)"

# ---------- the lab command (installed to ~/.local/bin/lab) ----------
LAB="$(cat <<'LABEOF'
#!/usr/bin/env bash
# lab — one-screen status dashboard: GPU, disk, caches, tmux sessions, docker, Claude Science.
set -uo pipefail
case "${1:-}" in -h|--help) sed -n '2,2p' "$0"; exit 0 ;; esac
B=$'\033[1m'; D=$'\033[2m'; Z=$'\033[0m'; [ -t 1 ] || { B=""; D=""; Z=""; }
echo "${B}── lab · $(date '+%a %H:%M') ──${Z}"
if command -v nvidia-smi >/dev/null 2>&1; then
  timeout 8 nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu,temperature.gpu \
    --format=csv,noheader 2>/dev/null \
    | awk -F', ' '{printf "GPU   %s — %s / %s · %s util · %s°C\n",$1,$2,$3,$4,$5}'
fi
df -h "$HOME" 2>/dev/null | awk 'NR==2{printf "disk  %s used / %s free (%s)\n",$3,$4,$5}'
printf 'cache uv %s · hf %s\n' \
  "$(du -sh "$HOME/.cache/uv" 2>/dev/null | cut -f1 || echo 0)" \
  "$(du -sh "$HOME/.cache/huggingface" 2>/dev/null | cut -f1 || echo 0)"
if command -v tmux >/dev/null 2>&1 && tmux ls >/dev/null 2>&1; then
  echo "tmux  $(tmux ls 2>/dev/null | awk -F: '{printf "%s ",$1}')"
else echo "tmux  ${D}no sessions${Z}"; fi
if command -v docker >/dev/null 2>&1 && timeout 4 docker info >/dev/null 2>&1; then
  echo "dock  $(docker ps -q 2>/dev/null | wc -l | tr -d ' ') container(s) running"
else echo "dock  ${D}daemon not running${Z}"; fi
if [ -x "$HOME/.local/bin/claude-science" ]; then
  cs="$(timeout 6 "$HOME/.local/bin/claude-science" status 2>/dev/null | grep -o '"running": *[a-z]*' | awk '{print $2}')"
  [ "${cs:-}" = "true" ] && echo "sci   claude-science running" || echo "sci   ${D}claude-science stopped (launch: science)${Z}"
fi
echo "proj  recent: $(ls -td "$HOME"/projects/*/*/ 2>/dev/null | head -3 | xargs -r -n1 basename 2>/dev/null | tr '\n' ' ')"
echo "${D}more: docs · 35-verify-setup.sh · ghmcp all · train <cmd> · nb · science${Z}"
LABEOF
)"

# ---------- the onboard command (installed to ~/.local/bin/onboard) ----------
ONBOARD="$(cat <<'ONB'
#!/usr/bin/env bash
# onboard <url|org/repo> [dir] — clone a repo into the CURRENT profile dir and set up its env.
# Detects the stack (uv/pyproject, requirements.txt, package.json), installs deps, wires
# direnv without dirtying the repo (.git/info/exclude), and reports the inherited identity.
set -uo pipefail
url="${1:-}"; case "$url" in ""|-h|--help) sed -n '2,4p' "$0"; exit 0 ;; esac
case "$PWD/" in "$HOME/projects/"*) ;; *)
  echo "onboard: run from inside a profile dir (~/projects/<profile>/...) so git identity is inherited" >&2; exit 1 ;;
esac
case "$url" in
  http*|git@*) ;;
  */*) url="git@github.com:${url}.git" ;;   # org/repo shorthand; per-profile insteadOf rewrites the host
  *) echo "onboard: expected a URL or org/repo" >&2; exit 1 ;;
esac
dir="${2:-$(basename "$url" .git)}"
[ -e "$dir" ] && { echo "onboard: ./$dir already exists" >&2; exit 1; }
echo "→ cloning $url"
git clone "$url" "$dir" || exit 1
cd "$dir" || exit 1
echo "→ identity: $(git config user.name 2>/dev/null) <$(git config user.email 2>/dev/null)> (from this directory's profile)"
py=0
if [ -f pyproject.toml ] || [ -f uv.lock ]; then
  py=1; echo "→ python (uv project): uv sync"
  uv sync || echo "! uv sync failed — inspect manually"
elif [ -f requirements.txt ]; then
  py=1; echo "→ python (requirements.txt): uv venv + install"
  { uv venv && uv pip install -r requirements.txt; } || echo "! install failed — inspect manually"
fi
if [ -f package.json ]; then
  if [ -f bun.lock ] || [ -f bun.lockb ]; then echo "→ node (bun): bun install"; bun install || true
  else echo "→ node (npm): npm install"; npm install || true; fi
fi
if [ "$py" -eq 1 ] && [ ! -f .envrc ]; then
  printf 'layout uv\ndotenv_if_exists .env\n' > .envrc
  echo ".envrc" >> .git/info/exclude
  command -v direnv >/dev/null 2>&1 && direnv allow . >/dev/null 2>&1
  echo "→ direnv wired (.envrc kept out of the repo via .git/info/exclude)"
fi
[ -f .pre-commit-config.yaml ] && command -v pre-commit >/dev/null 2>&1 \
  && pre-commit install >/dev/null 2>&1 && echo "→ pre-commit hooks installed"
echo "✓ onboarded ./$dir — cd '$dir' to start"
ONB
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
  note "$LBIN/docs     (condensed reference of your custom commands)"
  note "$LBIN/notify   (Windows toast from WSL)"
  note "$LBIN/lab      (status dashboard)"
  note "$LBIN/onboard  (third-party repo onboarder)"
  echo; printf '%sDry run complete.%s Re-run without --dry-run to apply.\n' "$G$B" "$Z"; exit 0
fi

# ---------- apply ----------
hdr "back up ~/.zshrc"
if [ -f "$ZSHRC" ]; then backup_file "$ZSHRC"; else warn "no existing ~/.zshrc — a new one will be created"; fi

hdr "write dev-shortcuts block to ~/.zshrc"
assemble > "$ZSHRC.new" && mv "$ZSHRC.new" "$ZSHRC"
ok "block written (between markers; your other blocks left intact)"

hdr "install commands (docs · notify · lab · onboard)"
mkdir -p "$LBIN"
install_bin(){ # name, content
  [ -f "$LBIN/$1" ] && backup_file "$LBIN/$1"
  printf '%s\n' "$2" > "$LBIN/$1"; chmod +x "$LBIN/$1"; ok "$LBIN/$1 installed"
}
install_bin docs "$DOCS"
install_bin notify "$NOTIFY"
install_bin lab "$LAB"
install_bin onboard "$ONBOARD"
case ":$PATH:" in *":$LBIN:"*) : ;; *) warn "$LBIN is not on PATH in this shell — your wsl2-dev-setup block adds it for zsh";; esac

hdr "done"
printf '%sShortcuts installed — apply to your current shell with: %sexec zsh%s\n' "$G$B" "$Z$B" "$Z"
echo
note "Try:  docs   ·   lab   ·   train uv run python train.py   ·   onboard org/repo"
note "      opget op://Private/OpenAI/credential          opadd \"New API key\""
note "Revert: delete the dev-shortcuts block in ~/.zshrc; rm $LBIN/{docs,notify,lab,onboard}"
