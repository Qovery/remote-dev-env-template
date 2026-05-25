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
#   OPENCODE_DEFAULT_MODEL — Default model for OpenCode (e.g. anthropic/claude-sonnet-4-6)
#   GIT_ROOT_PATH   — Subdirectory within the repo where the app lives (default: /).
#                      Useful for monorepos where the app is not at the repo root.
#   PRE_START_SCRIPT — Optional shell script to run before the main process starts.
#                      Runs inline (synchronously). Use & for long-running processes (e.g., web servers).
#                      Output is logged to /tmp/pre-start-script.log.
set -e

PROJECT_DIR="/home/coder/project"
DEV_PORT="${DEV_PORT:-3100}"
OPENCODE_PORT="${OPENCODE_PORT:-9100}"
GIT_ROOT_PATH="${GIT_ROOT_PATH:-/}"

# Derive the effective app directory (for monorepos where the app is in a subdirectory)
_root_path="${GIT_ROOT_PATH#/}"    # strip leading slash
_root_path="${_root_path%/}"        # strip trailing slash
if [[ -n "$_root_path" ]]; then
  APP_DIR="$PROJECT_DIR/$_root_path"
else
  APP_DIR="$PROJECT_DIR"
fi

# ── Fix /home/coder ownership when a volume is mounted at /home ──────────────
# Volume mounts override build-time ownership, leaving /home/coder owned by root.
# We start as root, fix permissions, then re-exec as the coder user.
if [[ "$(id -u)" -eq 0 ]]; then
  mkdir -p /home/coder/.local/share/code-server/User \
           /home/coder/.config/code-server \
           /home/coder/.config/opencode \
           /home/coder/project

  # Regenerate code-server config if wiped by volume mount (no auth — Qovery handles access control)
  if [[ ! -f /home/coder/.config/code-server/config.yaml ]]; then
    printf 'bind-addr: 0.0.0.0:8080\nauth: none\ncert: false\napp-name: Builder Workspace\n' \
      > /home/coder/.config/code-server/config.yaml
  fi

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

  # Auto-install dependencies (uses APP_DIR — respects GIT_ROOT_PATH for monorepos)
  if [[ -f "$APP_DIR/package.json" && ! -d "$APP_DIR/node_modules" ]]; then
    echo "Installing Node.js dependencies..."
    cd "$APP_DIR" && npm install 2>&1 || echo "WARNING: npm install failed (non-critical)."
  fi

  if [[ -f "$APP_DIR/requirements.txt" ]]; then
    echo "Installing Python dependencies..."
    cd "$APP_DIR" && pip install --user -r requirements.txt 2>&1 || echo "WARNING: pip install failed (non-critical)."
  fi

  # Ensure uvicorn is available for FastAPI projects
  if [[ -f "$APP_DIR/main.py" ]] && grep -qiE 'from fastapi|import fastapi' "$APP_DIR/main.py" 2>/dev/null; then
    if ! command -v uvicorn &>/dev/null; then
      echo "Installing uvicorn for FastAPI..."
      pip install --user uvicorn 2>&1 || echo "WARNING: uvicorn install failed (non-critical)."
    fi
  fi

  # Ruby/Rails dependencies
  if [[ -f "$APP_DIR/Gemfile" ]]; then
    echo "Installing Ruby dependencies..."
    cd "$APP_DIR" && bundle install 2>&1 || echo "WARNING: bundle install failed (non-critical)."
  fi

  # Go modules
  if [[ -f "$APP_DIR/go.mod" ]]; then
    echo "Downloading Go modules..."
    cd "$APP_DIR" && go mod download 2>&1 || echo "WARNING: go mod download failed (non-critical)."
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

