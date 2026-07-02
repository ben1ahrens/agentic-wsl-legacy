#!/usr/bin/env bash
#
# 30-shell.sh — Wire the installed tools into zsh, COMPLEMENTING an existing setup.
#
# It adds ONLY the pieces a typical curated .zshrc (e.g. a 'comfort-shell' block) lacks:
#   - ~/.local/bin, fnm, and Bun on PATH; PATH de-dupe + Windows-node prune
#   - fnm init (Linux Node) + bun completions + fzf keybindings
#   - op/open/BROWSER helpers + larger shared history
# It does NOT re-init brew/starship/direnv/zoxide and does NOT touch your aliases,
# keybindings, or plugins — those stay owned by your existing block.
#
# Also creates ~/.local/bin/wopen (+ xdg-open symlink) and ~/.config/direnv/direnvrc.
#
# Idempotent + reversible: writes a single marked block (re-running replaces it),
# backs up ~/.zshrc first, and applies nothing until you run `exec zsh`.
#
# Usage:
#   ./30-shell.sh --dry-run   # show the block + a diff of ~/.zshrc; write nothing
#   ./30-shell.sh             # apply (backs up first)
#
set -uo pipefail

DRY=0
for a in "$@"; do case "$a" in
  --dry-run|-n) DRY=1 ;;
  -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
  *) echo "Unknown option: $a" >&2; exit 2 ;;
esac; done

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
BLOCK_NAME="wsl2-dev-setup"
MSTART="# >>> ${BLOCK_NAME} (managed by 30-shell.sh) >>>"
MEND="# <<< ${BLOCK_NAME} (managed by 30-shell.sh) <<<"
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

printf '%s%sShell wiring (complementary)%s  %s(%s)%s\n' "$B" "$G" "$Z" "$D" \
  "$([ "$DRY" -eq 1 ] && echo 'DRY RUN — writes nothing' || echo 'live run')" "$Z"

# ---------- locate fnm dir (default vs legacy) ----------
FNMDIR='$HOME/.local/share/fnm'
[ -x "$HOME/.fnm/fnm" ] && [ ! -x "$HOME/.local/share/fnm/fnm" ] && FNMDIR='$HOME/.fnm'
note "fnm dir: $FNMDIR"

# ---------- sanity: does the existing .zshrc already init the things we assume? ----------
if [ -f "$ZSHRC" ]; then
  for pat in 'brew shellenv:Homebrew' 'starship init:starship prompt' 'direnv hook:direnv' 'zoxide init:zoxide'; do
    key="${pat%%:*}"; label="${pat##*:}"
    grep -qF "$key" "$ZSHRC" || warn "your ~/.zshrc doesn't appear to init ${label}; this block does NOT add it."
  done
fi

# ---------- the complementary block ----------
BLOCK="$(cat <<'BLK'
# >>> wsl2-dev-setup (managed by 30-shell.sh) >>>
# Complements your existing shell block — adds ONLY what it lacks.
# (brew, starship, direnv, zoxide, your aliases, keybindings, plugins are left untouched.)
# --- PATH: tool dirs your existing block doesn't add ---
export PATH="$HOME/.local/bin:$PATH"                       # uv, uv tools (pre-commit), wopen
export PATH="__FNMDIR__:$PATH"                             # fnm binary
export BUN_INSTALL="$HOME/.bun"; export PATH="$BUN_INSTALL/bin:$PATH"   # Bun
typeset -U PATH path                                       # de-duplicate PATH
path=("${(@)path:#*/nvm4w/*}")                             # remove Windows nvm4w node
path=("${(@)path:#*/AppData/Roaming/npm}")                 # remove Windows global npm
# --- runtimes your existing block doesn't init ---
eval "$(fnm env --use-on-cd)"                              # Linux Node now wins; auto-switch per dir
[ -s "$BUN_INSTALL/_bun" ] && source "$BUN_INSTALL/_bun"   # bun completions
# fzf keybindings — version-robust: fzf >=0.48 (e.g. brew) uses --zsh; older apt fzf sources shipped files
if command -v fzf >/dev/null 2>&1; then
  if fzf --zsh >/dev/null 2>&1; then source <(fzf --zsh)
  else for _f in /usr/share/doc/fzf/examples/key-bindings.zsh /usr/share/doc/fzf/examples/completion.zsh; do [ -r "$_f" ] && source "$_f"; done; fi
