Good question — and no, the "every secret access = a Hello prompt" framing is the *worst-case* if you wire it up naively (like my `.envrc` calling `op.exe read` on every `cd`). It doesn't have to work that way. Let me confirm the current 1Password behavior so I give you accurate options rather than guess.Helpful that you flagged this — the "every access = a prompt" picture is mostly an artifact of the naive `.envrc` I gave you (calling `op.exe read` on every `cd`), not how 1Password actually works. Here's the real behavior and how to get to roughly "approve once, then work uninterrupted."

**What actually happens.** Authorizing a terminal doesn't authorize one command — it establishes a 10-minute session that automatically refreshes on each use. So within an active terminal you're not re-prompted per secret. Two things make it *feel* like more in your WSL setup, though: a new terminal tab re-authorizes, and — the important one — because WSL uses `op.exe` (the Windows CLI) over interop, on Windows, commands executed in a sub-shell require separate authorization. A direnv `$(op.exe read ...)` is a sub-shell read, so that per-`cd` pattern is exactly what triggers repeated Hello prompts. The fix is to stop resolving secrets per-command.

**The fix: load secrets once per session, not per access.** Once an env var is in a process, it never re-touches 1Password. Two patterns:

- **Wrap the long-running process:** `op run --env-file .env.tpl -- uv run uvicorn api.main:app` → one prompt, and that server holds its env for its whole life. You approve when you start the dev server in the morning, done.
- **Render once at session start:** `op inject -i .env.tpl -o .env` → one prompt, then everything reads the (gitignored) `.env` for the rest of the day with zero further prompts. This is the literal "approve once per day." The tradeoff is that resolved secrets sit in a plaintext file for the session — acceptable if it's gitignored and you don't mind it on disk; delete it on exit if you do.

And **drop the per-`cd` `op.exe read` from `.envrc`** — that line is the whole source of the friction.

**Tune the app's auto-lock too** (Settings → Security). Turn on "Unlock with device," so 1Password auto-unlocks for up to 10 minutes whenever you unlock your PC, and set it to lock on device-lock rather than a short idle timer. Combined with the refreshing 10-minute session, active work rarely re-prompts.

