# Builder Workspace — All-in-One
# VS Code (code-server) + Claude Code + OpenCode + Codex + RTK
# + GitHub CLI + Qovery CLI + Node.js + Python + Git + Live Preview
#
# Non-tech builders: open the workspace URL → VS Code loads with Claude Code
# in the sidebar → describe what to build → preview results inline.
# Tech builders: open the terminal → run `opencode`, `claude`, or `codex`.
# RTK auto-compresses shell output to reduce LLM token consumption by 60-90%.
#
# Set GIT_REPO_URL + GIT_TOKEN to auto-clone a project on startup.
# Set ANTHROPIC_API_KEY so Claude Code can authenticate automatically.
# Set OPENAI_API_KEY so Codex can authenticate automatically.
FROM codercom/code-server:4.118.0

USER root

# Node.js 22 LTS (must run before the main apt-get so the NodeSource repo is available)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash -

# System dependencies + language runtimes + developer tools (single layer)
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Core utilities
    curl git jq make unzip xz-utils ca-certificates wget tree htop \
    # Python
    python3 python3-pip python3-venv \
    # Ruby + native extension build tools
    ruby ruby-dev build-essential \
    # Node.js (from NodeSource repo above)
    nodejs \
    # Search & navigation
    ripgrep fzf \
    && gem install bundler --no-document \
    && rm -rf /var/lib/apt/lists/*

# Go 1.24
ARG GO_VERSION=1.24.3
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz
ENV PATH="/usr/local/go/bin:/home/coder/go/bin:${PATH}"

# GitHub CLI (pinned + checksum verified)
ARG GH_VERSION=2.74.1
ARG GH_SHA256=d62406233a42e0dc577dcead8d7bafabcc4c548d9c3a6da761c6709bc8f4b373
RUN cd /tmp \
    && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" -o gh.tar.gz \
    && echo "${GH_SHA256}  gh.tar.gz" | sha256sum -c - \
    && tar -xzf gh.tar.gz \
    && install "gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh \
    && rm -rf gh.tar.gz "gh_${GH_VERSION}_linux_amd64"

# Zellij — terminal multiplexer for session persistence across network disconnects
# Each terminal tab gets its own named Zellij session; processes survive browser reconnects.
ARG ZELLIJ_VERSION=0.44.3
ARG ZELLIJ_SHA256=0f7c346788627f506c0a28296517768633cff24fc822a739f8264b640ecad751
RUN cd /tmp \
    && curl -fsSL "https://github.com/zellij-org/zellij/releases/download/v${ZELLIJ_VERSION}/zellij-x86_64-unknown-linux-musl.tar.gz" -o zellij.tar.gz \
    && echo "${ZELLIJ_SHA256}  zellij.tar.gz" | sha256sum -c - \
    && tar -xzf zellij.tar.gz \
    && install -m 755 zellij /usr/local/bin/zellij \
    && rm -rf zellij zellij.tar.gz

# Zellij config — transparent mode (no status bar, no pane frames, no UI chrome)
# default_shell ensures all Zellij panes use bash regardless of $SHELL env var
RUN mkdir -p /etc/zellij \
    && printf 'simplified_ui true\npane_frames false\ndefault_layout "compact"\ndefault_shell "/bin/bash"\n' \
       > /etc/zellij/config.kdl

# Zellij auto-attach — sourced by every interactive bash session
# Wraps each terminal tab in a named Zellij session (rde-shell-N).
# On reconnect after a network drop, reattaches to the same session via PPID lookup.
# Uses printf to write the script (heredoc is unreliable across Docker build environments).
RUN printf '%s\n' \
  '# RDE session persistence via Zellij' \
  '# Transparently wraps each terminal tab in a named session so processes survive' \
  '# network drops. Uses PPID as a stable key — code-server keeps the same parent' \
  '# process for a terminal tab across reconnects.' \
  'if [ -z "${ZELLIJ}" ] && [ -t 1 ]; then' \
  '  _sessions_dir="${HOME}/.rde-sessions"' \
  '  _counter_file="${HOME}/.rde-tab-counter"' \
  '  mkdir -p "${_sessions_dir}"' \
  '  _session_file="${_sessions_dir}/${PPID}"' \
  '  if [ -f "${_session_file}" ]; then' \
  '    _session_name=$(cat "${_session_file}")' \
  '  else' \
  '    (' \
  '      flock -x 9' \
  '      _n=$(cat "${_counter_file}" 2>/dev/null || echo 0)' \
  '      _n=$(( _n + 1 ))' \
  '      echo "${_n}" > "${_counter_file}"' \
  '      echo "rde-shell-${_n}" > "${_session_file}"' \
  '    ) 9>"${_counter_file}.lock"' \
  '    _session_name=$(cat "${_session_file}")' \
  '  fi' \
  '  trap '"'"'rm -f "${_sessions_dir}/${PPID}"'"'"' EXIT' \
  '  export ZELLIJ_CONFIG_FILE=/etc/zellij/config.kdl' \
  '  exec zellij attach --create "${_session_name}"' \
  'fi' \
  > /etc/profile.d/rde-zellij.sh \
  && echo '. /etc/profile.d/rde-zellij.sh' >> /etc/bash.bashrc

# Qovery CLI
RUN curl -s https://get.qovery.com | bash

# AI coding agents (single layer + cache cleanup)
ARG CLAUDE_CODE_VERSION=2.1.129
RUN npm install -g \
    @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
    opencode-ai \
    @openai/codex \
    && npm cache clean --force

# RTK — reduces LLM token consumption by 60-90% on shell commands
RUN curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh \
    && ln -sf /root/.local/bin/rtk /usr/local/bin/rtk

# Patch: disable navigator polyfill that crashes Claude Code extension on Node 22
# The extension host throws PendingMigrationError when extensions access `navigator`.
# This replaces the conditional check with `true` so the polyfill is never installed.
RUN sed -i 's/Xy.supportGlobalNavigator||/true||/' \
    /usr/lib/code-server/lib/vscode/out/vs/workbench/api/node/extensionHostProcess.js

# Configure code-server to use Microsoft VS Code Marketplace
# (required for Claude Code extension, GitHub Copilot, Live Preview, etc.)
# To revert to Open VSX, remove this ENV line.
ENV EXTENSIONS_GALLERY='{"serviceUrl":"https://marketplace.visualstudio.com/_apis/public/gallery","itemUrl":"https://marketplace.visualstudio.com/items","cacheUrl":"https://vscode.blob.core.windows.net/gallery/index","controlUrl":"","recommendationsUrl":""}'

# VS Code extensions (from Microsoft Marketplace)
# Use --user-data-dir to ensure extensions install into coder's data directory
RUN code-server --user-data-dir /home/coder/.local/share/code-server \
      --install-extension anthropic.claude-code 2>/dev/null || true \
    && code-server --user-data-dir /home/coder/.local/share/code-server \
      --install-extension github.copilot 2>/dev/null || true \
    && code-server --user-data-dir /home/coder/.local/share/code-server \
      --install-extension ms-vscode.live-server 2>/dev/null || true \
    && code-server --user-data-dir /home/coder/.local/share/code-server \
      --install-extension ms-python.python 2>/dev/null || true \
    && code-server --user-data-dir /home/coder/.local/share/code-server \
      --install-extension bradlc.vscode-tailwindcss 2>/dev/null || true \
    && code-server --user-data-dir /home/coder/.local/share/code-server \
      --install-extension esbenp.prettier-vscode 2>/dev/null || true

# Resources — skill templates (CLAUDE.md, SKILL.md) and welcome page (welcome.html)
# Copied to /home/coder/project/ at startup by entrypoint.sh (only if not already present)
COPY resources /opt/resources

# Builder Startup extension — auto-opens Claude sidebar + Simple Browser preview
# Must use correct directory naming ({publisher}.{name}-{version}) and register in extensions.json
COPY builder-startup-extension /tmp/builder-startup-extension
RUN mkdir -p /home/coder/.local/share/code-server/extensions/qovery.builder-startup-0.0.1 \
    && cp /tmp/builder-startup-extension/package.json \
          /tmp/builder-startup-extension/extension.js \
          /home/coder/.local/share/code-server/extensions/qovery.builder-startup-0.0.1/ \
    && rm -rf /tmp/builder-startup-extension \
    && jq '. += [{"identifier":{"id":"qovery.builder-startup"},"version":"0.0.1","location":{"$mid":1,"path":"/home/coder/.local/share/code-server/extensions/qovery.builder-startup-0.0.1","scheme":"file"},"relativeLocation":"qovery.builder-startup-0.0.1"}]' \
       /home/coder/.local/share/code-server/extensions/extensions.json > /tmp/ext.json \
    && mv /tmp/ext.json /home/coder/.local/share/code-server/extensions/extensions.json

# Disable code-server's custom Getting Started page
ENV CS_DISABLE_GETTING_STARTED_OVERRIDE=1

# Configure code-server (no auth — Qovery handles access control)
RUN mkdir -p /home/coder/.config/code-server \
    && printf 'bind-addr: 0.0.0.0:8080\nauth: none\ncert: false\napp-name: Builder Workspace\n' \
       > /home/coder/.config/code-server/config.yaml

# Pre-configure VS Code settings for a clean, dark, non-tech-friendly experience
# Uses printf to write JSON (heredoc is unreliable across Docker build environments)
RUN mkdir -p /home/coder/.local/share/code-server/User \
    && printf '%s\n' \
       '{' \
       '  "workbench.startupEditor": "none",' \
       '  "workbench.tips.enabled": false,' \
       '  "workbench.welcomePage.walkthroughs.openOnInstall": false,' \
       '  "workbench.colorTheme": "Default Dark Modern",' \
       '  "workbench.editor.showTabs": "none",' \
       '  "workbench.statusBar.visible": true,' \
       '  "editor.fontSize": 14,' \
       '  "editor.wordWrap": "on",' \
       '  "editor.minimap.enabled": false,' \
       '  "terminal.integrated.defaultProfile.linux": "bash",' \
       '  "terminal.integrated.profiles.linux": {' \
       '    "bash": { "path": "/bin/bash", "args": [] }' \
       '  },' \
       '  "terminal.integrated.fontSize": 14,' \
       '  "extensions.autoUpdate": false,' \
       '  "telemetry.telemetryLevel": "off",' \
       '  "task.allowAutomaticTasks": "on",' \
       '  "livePreview.portNumber": 3100,' \
       '  "livePreview.openPreviewTarget": "internalBrowser",' \
       '  "remote.autoForwardPorts": true,' \
       '  "remote.autoForwardPortsSource": "process",' \
       '  "claudeCode.preferredLocation": "sidebar",' \
       '  "claudeCode.hideOnboarding": true' \
       '}' \
       > /home/coder/.local/share/code-server/User/settings.json

# ── Switch to coder user for all user-space installations ──────────────
# Fix ownership: steps above created dirs under /home/coder as root
RUN chown -R coder:coder /home/coder
USER coder

# Pre-create skill directories (must exist before the skill installer runs)
RUN mkdir -p /home/coder/.config/opencode/skills \
    /home/coder/.config/opencode/commands \
    /home/coder/.claude/skills

# Qovery Skills — installed as coder so OpenCode and Claude Code can discover them
RUN curl -fsSL https://skill.qovery.com/install.sh | bash

# Initialize RTK hooks for Claude Code and OpenCode (auto-rewrite shell commands)
RUN rtk init -g 2>/dev/null || true \
    && rtk init -g --opencode 2>/dev/null || true

# ── Entrypoint: clone git repo (if configured), install deps, start code-server
# Start as root so the entrypoint can fix /home/coder ownership when a volume
# is mounted at /home (the entrypoint drops to the coder user after fixing).
USER root
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /home/coder/project

EXPOSE 8080 9100

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