fi
# atuin history — fuzzy, ranked Ctrl-R; init AFTER fzf so atuin owns Ctrl-R (fzf keeps
# Ctrl-T / Alt-C). Local-only unless you run `atuin login`; up-arrow stays standard zsh.
command -v atuin >/dev/null 2>&1 && eval "$(atuin init zsh --disable-up-arrow)"
# --- 1Password + Windows-open helpers ---
alias op="op.exe"                                          # 1Password CLI via Windows Hello
alias open="wopen"                                         # open files/URLs in Windows
export BROWSER="$HOME/.local/bin/wopen"                    # gh / xdg-open / webbrowser use wopen
# --- history ---
HISTSIZE=100000; SAVEHIST=100000
setopt SHARE_HISTORY HIST_IGNORE_ALL_DUPS HIST_REDUCE_BLANKS
# <<< wsl2-dev-setup (managed by 30-shell.sh) <<<
BLK
)"
BLOCK="${BLOCK//__FNMDIR__/$FNMDIR}"

WOPEN="$(cat <<'WO'
#!/usr/bin/env bash
# wopen — open URLs/files from WSL in Windows.
#
# Robust enough for CLI OAuth flows that may call browser commands with flags:
#   wopen https://example.com
#   wopen --new-window https://example.com
#   wopen -- https://example.com
#   wopen --app=https://example.com
#   wopen .
#
# Debug:
#   WOPEN_DEBUG=1 wopen https://example.com
#   tail -f /tmp/wopen.log

set -u

debug_log() {
  if [ "${WOPEN_DEBUG:-0}" = "1" ]; then
    {
      printf '\n--- wopen %s ---\n' "$(date -Is)"
      printf 'argc=%s\n' "$#"
      i=0
      for a in "$@"; do
        printf 'arg[%s]=<%s>\n' "$i" "$a"
        i=$((i + 1))
      done
    } >> /tmp/wopen.log
  fi
}

die() {
  echo "wopen: $*" >&2
  exit 1
}

strip_outer_quotes() {
  local s="$1"

  # Remove one layer of literal surrounding quotes, in case a caller passed them.
  case "$s" in
    \"*\") s="${s#\"}"; s="${s%\"}" ;;
    \'*\') s="${s#\'}"; s="${s%\'}" ;;
  esac

  printf '%s' "$s"
}

extract_url_from_arg() {
  local s
  s="$(strip_outer_quotes "$1")"

  # URL is the whole argument.
  case "$s" in
    http://*|https://*|mailto:*|file://*)
      printf '%s' "$s"
      return 0
      ;;
  esac

  # URL is embedded inside an argument, e.g. --app=https://example.com
  case "$s" in
    *https://*)
      s="https://${s#*https://}"
      ;;
    *http://*)
      s="http://${s#*http://}"
      ;;
    *mailto:*)
      s="mailto:${s#*mailto:}"
      ;;
    *file://*)
      s="file://${s#*file://}"
      ;;
    *)
      return 1
      ;;
  esac

  # Trim common trailing literal quotes/brackets that can appear in logs/wrappers.
  s="${s%\"}"
  s="${s%\'}"

  printf '%s' "$s"
  return 0
}

if [ "$#" -eq 0 ]; then
  die "usage: wopen <url|file|dir>"
fi

debug_log "$@"

target=""
saw_option=0

# 1. Prefer any URL-like value anywhere in the arguments.
for arg in "$@"; do
  if url="$(extract_url_from_arg "$arg")"; then
    target="$url"
    break
  fi

  case "$arg" in
    --|-*) saw_option=1 ;;
  esac
done

# 2. If no URL was found, fall back to a file/path only for normal direct use.
#    If browser-style options were present, do NOT accidentally open File Explorer.
if [ -z "$target" ]; then
  if [ "$saw_option" -eq 1 ]; then
    if [ "${WOPEN_DEBUG:-0}" = "1" ]; then
      echo "no URL found; refusing to treat browser flags as paths" >> /tmp/wopen.log
    fi
    die "no URL found in browser-style invocation; refusing to open File Explorer"
  fi

  # Normal path mode: wopen . / wopen ./file.txt
  target="$(strip_outer_quotes "$1")"
