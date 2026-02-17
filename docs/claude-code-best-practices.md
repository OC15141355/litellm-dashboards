# Claude Code — Best Practices & Getting Started

A guide for developers new to Claude Code. Covers what it is, how it works, and how to get the most out of it.

> **Prerequisites:** Complete the [Claude Code Onboarding Guide](claude-code-onboarding.md) first for setup instructions.

---

## What is Claude Code?

Claude Code is an AI coding assistant from Anthropic that runs in your terminal or VS Code. Unlike ChatGPT or a browser-based AI, it has **direct access to your codebase** — it can:

- Read and search files
- Edit code
- Run terminal commands (with your approval)
- Use git
- Run tests
- Navigate your project structure

Think of it as a junior dev sitting next to you who can read your entire codebase instantly but needs your approval before making changes.

---

## How It Works

### Permission Model

Claude Code operates on a **permission system**. When it wants to:

- **Read files / search code** — does it automatically
- **Edit files** — asks for approval (unless auto-allowed)
- **Run shell commands** — asks for approval (unless auto-allowed)

You always have the final say. Nothing destructive happens without your explicit approval.

### Context Window

Claude Code maintains a conversation context. It remembers what you've discussed in the current session. When the context gets large, older messages are automatically compressed — so you don't need to worry about hitting limits.

### Models

Claude Code uses different model tiers:

| Model | When it's used |
|-------|---------------|
| **Sonnet** | Default for everything — chat, edits, searches |
| **Opus** | Manually selected for complex tasks (`/model` to switch) |
| **Haiku** | Background subtasks (summarisation, quick lookups) |

Use Sonnet for day-to-day work. Switch to Opus for complex refactoring, architecture decisions, or tricky debugging.

---

## Key Files

### CLAUDE.md — Project Instructions

`CLAUDE.md` is a file you place in your repo root. Claude Code reads it automatically at the start of every session. Use it to tell Claude about your project:

```markdown
# CLAUDE.md

## Project Overview
This is our internal API gateway built with Go 1.22.

## Tech Stack
- Go 1.22, Chi router, PostgreSQL 15
- Deployed via Helm to EKS (ap-southeast-2)
- CI/CD: GitHub Actions → ECR → ArgoCD

## Conventions
- Use structured logging (slog)
- All errors must be wrapped with fmt.Errorf("context: %w", err)
- Tests use testify/assert
- Database migrations in migrations/ dir (golang-migrate)

## Commands
- Build: `go build ./cmd/api`
- Test: `go test ./...`
- Lint: `golangci-lint run`

## Important
- NEVER commit .env files
- All secrets are in AWS Secrets Manager
- Run `make lint` before committing
```

**Why this matters:** Without CLAUDE.md, Claude Code has to figure out your project from scratch every session. With it, it starts with full context of your stack, conventions, and workflows. This massively improves output quality.

**Tips:**
- Keep it concise — bullet points, not essays
- Include build/test/lint commands
- List conventions and patterns specific to your codebase
- Mention things it should NOT do (destructive commands, specific files to avoid)
- Nest CLAUDE.md files in subdirectories for module-specific context

### ~/.claude/settings.json — Global Config

