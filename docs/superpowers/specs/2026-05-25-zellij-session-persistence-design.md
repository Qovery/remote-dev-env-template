# Zellij Session Persistence Design

**Date:** 2026-05-25
**Repos:** `remote-dev-env-template` (base), `remote-dev-env-template-tmr` (Tomorro fork)

---

## Problem

When a user's browser disconnects from code-server (network drop, page refresh, laptop sleep), all terminal processes are killed. Claude Code CLI sessions and bash work in progress are lost. Reconnecting starts fresh with no history.

## Goal

Wrap every terminal session in a Zellij session so that processes survive disconnects. The experience must be **transparent** — users see a normal terminal, not a multiplexer UI.

---

## Design

### Approach: Entrypoint-started sessions + auto-attach in `.bashrc`

`entrypoint.sh` starts the `rde-claude` named Zellij session before launching `code-server`. Shell sessions are created lazily — one per code-server terminal tab — each with a unique name derived from an incrementing counter.

| Session name | Purpose |
|---|---|
| `rde-claude` | Runs the `claude` CLI (started at container boot) |
| `rde-shell-<N>` | One per interactive terminal tab opened by the user |

### Session naming for bash tabs

Each new code-server terminal tab launches a fresh bash shell. The `/etc/profile.d/rde-zellij.sh` logic:

1. Check if already inside Zellij (`$ZELLIJ` env var is set) → if yes, skip (avoids nesting)
2. Check if `~/.rde-sessions/<PPID>` exists → if yes, reattach to that session name (network reconnect case)
3. Otherwise: atomically increment `~/.rde-tab-counter` (via `flock`), assign `rde-shell-<N>`, write to `~/.rde-sessions/<PPID>`, start new Zellij session

On clean shell exit, `trap` removes `~/.rde-sessions/<PPID>` to prevent stale entries.

**Why PPID?** code-server keeps the same parent process for a terminal tab across reconnects. When a network drop occurs and the user reconnects, the shell is respawned under the same PPID — giving us a stable lookup key without any browser-side tab ID.

### Network reconnect flow

```
User opens tab → bash starts → /etc/profile.d/rde-zellij.sh runs
  → $ZELLIJ not set, terminal is interactive
  → no ~/.rde-sessions/<PPID> entry
  → flock → counter++ → assign rde-shell-3
  → write ~/.rde-sessions/<PPID> = rde-shell-3
  → exec: zellij attach --create rde-shell-3
  → user works normally inside transparent Zellij session

Network drops → tab reconnects → bash respawns under same PPID
  → /etc/profile.d/rde-zellij.sh runs
  → $ZELLIJ not set
  → ~/.rde-sessions/<PPID> exists → value: rde-shell-3
  → exec: zellij attach --create rde-shell-3
  → user is back in their session, process still running
```

### Transparent Zellij config

Stored at `/etc/zellij/config.kdl`, written at image build time:

```kdl
simplified_ui true
pane_frames false
default_layout "compact"
```

No status bar. No pane borders. Users see only their terminal content.

### Claude session (`rde-claude`)

`entrypoint.sh` starts this session lazily (only if it doesn't already exist) before launching code-server:

```bash
zellij --session rde-claude -- bash -c 'claude'
```

The VS Code Claude Code sidebar extension manages its own process independently and is unaffected.

---

## File Changes

| File | Repo | Change |
|---|---|---|
| `Dockerfile` | base + TMR | Download Zellij v0.44.3 binary (SHA256 pinned), write `/etc/zellij/config.kdl`, write `/etc/profile.d/rde-zellij.sh` |
| `entrypoint.sh` | base + TMR | Add `start_zellij_sessions()` called before `exec code-server` and before `exec python3 -m http.server 8080` |
| `docs/superpowers/specs/` | base only | This design document |

## What Does NOT Change

- code-server VS Code experience is identical
- Claude Code sidebar extension is unaffected
- OpenCode web UI is unaffected
- All existing env vars, git clone, dep install, dev server detection logic unchanged
- Port mappings unchanged (8080, 9100, 3100)
