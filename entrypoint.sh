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
#   DEV_PORT        — Port for the auto-started dev server (default: 3100)
#   OPENCODE_PORT   — Port for the OpenCode web UI (default: 9100)
#   DISABLE_CODE_SERVER — Set to "true" to skip code-server and serve an RDE welcome page instead
#   OPENAI_API_KEY  — API key for Codex (OpenAI's AI coding agent)
#   PRE_START_SCRIPT — Optional shell script to run before the main process starts.
#                      Runs inline (synchronously). Use & for long-running processes (e.g., web servers).
#                      Output is logged to /tmp/pre-start-script.log.
set -e

PROJECT_DIR="/home/coder/project"
DEV_PORT="${DEV_PORT:-3100}"
OPENCODE_PORT="${OPENCODE_PORT:-9100}"

# ── Fix /home/coder ownership when a volume is mounted at /home ──────────────
# Volume mounts override build-time ownership, leaving /home/coder owned by root.
# We start as root, fix permissions, then re-exec as the coder user.
if [[ "$(id -u)" -eq 0 ]]; then
  mkdir -p /home/coder/.local/share/code-server/User \
           /home/coder/.config/code-server \
           /home/coder/.config/opencode \
           /home/coder/project
  chown -R coder:coder /home/coder
  # Re-execute this script as coder, preserving all env vars (-p)
  # Set HOME explicitly — su -p preserves the root HOME otherwise
  export HOME=/home/coder
  exec su -p -s /bin/bash coder -- "$0" "$@"
fi

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

  # Ensure uvicorn is available for FastAPI projects
  if [[ -f "$PROJECT_DIR/main.py" ]] && grep -qiE 'from fastapi|import fastapi' "$PROJECT_DIR/main.py" 2>/dev/null; then
    if ! command -v uvicorn &>/dev/null; then
      echo "Installing uvicorn for FastAPI..."
      pip install --user uvicorn 2>&1 || echo "WARNING: uvicorn install failed (non-critical)."
    fi
  fi

  # Ruby/Rails dependencies
  if [[ -f "$PROJECT_DIR/Gemfile" ]]; then
    echo "Installing Ruby dependencies..."
    cd "$PROJECT_DIR" && bundle install 2>&1 || echo "WARNING: bundle install failed (non-critical)."
  fi

  # Go modules
  if [[ -f "$PROJECT_DIR/go.mod" ]]; then
    echo "Downloading Go modules..."
    cd "$PROJECT_DIR" && go mod download 2>&1 || echo "WARNING: go mod download failed (non-critical)."
  fi
fi

# ── Generate WELCOME.md for new builders ─────────────────────────────────────
generate_welcome_md() {
  if [[ ! -f "$PROJECT_DIR/WELCOME.md" ]]; then
    if [[ -f /opt/resources/WELCOME.md ]]; then
      cp /opt/resources/WELCOME.md "$PROJECT_DIR/WELCOME.md"
      echo "Generated WELCOME.md"
    fi
  fi
}

# WELCOME.md is only useful for fresh workspaces (no existing project)
if [[ -z "${GIT_REPO_URL:-}" ]]; then
  generate_welcome_md
fi

# ── Generate CLAUDE.md for Claude Code (sidebar + terminal) ──────────────────
generate_claude_md() {
  if [[ ! -f "$PROJECT_DIR/CLAUDE.md" ]]; then
    if [[ -f /opt/resources/CLAUDE.md ]]; then
      cp /opt/resources/CLAUDE.md "$PROJECT_DIR/CLAUDE.md"
      echo "Generated CLAUDE.md (Claude Code instructions)"
    fi
  fi
}

generate_claude_md

# ── Generate OpenCode skill for builder workspace ────────────────────────────
generate_opencode_skill() {
  local skill_dir="$PROJECT_DIR/.opencode/skills/builder-workspace"
  if [[ ! -f "$skill_dir/SKILL.md" ]]; then
    if [[ -f /opt/resources/SKILL.md ]]; then
      mkdir -p "$skill_dir"
      cp /opt/resources/SKILL.md "$skill_dir/SKILL.md"
      echo "Generated OpenCode builder-workspace skill"
    fi
  fi
}

generate_opencode_skill

# ── Execute optional PRE_START_SCRIPT ─────────────────────────────────────────
# Runs inline (synchronously) so setup commands complete before the entrypoint
# continues. For long-running processes (web servers, watchers), add & in the
# script to background them.
if [[ -n "${PRE_START_SCRIPT:-}" ]]; then
  echo "Executing PRE_START_SCRIPT..."
  local_script="/tmp/pre-start-script.sh"
  printf '%s\n' "$PRE_START_SCRIPT" > "$local_script"
  chmod +x "$local_script"
  bash "$local_script" >> /tmp/pre-start-script.log 2>&1
  echo "PRE_START_SCRIPT completed (log: /tmp/pre-start-script.log)"