Your personal Claude Code config. Applies to every project:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://litellm.yourcompany.com",
    "ANTHROPIC_AUTH_TOKEN": "sk-your-key",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "au.anthropic.claude-sonnet-4-5-20250929-v1:0"
  }
}
```

### Memory

Claude Code can remember things across sessions. If you say "remember that we use bun instead of npm", it saves this to its memory files. Next session, it already knows.

Memory is stored in `~/.claude/` and is personal to your machine — not shared with the team. Use CLAUDE.md for team-wide knowledge, memory for personal preferences.

---

## Best Practices

### 1. Be Specific with Prompts

**Bad:** "Fix the bug"
**Good:** "The /api/users endpoint returns 500 when the email field is missing. Add input validation to return 400 with a descriptive error message."

**Bad:** "Refactor this"
**Good:** "Extract the database connection logic from main.go into a separate db/connection.go package. Keep the same interface."

### 2. Start Small, Build Up

Don't ask Claude Code to rewrite your entire service in one go. Break it down:

1. "Read through the auth middleware and explain how it works"
2. "What would need to change to support JWT refresh tokens?"
3. "Implement the refresh token logic in auth/refresh.go"
4. "Write tests for the refresh token handler"

### 3. Let It Read Before It Writes

Before asking Claude Code to modify code, have it read and understand the existing code first:

- "Read the deployment config and summarise what it does"
- "How does our error handling work in the API layer?"
- "What patterns does our codebase use for database queries?"

This gives it context to make changes that fit your codebase style.

### 4. Review Every Change

Claude Code is powerful but not infallible. Always:

- Review diffs before accepting edits
- Run tests after changes
- Don't blindly approve shell commands you don't understand
- Use `git diff` to check what changed

### 5. Use It for What It's Good At

**Great for:**
- Boilerplate code (CRUD endpoints, tests, configs)
- Reading and explaining unfamiliar code
- Debugging — paste an error, let it investigate
- Writing tests for existing code
- Refactoring with clear requirements
- Generating Terraform/Helm/YAML from descriptions
- Git operations (commit messages, branch management)

**Be cautious with:**
- Complex architectural decisions (use it for input, not as the final word)
- Security-critical code (always review manually)
- Production deployments (read-only kubectl is fine, don't let it apply)

### 6. Use CLAUDE.md Effectively

A good CLAUDE.md saves you repeating context every session. Update it as your project evolves. The best CLAUDE.md files include:

- Build/test/lint commands
- Project structure overview
- Naming conventions and patterns
- What NOT to do
- Key dependencies and their versions

### 7. Non-Destructive Workflow

When using Claude Code in shared environments:

- **Read-only by default** — let it search and read freely, approve writes carefully
- **Branch first** — always work on a feature branch
- **No direct deploys** — don't let it run `kubectl apply`, `terraform apply`, or `helm install` against shared environments
- **Review before commit** — check the diff before letting it commit

---

## Demo: Capabilities Showcase

Here are some non-destructive demos you can try to see what Claude Code can do. These are read-only or local-only — nothing touches shared infrastructure.

### Demo 1: Codebase Explorer

Open Claude Code in any project and ask:

```
Explain the architecture of this project. What are the main components
and how do they interact?
```

It will read through the codebase and give you a structured overview. Great for onboarding to unfamiliar repos.

### Demo 2: Code Review

Point it at a recent PR or diff:

```
Review the changes in the last commit. Look for bugs, security issues,
and suggest improvements.
```

Or for a specific file:

```
Review src/api/handler.go for potential issues — error handling,
edge cases, performance.
```

### Demo 3: Test Generation

Pick a file that needs tests:

```
Read src/utils/validator.go and write comprehensive unit tests for it.
Use the same test patterns as the existing tests in this project.
```

### Demo 4: Documentation

```
Read the src/api/ directory and generate API documentation for all
endpoints, including request/response examples.
```

### Demo 5: Debugging

Paste an error and let it investigate:

```
I'm getting this error in production:

panic: runtime error: invalid memory address or nil pointer dereference
goroutine 1 [running]:
main.handleRequest(0x0, 0xc0000b2000)
    /app/cmd/api/handler.go:45 +0x26