**If you want truly zero prompts** (for headless/agent runs, or if even one prompt per session is too much): use a **vault-scoped, read-only 1Password service account**. The native Linux `op` reads its `OP_SERVICE_ACCOUNT_TOKEN` non-interactively — no Hello ever, and it works cleanly across sub-shells (which `op.exe` doesn't). The honest tradeoff: the token *is* a stored long-lived secret, so you've partly traded away the "nothing on disk" principle — scope it to a single read-only dev vault to limit the blast radius. I'd reserve this for automation/agent workflows and keep biometric for your interactive day-to-day.

**Net recommendation:** for interactive dev, use `op run` (or one `op inject`) at session start plus the auto-lock tuning — you'll approve once when you sit down and then work without interruption. The per-`cd` approach was the design flaw, not 1Password.

Want me to update §8 of the guide to make "load once per session via `op run`/`op inject`" the default pattern, demote the per-`cd` direnv example with a friction warning, and add the service-account option as the zero-prompt alternative?

Good moment to draw this line — before writing any installer, it's worth being explicit about what should be automated and what shouldn't. The dividing principle is simple: **script the deterministic, re-runnable, no-secrets parts; keep manual anything that touches credentials, biometrics, your accounts, a GUI app, the Windows host, or an irreversible change** — because those are exactly the things a script shouldn't silently do on your behalf, and several of them I can't (and shouldn't) do for you anyway.

## At a glance

| Bucket | What goes here | Why |
|---|---|---|
| **Scriptable** (we build, you run) | Deterministic WSL-side installs, config files, helpers | Idempotent, safe to re-run, no secrets |
| **Hybrid** (script prepares, you finish) | Config generation that needs your input/auth/approval | Script does the typing; you own the decision/credential |
| **Manual** (you do, not scripted) | GUI apps, biometrics, account/OAuth, host security, destructive ops | Can't/shouldn't be automated |

## Scriptable — I generate, you run (≈70% of the work)

I'd package these as a few **idempotent** bash scripts (safe to re-run, each backs up what it edits and prints a summary):

- **`10-wsl-base.sh`** — write `/etc/wsl.conf` (systemd, default user, interop, automount); `apt full-upgrade`; install the essential set (`build-essential cmake pkg-config htop tree zip ca-certificates socat bubblewrap`); mask `getty@tty1`. *(Applying `wsl.conf` then needs a `wsl --shutdown` from Windows — that part's manual.)*
- **`20-tooling.sh`** — install **uv** (+ Python 3.12/3.13 + pin), **fnm** (+ Node LTS), **Bun**, **AWS CLI v2**, `starship`/`zoxide`/`direnv`/`bat`/`eza`, and `gitleaks`+`pre-commit` (via `uv tool`). Plus the **non-identity git defaults** (`pull.rebase`, `fetch.prune`, `push.autoSetupRemote`, `rerere`, `diff.algorithm`, `init.defaultBranch`, `core.autocrlf`).
- **`30-shell.sh`** — back up your existing `.zshrc`, then write a managed block (PATH hygiene + dedupe + Windows-Node prune, tool inits, aliases incl. `op`/`open`, `BROWSER`, history); create the **`wopen`** helper + `xdg-open` symlink; write `~/.config/direnv/direnvrc`; drop in the guarded **socat SSH-agent bridge** snippet.
- **`new-project.sh`** — the per-project scaffold: `uv init` with dependency groups, plus templates for `.gitignore`, `.env.example`, `.env.tpl`, `.envrc`, `docker-compose.yml`, `.vscode/settings.json`, `README`, and `pre-commit install` + Playwright system deps.

## Hybrid — script prepares, you supply the missing piece

- **Git identity** — you give me your name/email once; the script sets it (it's currently unset).
- **AWS config** — script pre-writes the `~/.aws/config` `sso-session`/profile blocks from *your* org values; **you** run `aws sso login` (browser).
- **Commit signing** — **you** Copy Snippet from the 1Password app (the path is machine-specific) → paste into `~/.gitconfig`; the script then writes the `allowed_signers` file.
- **Leftover `Ubuntu` distro** — the `wsl --export` safety snapshot is scriptable; **you** run the `wsl --unregister` (destructive) after confirming it's empty.
- **WSL apply/restart/snapshots** — `wsl --shutdown` / `--update` / `--export` run in Windows PowerShell; I can hand you a `.ps1`, but you run it.
- **Memory cap** — you confirm host physical RAM, then set Memory in the WSL Settings app (~24 GB if it's a 32 GB host).

## Manual only — you do these, by design

These involve secrets, biometrics, the Windows host, or your accounts — I won't script or perform them:

- **WSL Settings app** — memory/CPU/swap/NAT/autoMemoryReclaim/sparseVHD (you chose to manage globals here).
- **NVIDIA driver** (Windows / NVIDIA app) — keep it current for Blackwell.
- **Docker Desktop** — confirm WSL integration is enabled for Ubuntu-24.04 (GUI toggle).
- **1Password desktop app** — enable the SSH agent, CLI integration, Windows Hello, and auto-lock ("Unlock with device"); create/import your ed25519 key. **This is your security root — it must be you.**
- **npiperelay.exe** on Windows (winget/scoop) — prerequisite for the socat bridge.
- **GitHub auth** — `gh auth login` (browser OAuth), then upload the SSH **public** key as both a Signing and an Authentication key.
- **Secrets into 1Password** — add your Anthropic/OpenAI keys, DB creds, etc.; create a scoped read-only service-account token if you want the zero-prompt route.
- **Cursor / VS Code** — install on Windows, add the WSL extension, connect, sign in.

## Recommended order (dependencies matter)

1. *(Manual)* WSL Settings app limits → `wsl --shutdown`; NVIDIA driver current; Docker Desktop integration on.
2. *(Script)* `10-wsl-base.sh` → `wsl --shutdown` to apply `wsl.conf`.
3. *(Script)* `20-tooling.sh`, `30-shell.sh` → open a fresh shell.
4. *(Hybrid)* git identity → *(Manual)* 1Password SSH agent + key → *(Hybrid)* commit-signing snippet + `allowed_signers` → *(Manual)* upload pubkey to GitHub + `gh auth login`.
5. *(Manual)* npiperelay.exe → verify the bridge with `ssh-add -l`.
6. *(Hybrid)* AWS config blocks → *(Manual)* `aws sso login` → sanity `aws sts get-caller-identity`.
7. *(Manual)* secrets into 1Password → verify the once-per-session `op inject` flow.
8. *(Hybrid)* export + *(Manual)* unregister the leftover distro.
9. *(Script)* `new-project.sh` → GPU verify (torch `cu128`, `(12,0)`) → *(Manual)* first `wsl --export` snapshot.

## The balance

The split lands at roughly **70% scripted / 30% manual**, and that ratio is deliberate rather than convenient: the scripts absorb the tedious, repeatable, safe-to-re-run setup, while you keep hands-on ownership of everything involving trust, identity, and judgment — your vault, your accounts, your biometrics, the Windows host, and anything you can't undo. Every script will be idempotent, back up what it edits, and print what it did, so you can re-run freely and review before sourcing.

Want me to start building these? I'd suggest `10-wsl-base.sh` first (it's the foundation and the lowest-risk), and I can write them one at a time so you can review each before running.