fi

# ── Auto-detect app type and start dev server with hot-reload ─────────────────
detect_and_start_devserver() {
  if [[ -z "${GIT_REPO_URL:-}" ]]; then
    return
  fi

  local dev_cmd=""
  local app_type=""

  cd "$PROJECT_DIR"

  # ── Priority-ordered framework detection ──
  # Specific framework configs take priority over generic package.json scripts,
  # because we can pass explicit --host and --port flags to them.

  # 1. Vite (React, Vue, Svelte, etc.)
  if compgen -G "vite.config.*" >/dev/null 2>&1; then
    app_type="Vite"
    dev_cmd="npx vite --host 0.0.0.0 --port $DEV_PORT"

  # 2. Next.js
  elif compgen -G "next.config.*" >/dev/null 2>&1; then
    app_type="Next.js"
    dev_cmd="npx next dev --hostname 0.0.0.0 --port $DEV_PORT"

  # 3. Nuxt
  elif compgen -G "nuxt.config.*" >/dev/null 2>&1; then
    app_type="Nuxt"
    dev_cmd="npx nuxt dev --host 0.0.0.0 --port $DEV_PORT"

  # 4. Node.js — generic package.json scripts (dev > start > serve)
  elif [[ -f package.json ]]; then
    if jq -e '.scripts.dev' package.json >/dev/null 2>&1; then
      app_type="Node.js (npm run dev)"
      dev_cmd="npm run dev"
    elif jq -e '.scripts.start' package.json >/dev/null 2>&1; then
      app_type="Node.js (npm start)"
      dev_cmd="npm start"
    elif jq -e '.scripts.serve' package.json >/dev/null 2>&1; then
      app_type="Node.js (npm run serve)"
      dev_cmd="npm run serve"
    fi

  # 5. Django
  elif [[ -f manage.py ]]; then
    app_type="Django"
    dev_cmd="python3 manage.py runserver 0.0.0.0:$DEV_PORT"

  # 6. Flask
  elif [[ -f app.py ]] && grep -qiE 'from flask|import flask' app.py 2>/dev/null; then
    app_type="Flask"
    dev_cmd="flask run --host 0.0.0.0 --port $DEV_PORT --reload"

  elif [[ -f wsgi.py ]] && grep -qiE 'from flask|import flask' wsgi.py 2>/dev/null; then
    app_type="Flask"
    dev_cmd="FLASK_APP=wsgi.py flask run --host 0.0.0.0 --port $DEV_PORT --reload"

  # 7. FastAPI
  elif [[ -f main.py ]] && grep -qiE 'from fastapi|import fastapi' main.py 2>/dev/null; then
    app_type="FastAPI"
    dev_cmd="uvicorn main:app --host 0.0.0.0 --port $DEV_PORT --reload"

  # 8. Ruby on Rails
  elif [[ -f Gemfile ]] && grep -q 'rails' Gemfile 2>/dev/null; then
    app_type="Ruby on Rails"
    dev_cmd="bundle exec rails server -b 0.0.0.0 -p $DEV_PORT"

  # 9. Go
  elif [[ -f go.mod ]]; then
    app_type="Go"
    dev_cmd="go run ."

  # 10. Static HTML (fallback — serve with npx serve)
  elif [[ -f index.html ]]; then
    app_type="Static HTML"
    dev_cmd="npx serve -l $DEV_PORT"
  fi

  if [[ -z "$dev_cmd" ]]; then
    echo "No dev server detected — skipping auto-start."
    return
  fi

  echo "Detected $app_type project. Starting dev server on port $DEV_PORT..."
  echo "Command: $dev_cmd"

  # Set common port env vars that many frameworks respect (for npm script cases)
  export PORT="$DEV_PORT"

  # Start dev server in background with output logged to file
  cd "$PROJECT_DIR"
  nohup bash -c "$dev_cmd" > /tmp/devserver.log 2>&1 &
  local pid=$!
  echo "$pid" > /tmp/devserver.pid
  echo "$app_type" > /tmp/devserver.type
  echo "Dev server started (PID: $pid, log: /tmp/devserver.log)"
}

detect_and_start_devserver