Find the root cause and suggest a fix.
```

### Demo 6: Infrastructure as Code

```
Read our current Helm values.yaml and Dockerfile. Generate a
Terraform module that would deploy this same application to EKS
with an ALB ingress, autoscaling, and a PostgreSQL RDS instance.
```

### Demo 7: Explain and Learn

```
I'm new to this codebase. Walk me through the request lifecycle —
from when an HTTP request hits the server to when the response
is sent back. Include middleware, auth, and database interactions.
```

### Demo 8: Git Operations

```
Look at the git log for the last week. Summarise what the team
has been working on, grouped by feature area.
```

---

## Useful Commands

| Command | What it does |
|---------|-------------|
| `/model` | Switch between Sonnet/Opus |
| `/help` | Show available commands |
| `/clear` | Clear conversation context |
| `/compact` | Compress context to free up space |
| `Ctrl+C` | Cancel current operation |
| `Escape` | Dismiss current suggestion |

---

## Common Gotchas

### "It changed something I didn't want"
Use `git diff` to see exactly what changed. Undo with `git checkout -- file` if needed. This is why we always work on branches.

### "It keeps suggesting the wrong approach"
Be more specific in your prompt. Reference the existing patterns: "Follow the same pattern as src/api/users.go when creating the new endpoint."

### "It's slow on big tasks"
Large context = slower responses. Use `/compact` to compress the conversation, or start a fresh session for a new task.

### "It doesn't know about our internal libraries"
Add them to CLAUDE.md. Describe the library, its API, and link to internal docs if available.

### "It hallucinated a function that doesn't exist"
This happens. Always verify that suggested imports and function calls actually exist in your dependencies. Trust but verify.

---

## Recommended Permission Settings

Claude Code asks for approval before editing files or running commands. You can pre-configure what's allowed to reduce friction while keeping guardrails in place.

### Safe to Auto-Allow

Add these to your project's `.claude/settings.json` (committed to repo) or `~/.claude/settings.json` (personal):

```json
{
  "permissions": {
    "allow": [
      "Read",
      "Glob",
      "Grep",
      "Bash(git status)",
      "Bash(git diff*)",
      "Bash(git log*)",
      "Bash(git branch*)",
      "Bash(go test*)",
      "Bash(npm test*)",
      "Bash(make lint*)",
      "Bash(make test*)",
      "Bash(kubectl get*)",
      "Bash(kubectl describe*)",
      "Bash(kubectl logs*)",
      "Bash(terraform plan*)",
      "Bash(terraform validate*)",
      "Bash(helm template*)"
    ]
  }
}
```

This auto-allows:
- **All read operations** — file reads, searches, glob patterns
- **Git reads** — status, diff, log, branches (not push/commit)
- **Tests and linting** — run freely without prompts
- **Kubernetes reads** — get, describe, logs (not apply/delete/patch)
- **Terraform reads** — plan and validate (not apply/destroy)
- **Helm reads** — template rendering (not install/upgrade)

### Always Require Approval

Never auto-allow these — they should always prompt:

- `kubectl apply/delete/patch` — changes to live clusters
- `terraform apply/destroy` — infrastructure changes
- `git push/commit` — changes to remote repos
- `helm install/upgrade/delete` — release changes
- `rm/mv` — destructive file operations
- Any command with `--force` or `-f` flags

### Project-Level vs Personal

| File | Scope | Committed to Git? |
|------|-------|-------------------|
| `.claude/settings.json` (in repo root) | Everyone on this project | Yes — shared with team |
| `~/.claude/settings.json` | All your projects | No — personal only |

**Recommendation:** Commit a `.claude/settings.json` with read-only auto-allows to each repo. Developers can then add personal preferences in their home directory config.

### Example: DevOps Team Project Settings

For a repo that manages infrastructure, a conservative `.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "Read",
      "Glob",
      "Grep",
      "Bash(git status)",
      "Bash(git diff*)",
      "Bash(git log*)",
      "Bash(kubectl get*)",
      "Bash(kubectl describe*)",
      "Bash(kubectl logs*)",
      "Bash(terraform plan*)",
      "Bash(terraform validate*)",
      "Bash(terraform fmt*)",
      "Bash(aws sts get-caller-identity)"
    ],
    "deny": [
      "Bash(kubectl apply*)",
      "Bash(kubectl delete*)",
      "Bash(terraform apply*)",
      "Bash(terraform destroy*)",
      "Bash(helm install*)",
      "Bash(helm upgrade*)",
      "Bash(rm -rf*)"
    ]
  }
}
```

The `deny` list acts as a hard block — Claude Code won't even ask, it'll refuse. This prevents accidental approval of destructive commands.

---

## Security Reminders

- **Never paste secrets** into Claude Code prompts (API keys, passwords, tokens)
- **Review all shell commands** before approving — understand what they do
- **Don't auto-approve** everything — use selective permissions
- **Prompts are logged** — LiteLLM stores prompts when `store_prompts_in_spend_logs` is enabled. Don't include sensitive information in prompts.
- **Branch protection** — use branch protection rules so Claude Code can't push directly to main