fi

case "$target" in
  http://*|https://*|mailto:*|file://*)
    loc="$target"
    kind="url"
    ;;
  *)
    command -v wslpath >/dev/null 2>&1 || die "wslpath not found"
    command -v realpath >/dev/null 2>&1 || die "realpath not found"
    loc="$(wslpath -w "$(realpath -m "$target")")"
    kind="path"
    ;;
esac

if [ "${WOPEN_DEBUG:-0}" = "1" ]; then
  {
    printf 'target=<%s>\n' "$target"
    printf 'kind=<%s>\n' "$kind"
    printf 'loc=<%s>\n' "$loc"
  } >> /tmp/wopen.log
fi

# URLs: use Windows URL protocol handler.
# Avoid `cmd.exe /c start`, because OAuth URLs contain &.
if [ "$kind" = "url" ]; then
  rundll32.exe url.dll,FileProtocolHandler "$loc" >/dev/null 2>&1 &
else
  explorer.exe "$loc" >/dev/null 2>&1 &
fi

exit 0
WO
)"

DIRENVRC="$(cat <<'DR'
layout_uv() {
  if [[ ! -d ".venv" ]]; then uv venv; fi
  PATH_add ".venv/bin"
  export VIRTUAL_ENV="$PWD/.venv" UV_ACTIVE=1
}
DR
)"

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

if [ "$DRY" -eq 1 ]; then
  hdr "complementary block that would be appended to ~/.zshrc"
  printf '%s\n' "$BLOCK"
  hdr "diff of ~/.zshrc (current -> after)"
  if [ -f "$ZSHRC" ] && command -v diff >/dev/null 2>&1; then
    diff -u "$ZSHRC" <(assemble) && note "(no change)" || true
  else
    note "~/.zshrc does not exist yet; the block above would be its content."
  fi
  hdr "files that would be created"
  note "~/.local/bin/wopen  (+ ~/.local/bin/xdg-open -> wopen)"
  note "~/.config/direnv/direnvrc"
  echo; printf '%sDry run complete.%s Re-run without --dry-run to apply.\n' "$G$B" "$Z"; exit 0
fi

hdr "back up ~/.zshrc"
if [ -f "$ZSHRC" ]; then backup_file "$ZSHRC"
else warn "no existing ~/.zshrc — a new one will be created"; fi

hdr "append complementary block to ~/.zshrc"
assemble > "$ZSHRC.new" && mv "$ZSHRC.new" "$ZSHRC"
ok "block written (between markers; your existing block left intact)"

hdr "create wopen + xdg-open"
mkdir -p "$HOME/.local/bin"
printf '%s\n' "$WOPEN" > "$HOME/.local/bin/wopen"; chmod +x "$HOME/.local/bin/wopen"
ln -sf "$HOME/.local/bin/wopen" "$HOME/.local/bin/xdg-open"
ok "~/.local/bin/wopen and xdg-open symlink created"

hdr "create direnvrc"
mkdir -p "$HOME/.config/direnv"
printf '%s\n' "$DIRENVRC" > "$HOME/.config/direnv/direnvrc"
ok "~/.config/direnv/direnvrc created"

hdr "done"
printf '%sComplementary block written — nothing applied to your current session yet.%s\n' "$G$B" "$Z"
echo
note "Review:  sed -n '/>>> wsl2-dev-setup/,/<<< wsl2-dev-setup/p' ~/.zshrc"
note "Apply:   exec zsh"
note "Revert:  delete the lines between the wsl2-dev-setup markers (backups: ~/.local/state/wsl2-dev/backups/)"
echo
warn "Behavioral changes from THIS block: node now resolves to Linux (fnm);"
warn "fzf adds/ remaps Ctrl-R, Ctrl-T, Alt-C; history becomes shared across sessions (SHARE_HISTORY)."
note "No alias changes — your ls/cat/ll/gs and keybindings are untouched."
