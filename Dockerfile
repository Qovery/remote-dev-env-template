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

# Use bash with pipefail for all RUN instructions — pipe failures are caught, not silently ignored
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# NOTE: root is required for system package installation.
# The container drops to `coder` at line ~175 and again the entrypoint handles
# re-dropping after fixing volume ownership at runtime (see entrypoint.sh).
USER root

# Node.js 22 LTS (must run before the main apt-get so the NodeSource repo is available)
# Download setup script to /tmp first — avoids piping remote code directly into bash
RUN curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/nodesource_setup.sh \
    && bash /tmp/nodesource_setup.sh \
    && rm /tmp/nodesource_setup.sh

# System dependencies + language runtimes + developer tools (single layer)
# core utils / python / ruby+build-tools / nodejs (NodeSource) / search tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git jq make unzip xz-utils ca-certificates tree \
    python3 python3-pip python3-venv \
    ruby ruby-dev build-essential \
    nodejs \
    ripgrep fzf \
    && gem install bundler:2.5.23 --no-document \
    && apt-get clean \
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
RUN curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
        -o /tmp/gh.tar.gz \
    && echo "${GH_SHA256}  /tmp/gh.tar.gz" > /tmp/gh.sha256 \
    && sha256sum -c /tmp/gh.sha256 \
    && tar -xzf /tmp/gh.tar.gz -C /tmp \
    && install "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh \
    && rm -rf /tmp/gh.tar.gz /tmp/gh.sha256 "/tmp/gh_${GH_VERSION}_linux_amd64"

# Zellij — terminal multiplexer for session persistence across network disconnects
# Each terminal tab gets its own named Zellij session; processes survive browser reconnects.
ARG ZELLIJ_VERSION=0.44.3
ARG ZELLIJ_SHA256=0f7c346788627f506c0a28296517768633cff24fc822a739f8264b640ecad751
RUN curl -fsSL "https://github.com/zellij-org/zellij/releases/download/v${ZELLIJ_VERSION}/zellij-x86_64-unknown-linux-musl.tar.gz" \
        -o /tmp/zellij.tar.gz \
    && echo "${ZELLIJ_SHA256}  /tmp/zellij.tar.gz" > /tmp/zellij.sha256 \
    && sha256sum -c /tmp/zellij.sha256 \
    && tar -xzf /tmp/zellij.tar.gz -C /tmp \
    && install -m 755 /tmp/zellij /usr/local/bin/zellij \
    && rm -rf /tmp/zellij /tmp/zellij.tar.gz /tmp/zellij.sha256

# Zellij config — transparent mode (no status bar, no pane frames, no UI chrome)
# default_shell ensures all Zellij panes use bash regardless of $SHELL env var
ENV ZELLIJ_CONFIG_FILE=/etc/zellij/config.kdl
RUN mkdir -p /etc/zellij \
    && printf 'simplified_ui true\npane_frames false\ndefault_layout "compact"\ndefault_shell "/bin/bash"\nshow_release_notes false\nshow_startup_tips false\n' \
       > /etc/zellij/config.kdl

# ttyd — web-based terminal server for iframe embedding
ARG TTYD_VERSION=1.7.7
ARG TTYD_SHA256=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55
RUN curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64" \
        -o /usr/local/bin/ttyd \
    && echo "${TTYD_SHA256}  /usr/local/bin/ttyd" > /tmp/ttyd.sha256 \
    && sha256sum -c /tmp/ttyd.sha256 \
    && rm /tmp/ttyd.sha256 \
    && chmod +x /usr/local/bin/ttyd

# Qovery CLI — download install script to /tmp first, don't pipe directly into bash
RUN curl -fsSL https://get.qovery.com -o /tmp/install-qovery.sh \
    && bash /tmp/install-qovery.sh \
    && rm /tmp/install-qovery.sh

# AI coding agents (single layer + cache cleanup)
# Note: `npm install -g` is correct here — `npm ci` is for local project installs only
ARG CLAUDE_CODE_VERSION=2.1.129
RUN npm install -g \
    @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
    opencode-ai \
    @openai/codex \
    && npm cache clean --force

# RTK — reduces LLM token consumption by 60-90% on shell commands
# Download install script to /tmp first, don't pipe directly into sh
RUN curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh \
        -o /tmp/install-rtk.sh \
    && sh /tmp/install-rtk.sh \
    && rm /tmp/install-rtk.sh \
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

# Qovery Skills — download install script to /tmp first, don't pipe directly into bash
RUN curl -fsSL https://skill.qovery.com/install.sh -o /tmp/install-skills.sh \
    && bash /tmp/install-skills.sh \
    && rm /tmp/install-skills.sh

# Initialize RTK hooks for Claude Code and OpenCode (auto-rewrite shell commands)
RUN rtk init -g 2>/dev/null || true \
    && rtk init -g --opencode 2>/dev/null || true

# ── Entrypoint: clone git repo (if configured), install deps, start code-server
# NOTE: root is required so the entrypoint can fix /home/coder ownership when a
# volume is mounted at /home. The entrypoint drops to the coder user after fixing.
USER root
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /home/coder/project

EXPOSE 8080 9100

# Health check: verify code-server is accepting HTTP connections
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8080/ || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