# ── Auto-generate .vscode/tasks.json for dev server auto-start ───────────────
# Only used for fresh workspaces (no GIT_REPO_URL) — cloned repos use the
# background dev server started above instead.
generate_tasks_json() {
  local run_cmd=""

  if [[ -f "$PROJECT_DIR/package.json" ]]; then
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
      run_cmd="python3 manage.py runserver 0.0.0.0:$DEV_PORT"
    fi
  fi

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

if [[ -z "${GIT_REPO_URL:-}" ]]; then
  generate_tasks_json
fi

# ── Ensure injected files are git-ignored in cloned repos ────────────────────
ensure_gitignore() {
  if [[ -z "${GIT_REPO_URL:-}" ]]; then
    return
  fi

  local gitignore="$PROJECT_DIR/.gitignore"
  local header="# Builder Workspace — auto-generated files"
  local entries=(
    "CLAUDE.md"
    ".opencode/"
    ".vscode/tasks.json"
  )

  # Create .gitignore if it doesn't exist
  touch "$gitignore"

  # Add comment header if not already present
  if ! grep -qxF "$header" "$gitignore"; then
    # Add a blank line separator if file is non-empty
    if [[ -s "$gitignore" ]]; then
      echo "" >> "$gitignore"
    fi
    echo "$header" >> "$gitignore"
  fi

  # Add each entry if not already present
  for entry in "${entries[@]}"; do
    if ! grep -qxF "$entry" "$gitignore"; then
      echo "$entry" >> "$gitignore"
    fi
  done
}

ensure_gitignore

# ── RDE welcome page (served when code-server is disabled) ───────────────────
start_welcome_server() {
  local rde_dir="/tmp/rde-welcome"
  mkdir -p "$rde_dir"

  # Read dev server metadata (written by detect_and_start_devserver)
  local ds_type="" ds_pid="" ds_status="" ds_status_color=""
  if [[ -f /tmp/devserver.type ]]; then
    ds_type=$(cat /tmp/devserver.type)
  fi
  if [[ -f /tmp/devserver.pid ]]; then
    ds_pid=$(cat /tmp/devserver.pid)
    if kill -0 "$ds_pid" 2>/dev/null; then
      ds_status="Running (PID $ds_pid)"
      ds_status_color="#4ade80"
    else
      ds_status="Exited (PID $ds_pid)"
      ds_status_color="#f87171"
    fi
  fi

  # Copy the HTML template from resources and inject dynamic dev server info
  cp /opt/resources/welcome.html "$rde_dir/index.html"

  local dev_server_html=""
  if [[ -n "$ds_type" ]]; then
    dev_server_html="    <div class=\"row\"><span class=\"label\">Type</span><span class=\"value\">${ds_type}</span></div>\n"
    dev_server_html+="    <div class=\"row\"><span class=\"label\">Port</span><span class=\"value\">${DEV_PORT}</span></div>\n"
    dev_server_html+="    <div class=\"row\"><span class=\"label\">Status</span><span class=\"value\"><span class=\"status-dot\" style=\"background:${ds_status_color}\"></span>${ds_status}</span></div>\n"
    dev_server_html+="    <div class=\"row\"><span class=\"label\">Log</span><span class=\"value\">/tmp/devserver.log</span></div>"
  else
    dev_server_html="    <p class=\"no-server\">This is the preview of your workspace. Start a web server in your project and it will appear here. You can also change the preview URL in the navigation bar above.</p>"
  fi

  sed -i "s|<!-- DEV_SERVER_INFO -->|${dev_server_html}|" "$rde_dir/index.html"

  # ── Start OpenCode web UI ───────────────────────────────────────────────────
  echo "Starting OpenCode web UI on port ${OPENCODE_PORT}..."
  (cd "$PROJECT_DIR" && opencode web --port "${OPENCODE_PORT}" >> /tmp/opencode-web.log 2>&1) &

  echo "Code-server disabled (DISABLE_CODE_SERVER=true)."
  echo "Serving RDE welcome page on port 8080..."
  cd "$rde_dir"
  exec python3 -m http.server 8080 --bind 0.0.0.0
}

# ── Start code-server (or RDE welcome page in headless mode) ─────────────────
if [[ "${DISABLE_CODE_SERVER:-}" == "true" ]]; then
  start_welcome_server
else
  # ── Start OpenCode web UI ───────────────────────────────────────────────────
  echo "Starting OpenCode web UI on port ${OPENCODE_PORT}..."
  (cd "$PROJECT_DIR" && opencode web --port "${OPENCODE_PORT}" >> /tmp/opencode-web.log 2>&1) &

  echo "Starting Builder Workspace..."
  exec code-server --host 0.0.0.0 --port 8080 "$PROJECT_DIR"
fi
