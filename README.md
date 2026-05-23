# Remote Dev Environment Template

A Docker template for [Qovery Remote Development Environments](https://www.qovery.com/docs/rde/overview) -- browser-based VS Code with built-in AI coding assistants (Claude Code, OpenCode, and Codex), pre-installed language runtimes, and automatic framework detection.

Designed so that any team member -- technical or not -- can spin up an isolated cloud workspace, describe what they want to build in plain English, and have an AI assistant create, run, and preview the application.

## Architecture

```
Browser
  |
  +--[Port 8080] code-server (VS Code in the browser)
  |    |-- Claude Code sidebar (AI chat)
  |    |-- Live Preview panel (port 3100)
  |    |-- Pre-installed extensions (Copilot, Python, Tailwind CSS, Prettier)
  |
  +--[Port 9100] OpenCode web UI (alternative AI coding interface)
  |
  +--[Port 3100] Auto-started dev server (Vite, Next.js, Django, Rails, Go, etc.)
```

## What's Included

### Languages & Runtimes

- **Node.js** 22 LTS
- **Python** 3 (with pip and venv)
- **Ruby** + Bundler
- **Go** 1.24

### AI Assistants

- **Claude Code** -- integrated in the VS Code sidebar
- **OpenCode** -- web UI on port 9100
- **Codex** -- OpenAI's AI coding agent CLI
- **RTK** -- token compression tool that reduces LLM token consumption by 60-90% on shell output

### CLI Tools

- **GitHub CLI** (gh)
- **Qovery CLI**

### Developer Tools

- **ripgrep** (rg) -- fast recursive search
- **fzf** -- fuzzy file finder
- **htop** -- interactive process viewer
- **wget** -- HTTP file downloader
- **tree** -- directory tree visualization

### VS Code Extensions

- Claude Code (`anthropic.claude-code`)
- GitHub Copilot (`github.copilot`)
- Live Server (`ms-vscode.live-server`)
- Python (`ms-python.python`)
- Tailwind CSS IntelliSense (`bradlc.vscode-tailwindcss`)
- Prettier (`esbenp.prettier-vscode`)

### Auto-Detection

The entrypoint automatically detects and starts the appropriate dev server for:

| Framework / Stack | Detection |
|---|---|
| Vite (React, Vue, Svelte) | `vite.config.*` |
| Next.js | `next.config.*` |
| Nuxt | `nuxt.config.*` |
| Node.js (generic) | `package.json` with `dev`, `start`, or `serve` scripts |
| Django | `manage.py` |
| Flask | `app.py` or `wsgi.py` with Flask imports |
| FastAPI | `main.py` with FastAPI imports |
| Ruby on Rails | `bin/rails` |
| Go | `main.go` |
| Static HTML | `index.html` (served with `npx serve`) |

## Quick Start

### Build the image

```bash
docker build -t remote-dev-env .
```

### Run locally

```bash
docker run -p 8080:8080 -p 3100:3100 -p 9100:9100 \
  -e ANTHROPIC_API_KEY=your-key \
  -e OPENAI_API_KEY=your-key \
  remote-dev-env
```

Open `http://localhost:8080` to access VS Code in the browser.

### Run with a Git repository

```bash
docker run -p 8080:8080 -p 3100:3100 -p 9100:9100 \
  -e ANTHROPIC_API_KEY=your-key \
  -e OPENAI_API_KEY=your-key \
  -e GIT_REPO_URL=https://github.com/your-org/your-repo.git \
  -e GIT_TOKEN=your-git-token \
  -e GIT_BRANCH=main \
  remote-dev-env
```

### Deploy on Qovery

This template is designed to be used as a **blueprint** in the [Qovery RDE Portal](https://www.qovery.com/docs/rde/overview). See the [Admin Setup guide](https://www.qovery.com/docs/rde/getting-started/admin-setup) for instructions on registering this as a blueprint environment.

## Environment Variables

| Variable | Description | Default |
|---|---|---|
| `GIT_REPO_URL` | HTTPS URL of the repository to clone | -- |
| `GIT_TOKEN` | Git personal access token | -- |
| `GITHUB_TOKEN` | Fallback GitHub token (used if `GIT_TOKEN` is not set) | -- |
| `GIT_BRANCH` | Branch to checkout | `main` |
| `GIT_USER_NAME` | Git author name for commits | -- |
| `GIT_USER_EMAIL` | Git author email for commits | -- |
| `DEV_PORT` | Port for the auto-started dev server | `3100` |
| `OPENCODE_PORT` | Port for the OpenCode web UI | `9100` |
| `DISABLE_CODE_SERVER` | Skip code-server and serve a static welcome page instead | `false` |
| `ANTHROPIC_API_KEY` | API key for Claude Code | -- |
| `OPENAI_API_KEY` | API key for Codex | -- |

## How It Works

The `entrypoint.sh` orchestrates the full startup sequence:

1. **Permission setup** -- fixes `/home/coder` ownership when volumes are mounted, then drops from root to the `coder` user
2. **Git configuration** -- auto-detects the git provider (GitHub, GitLab, Bitbucket) and configures credentials
3. **Repository clone** -- clones (or pulls on restart) the repo specified by `GIT_REPO_URL`
4. **Dependency installation** -- runs `npm install`, `pip install`, `bundle install`, or `go mod download` based on what's detected
5. **AI skill setup** -- copies Claude Code instructions (`CLAUDE.md`) and OpenCode skill files into the workspace
6. **Dev server startup** -- detects the framework and starts the appropriate dev server on `DEV_PORT`
7. **code-server launch** -- starts the browser-based VS Code on port 8080

For fresh workspaces (no `GIT_REPO_URL`), a `WELCOME.md` guide is generated with step-by-step instructions and example prompts.

## Customization

### Adding VS Code extensions

Add more extensions to the `Dockerfile`:

```dockerfile
RUN code-server --install-extension publisher.extension-name
```

### Changing AI assistant behavior

Edit the instruction files in `builder-skill/`:

- `builder-skill/CLAUDE.md` -- instructions for Claude Code
- `builder-skill/SKILL.md` -- instructions for OpenCode

These are copied into the workspace at startup and guide how the AI assistants interact with users.

### Changing the default tech stack

The default stack for new projects is **Vite + React + Tailwind CSS** (configured in the skill files). Edit `builder-skill/CLAUDE.md` and `builder-skill/SKILL.md` to change this.

## Project Structure

```
├── Dockerfile                          # Container image definition
├── entrypoint.sh                       # Startup orchestrator (permission setup, git,
│                                       #   dependency install, dev server, code-server)
├── builder-skill/
│   ├── CLAUDE.md                       # AI instructions for Claude Code
│   └── SKILL.md                        # AI instructions for OpenCode
└── builder-startup-extension/
    ├── package.json                    # VS Code extension manifest
    └── extension.js                    # Auto-opens Claude sidebar + WELCOME.md on startup
```

## Ports

| Port | Service |
|---|---|
| 8080 | code-server (VS Code) or RDE welcome page |
| 9100 | OpenCode web UI |
| 3100 | Dev server (configurable via `DEV_PORT`) |

## Learn More

- [Qovery RDE Overview](https://www.qovery.com/docs/rde/overview) -- what Remote Dev Environments are and why they exist
- [Admin Setup](https://www.qovery.com/docs/rde/getting-started/admin-setup) -- configure the portal and register blueprints
- [Create Your First Workspace](https://www.qovery.com/docs/rde/getting-started/create-your-first-workspace) -- spin up a workspace in minutes
- [Security & Data Residency](https://www.qovery.com/docs/rde/reference/security) -- how RDE keeps your data on your infrastructure
- [CLI-Based RDE](https://www.qovery.com/docs/getting-started/guides/use-cases/remote-development-environments) -- manage RDEs via `qovery rde` commands
- [Qovery Pricing](https://www.qovery.com/pricing) -- RDE Portal requires a Business or Enterprise plan
