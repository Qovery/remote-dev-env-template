#!/bin/bash
# entrypoint.sh — Builder Workspace startup script
# Clones a git repo (if configured), installs dependencies, starts code-server.
#
# Environment variables (all optional — set per-builder in Qovery):
#   GIT_REPO_URL    — HTTPS URL of the repo to clone (e.g., https://github.com/org/project.git)
#   GIT_TOKEN       — Personal access token for git auth (secret). Auto-detects provider.
#   GITHUB_TOKEN    — Fallback token if GIT_TOKEN is not set (GitHub only)
#   GIT_BRANCH      — Branch to checkout (default: main)
#   GIT_USER_NAME   — Git author name for commits
#   GIT_USER_EMAIL  — Git author email for commits
set -e

PROJECT_DIR="/home/coder/project"

# ── Clear stale workspace state to prevent webview deserialization crashes ────
rm -rf /home/coder/.local/share/code-server/User/workspaceStorage/*/state.vscdb 2>/dev/null

# ── Detect git provider from URL and return the correct credential username ──
detect_git_username() {
  local url="$1"
  case "$url" in
    *github.com*)    echo "x-access-token" ;;
    *gitlab.com*|*gitlab.*)  echo "oauth2" ;;
    *bitbucket.org*) echo "x-token-auth" ;;
    *)               echo "x-access-token" ;;
  esac
}

# ── Configure git credentials ───────────────────────────────────────────────
TOKEN="${GIT_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ -n "$TOKEN" ]]; then
  GIT_USERNAME=$(detect_git_username "${GIT_REPO_URL:-}")
  git config --global credential.helper \
    '!f() { echo "username='"$GIT_USERNAME"'"; echo "password='"$TOKEN"'"; }; f'
fi

# Git user identity (for commits)
if [[ -n "${GIT_USER_NAME:-}" ]]; then
  git config --global user.name "$GIT_USER_NAME"
fi
if [[ -n "${GIT_USER_EMAIL:-}" ]]; then
  git config --global user.email "$GIT_USER_EMAIL"
fi

# ── Clone or pull project from GIT_REPO_URL ─────────────────────────────────
if [[ -n "${GIT_REPO_URL:-}" ]]; then
  BRANCH="${GIT_BRANCH:-main}"

  if [[ ! -d "$PROJECT_DIR/.git" ]]; then
    # First start — clone the repo
    echo "Cloning $GIT_REPO_URL (branch: $BRANCH)..."
    if git clone --branch "$BRANCH" --single-branch "$GIT_REPO_URL" "$PROJECT_DIR" 2>&1; then
      echo "Clone successful."
    else
      echo "WARNING: Git clone failed. Starting with empty project directory."
    fi
  else
    # Container restart — pull latest changes
    echo "Project already cloned. Pulling latest from $BRANCH..."
    cd "$PROJECT_DIR" && git pull origin "$BRANCH" 2>&1 || echo "WARNING: Git pull failed (non-critical)."
  fi

  # Auto-install dependencies
  if [[ -f "$PROJECT_DIR/package.json" && ! -d "$PROJECT_DIR/node_modules" ]]; then
    echo "Installing Node.js dependencies..."
    cd "$PROJECT_DIR" && npm install 2>&1 || echo "WARNING: npm install failed (non-critical)."
  fi

  if [[ -f "$PROJECT_DIR/requirements.txt" ]]; then
    echo "Installing Python dependencies..."
    cd "$PROJECT_DIR" && pip install --user -r requirements.txt 2>&1 || echo "WARNING: pip install failed (non-critical)."
  fi
fi

# ── Generate WELCOME.md for new builders ─────────────────────────────────────
generate_welcome_md() {
  if [[ ! -f "$PROJECT_DIR/WELCOME.md" ]]; then
    cat > "$PROJECT_DIR/WELCOME.md" << 'WELCOME'
# Welcome to Your Builder Workspace

You're all set to start building! This workspace comes with **Claude Code**, an AI assistant that can write code, create apps, and help you bring ideas to life.

---

## Step 1: Start a conversation with Claude

Look at the **Claude Code panel on the right side** of your screen. You'll see a text box that says _"Describe what to build"_.

Just type what you want and press Enter. Here are some ideas to try:

> Build me a personal portfolio website with a hero section, an about me page, and a contact form. Use a modern dark theme.

> Create a simple todo app where I can add, complete, and delete tasks. Make it look clean and minimal.

> Build a weather dashboard that shows the current weather for any city. Use a free weather API.

---

## Step 2: Preview your app

Once Claude starts building, it will create files and may start a development server. When it does:

1. A **preview panel** will appear showing your app
2. If it doesn't appear automatically, open the terminal (`` Ctrl+` ``) and look for the URL (usually `http://localhost:3000` or similar)
3. You can also use the **Live Preview** extension — click the "Go Live" button in the bottom status bar

---

## Step 3: Iterate and improve

The best way to vibe code is to **iterate**. After Claude builds something:

- Tell it what you like and what to change
- Ask it to add new features
- Be specific: _"Make the header blue"_ works better than _"Make it look better"_

---

## Tips for effective vibe coding

- **Be specific**: _"Add a signup form with email, password, and a submit button"_ beats _"Add a form"_
- **Iterate in small steps**: Ask for one feature at a time rather than everything at once
- **Ask Claude to explain**: If you're curious how something works, just ask!
- **Don't worry about mistakes**: Claude can fix errors — just paste the error message and ask for help

---

## Authentication

If Claude asks you to log in or you see an authentication prompt:

- **With an API key**: Your admin should have set the `ANTHROPIC_API_KEY` environment variable. If not, ask them to configure it.
- **With a login**: Click the login link and sign in with your Anthropic account.

---

Happy building!
WELCOME
    echo "Generated WELCOME.md"
  fi
}

generate_welcome_md

# ── Auto-generate .vscode/tasks.json for dev server auto-start ───────────────
generate_tasks_json() {
  local run_cmd=""

  if [[ -f "$PROJECT_DIR/package.json" ]]; then
    # Detect the best run command from package.json scripts
    if jq -e '.scripts.dev' "$PROJECT_DIR/package.json" >/dev/null 2>&1; then
      run_cmd="npm run dev"
    elif jq -e '.scripts.start' "$PROJECT_DIR/package.json" >/dev/null 2>&1; then
      run_cmd="npm start"
    elif jq -e '.scripts.serve' "$PROJECT_DIR/package.json" >/dev/null 2>&1; then
      run_cmd="npm run serve"
    elif jq -e '.scripts.preview' "$PROJECT_DIR/package.json" >/dev/null 2>&1; then
      run_cmd="npm run preview"
    fi
  elif [[ -f "$PROJECT_DIR/requirements.txt" ]] || [[ -f "$PROJECT_DIR/manage.py" ]]; then
    if [[ -f "$PROJECT_DIR/manage.py" ]]; then
      run_cmd="python3 manage.py runserver 0.0.0.0:3100"
    fi
  fi

  # Only generate tasks.json if we detected a run command and none exists yet
  if [[ -n "$run_cmd" && ! -f "$PROJECT_DIR/.vscode/tasks.json" ]]; then
    mkdir -p "$PROJECT_DIR/.vscode"
    cat > "$PROJECT_DIR/.vscode/tasks.json" << TASKS
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Start Dev Server",
      "type": "shell",
      "command": "${run_cmd}",
      "runOptions": { "runOn": "folderOpen" },
      "isBackground": true,
      "presentation": {
        "reveal": "silent",
        "panel": "dedicated",
        "showReuseMessage": false
      },
      "problemMatcher": []
    }
  ]
}
TASKS
    echo "Auto-configured dev server task: ${run_cmd}"
  fi
}

generate_tasks_json

# ── Start code-server ────────────────────────────────────────────────────────
echo "Starting Builder Workspace..."
exec code-server --host 0.0.0.0 --port 8080 "$PROJECT_DIR"
