---
name: new-project
description: Scaffold a new project via Q&A — interviews for profile, kind, and options, then drives new-project.sh. Use when the user wants to start, create, or scaffold a new project, repo, or experiment in this WSL2 environment.
---

# new-project — Q&A scaffolding

Interview the user, then run the scaffold script. Never guess answers; ask.

## 1. Interview (AskUserQuestion, one round)

Ask these together:
- **Profile** — where does it live? `work` / `personal` / `imperial` (decides git identity,
  signing key, and GitHub account — the directory does this automatically).
- **Kind** — `ML research` (torch cu130 + HF stack + trackio + notebooks) /
  `general Python` (torch optional) / `automation & web` (Playwright-focused).
- **Name** — if not already given in the request.
- **GitHub MCP** — should Claude sessions in this project get the GitHub MCP server
  wired with the profile's 1Password-backed PAT? (yes for repos you'll drive with agents)

Skip anything the user already stated. Defaults: python 3.13, cuda cu130.

## 2. Compose the command

The scaffold script lives at `~/projects/personal/agentic-wsl/agentic-wsl/new-project.sh`.
Map answers to flags:

| Answer | Flags |
|--------|-------|
| ML research | `--ml` |
| general Python | *(none — plain torch scaffold)*, add `--no-torch` if user says no GPU work |
| automation & web | `--no-torch` (keeps Playwright) |
| GitHub MCP yes | `--github-mcp --mcp-token-ref "op://Private/github-mcp-<profile>/credential"` |

## 3. Run it

```bash
cd ~/projects/<profile> && ~/projects/personal/agentic-wsl/agentic-wsl/new-project.sh <name> <flags>
```

Run it live (it downloads packages and verifies the GPU — takes minutes for torch).
Do NOT use --dry-run unless the user asked for a preview.

## 4. Report

Summarize: where it was created, what the GPU verification printed (torch version,
sm_120 line), and remind the user the first commit will be signed + Verified.
If the GPU check failed, show its output and diagnose before finishing.