# ── Generate OpenCode provider configuration ─────────────────────────────────
generate_opencode_config() {
  local config_dir="/home/coder/.config/opencode"
  local config_file="$config_dir/opencode.json"

  # Skip if config already exists (user may have customized it)
  if [[ -f "$config_file" ]]; then
    echo "OpenCode config already exists, skipping generation."
    return
  fi

  mkdir -p "$config_dir"

  local model=""

  # Priority 1: Explicit default model from blueprint settings
  if [[ -n "${OPENCODE_DEFAULT_MODEL:-}" ]]; then
    model="$OPENCODE_DEFAULT_MODEL"
  # Priority 2: Derive from BLUEPRINT_AI_PROVIDERS JSON
  elif [[ -n "${BLUEPRINT_AI_PROVIDERS:-}" ]] && echo "$BLUEPRINT_AI_PROVIDERS" | jq empty 2>/dev/null; then
    # Find the first enabled provider with a model
    local provider_name
    local provider_model
    provider_name=$(echo "$BLUEPRINT_AI_PROVIDERS" | jq -r '[.[] | select(.enabled == true and .model != "")] | .[0].provider // empty')
    provider_model=$(echo "$BLUEPRINT_AI_PROVIDERS" | jq -r '[.[] | select(.enabled == true and .model != "")] | .[0].model // empty')
    if [[ -n "$provider_name" && -n "$provider_model" ]]; then
      if [[ "$provider_name" == "custom" ]]; then
        # "custom-llm" is the provider ID used in opencode.json — must match the frontend
        model="custom-llm/$provider_model"
      else
        model="$provider_name/$provider_model"
      fi
    fi
  # Priority 3: Detect from individual env vars
  elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    model="anthropic/claude-sonnet-4-6"
  elif [[ -n "${OPENAI_API_KEY:-}" ]]; then
    model="openai/gpt-4o"
  fi

  if [[ -z "$model" ]]; then
    echo "No AI provider detected — skipping OpenCode config generation."
    return
  fi

  # Check if custom provider needs configuration
  local needs_custom=false
  if [[ -n "${CUSTOM_LLM_API_KEY:-}" && -n "${CUSTOM_LLM_BASE_URL:-}" ]]; then
    needs_custom=true
  fi

  # Extract the custom model name (part after the slash) for the models map
  local custom_model_id=""
  if [[ "$needs_custom" == "true" ]]; then
    # Get model name from BLUEPRINT_AI_PROVIDERS if available
    if [[ -n "${BLUEPRINT_AI_PROVIDERS:-}" ]]; then
      custom_model_id=$(echo "$BLUEPRINT_AI_PROVIDERS" | jq -r '[.[] | select(.provider == "custom" and .enabled == true)] | .[0].model // empty')
    fi
    # Fallback: extract from the model string if it starts with custom-llm/
    if [[ -z "$custom_model_id" && "$model" == custom-llm/* ]]; then
      custom_model_id="${model#custom-llm/}"
    fi
  fi

  # Build the config JSON
  if [[ "$needs_custom" == "true" && -n "$custom_model_id" ]]; then
    jq -n \
      --arg schema "https://opencode.ai/config.json" \
      --arg model "$model" \
      --arg baseURL "$CUSTOM_LLM_BASE_URL" \
      --arg modelId "$custom_model_id" \
      '{
        "$schema": $schema,
        "model": $model,
        "autoupdate": false,
        "provider": {
          "custom-llm": {
            "npm": "@ai-sdk/openai-compatible",
            "name": "Custom LLM",
            "options": {
              "baseURL": $baseURL,
              "apiKey": "{env:CUSTOM_LLM_API_KEY}"
            },
            "models": {
              ($modelId): {
                "name": $modelId
              }
            }
          }
        }
      }' > "$config_file"
  else
    jq -n \
      --arg schema "https://opencode.ai/config.json" \
      --arg model "$model" \
      '{
        "$schema": $schema,
        "model": $model,
        "autoupdate": false
      }' > "$config_file"
  fi

  echo "Generated OpenCode config: model=$model (config: $config_file)"
}

generate_opencode_config

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

  cd "$APP_DIR"

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
  cd "$APP_DIR"
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

# ── Start persistent Zellij session for Claude CLI ───────────────────────────
# Starts the rde-claude session (detached) running the claude CLI before
# code-server launches. The session persists across network disconnects.
# Shell tab sessions (rde-shell-N) are created lazily via /etc/profile.d/rde-zellij.sh.
start_zellij_sessions() {
  mkdir -p /home/coder/.rde-sessions

  # Only start rde-claude if it doesn't already exist (idempotent on container restart)
  if ! ZELLIJ_CONFIG_FILE=/etc/zellij/config.kdl zellij list-sessions 2>/dev/null | grep -q "^rde-claude"; then
    ZELLIJ_CONFIG_FILE=/etc/zellij/config.kdl \
      zellij --session rde-claude -- bash -c 'claude' \
      > /tmp/zellij-claude.log 2>&1 &
    echo "Started Zellij session: rde-claude (claude CLI)"
  else
    echo "Zellij session rde-claude already exists — skipping."
  fi
}

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

  # Start persistent Zellij sessions
  start_zellij_sessions

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

  # Start persistent Zellij sessions
  start_zellij_sessions

  echo "Starting Builder Workspace..."
  exec code-server --host 0.0.0.0 --port 8080 "$PROJECT_DIR"
fi
