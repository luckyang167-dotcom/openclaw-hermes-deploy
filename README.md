# OpenClaw + Hermes Deploy

Private backup, migration, deployment, and active/standby failover system for OpenClaw agents and Hermes profiles.

## Architecture

```
openclaw-hermes-deploy/
├── README.md              ← This file
├── manifest.yaml           ← Source machine metadata
├── .gitignore              ← Prevents secrets/DBs/archives in Git
├── openclaw/
│   ├── config/
│   │   └── openclaw.patch.json5   ← Portable OpenClaw config (no secrets)
│   ├── agents/             ← Agent workspace definitions (readable)
│   │   ├── main/           ← Rui (生活助手)
│   │   ├── job-hunter/     ← 求职助手
│   │   ├── coding/         ← 编程搭档
│   │   └── fitness/        ← 铁哥
│   └── cron/
│       └── jobs.json       ← 6 OpenClaw cron job declarations
├── hermes/
│   └── profiles/
│       ├── default/        ← General-purpose assistant
│       ├── coder/          ← Professional coding assistant
│       └── money-maker/    ← Money-making strategy assistant
├── control/
│   └── active-host.json   ← Active/standby state machine
├── scripts/
│   ├── common.sh           ← Shared library
│   ├── export.sh           ← Create consistency snapshot
│   ├── deploy.sh           ← Deploy snapshot to target
│   ├── demote.sh           ← Demote active host
│   ├── promote.sh          ← Promote standby to active
│   ├── verify.sh           ← Verify deployment integrity
│   ├── rollback.sh         ← Restore pre-deployment state
│   └── preflight-check.sh  ← Check for secrets/DBs before commit
└── tests/
    └── run-all-tests.sh    ← Automated test suite
```

## Git vs Release Boundary

| What | Where |
|------|-------|
| Agent definitions, SOUL.md, AGENTS.md | **Ordinary Git** |
| Sanitized configs (no API keys) | **Ordinary Git** |
| Cron job declarations | **Ordinary Git** |
| `.env.EXAMPLE` templates | **Ordinary Git** |
| Scripts, tests, docs | **Ordinary Git** |
| API keys, tokens, credentials | **Private Release ONLY** |
| `.env`, `auth.json` | **Private Release ONLY** |
| SQLite databases | **Private Release ONLY** |
| Sessions, memories, pairings | **Private Release ONLY** |
| Device identity | **Private Release ONLY** |
| `agent-state.tar.zst` | **Private Release ONLY** |

## Included Agents

| ID | Name | Description |
|----|------|-------------|
| main | Rui (睿) | 生活助手 & Agent管家 |
| job-hunter | 求职助手 (Hunter) | 全能求职助手 |
| coding | 编程搭档 (Code) | 专业编程助手 |
| fitness | 铁哥 (Tie Ge) | 健身运动搭子 |

## Included Hermes Profiles

| Profile | Description |
|---------|-------------|
| default | General-purpose AI assistant |
| coder | Professional coding assistant |
| money-maker | Money-making strategy assistant |

## Included Cron Jobs

### OpenClaw (6 jobs)

1. **Memory Dreaming Promotion** — Daily at 03:00 UTC
2. **pulse** — Tech brief every morning at 08:00 Asia/Shanghai
3. **morning-todo-planning** — Daily todo planning at 09:00 Asia/Shanghai
4. **afternoon-pulse-check** — Progress check at 14:00 Asia/Shanghai
5. **每日面经准备提醒** — Interview prep reminder at 14:00 Asia/Shanghai
6. **每日英语学习提醒** — English study reminder at 20:00 Asia/Shanghai

### Hermes (1 job)

1. **具身智能每日市场扫描** (money-maker) — Daily market scan at 08:00 Asia/Shanghai

## Version Requirements

| Component | Version |
|-----------|---------|
| Node.js | 24.15.0 |
| OpenClaw | 2026.6.11 |
| Hermes Agent | 0.19.0 |
| Python | ≥3.12 |
| zstd | Any recent |
| GitHub CLI | Any recent |

## WSL2 Initial Setup

```bash
# 1. Install Node.js 24.15.0
nvm install 24.15.0
nvm use 24.15.0

# 2. Install OpenClaw
npm install -g openclaw@2026.6.11

# 3. Install Hermes Agent
pip install hermes-agent==0.19.0

# 4. Install GitHub CLI and authenticate
# https://cli.github.com/
gh auth login

# 5. Clone this repository
git clone git@github.com:luckyang167-dotcom/openclaw-hermes-deploy.git
cd openclaw-hermes-deploy
```

## First Deployment

On the target WSL2 machine:

```bash
# 1. Set host ID and initialize control file
HOST_ID="wsl2-standby"

# 2. Deploy the latest snapshot
scripts/deploy.sh --snapshot <latest-tag> --host-id $HOST_ID

# 3. Wait for demotion on active host, then promote
git pull
scripts/promote.sh --host-id $HOST_ID --snapshot <latest-tag>
```

## Regular Export (no switch)

On the active machine:

```bash
scripts/export.sh
```

This creates a consistency snapshot and uploads it as a Private GitHub Release.
Gateways are stopped during export and restarted afterwards.

## Active/Standby Switch Flow

### Demote (active → standby)

On the **currently active** machine:

```bash
scripts/demote.sh --next-host wsl2-standby
```

What happens:
1. Git fetch and generation verification
2. All gateways stopped
3. Consistency snapshot created and uploaded
4. `active-host.json` updated to `switching`
5. Committed and pushed
6. Services remain stopped on this machine

### Deploy (on standby)

On the **standby** machine:

```bash
scripts/deploy.sh --snapshot <tag> --host-id wsl2-standby
```

What happens:
1. Dependencies verified
2. Release downloaded and SHA-256 verified
3. Local rollback backup created
4. Profile-level merge (source wins)
5. Paths rendered, permissions fixed
6. Configs and databases validated
7. Services NOT started (standby)

### Promote (standby → active)

On the **standby** machine:

```bash
scripts/promote.sh --host-id wsl2-standby --snapshot <tag>
```

What happens:
1. Git fetch and control state verified (must be `switching`)
2. `next_host_id` must match this machine
3. `verify.sh` run
4. Control updated to `active`
5. Pushed to GitHub
6. All gateways started
7. Health check performed

## Rollback

On the machine that needs rollback:

```bash
# Use most recent rollback
scripts/rollback.sh

# Or specify a specific rollback
scripts/rollback.sh --archive .rollback/pre-deploy-snapshot-20260803-120000Z
```

What happens:
1. Available rollback archives listed
2. Emergency backup of current (broken) state created
3. All services stopped
4. Pre-deployment state restored
5. Permissions fixed, databases validated
6. Services restarted ONLY if this host is active
7. Rollback archive preserved (never auto-deleted)

## active-host.json States

```json
{
  "schema_version": 1,
  "host_id": "linux-desktop",
  "status": "active",
  "generation": 5,
  "snapshot_tag": "snapshot-20260803-120000Z",
  "next_host_id": null,
  "updated_at": "2026-08-03T12:00:00+08:00"
}
```

| Status | Meaning | Can Start Services? |
|--------|---------|---------------------|
| `active` | This host is serving | ✅ Yes |
| `standby` | Ready but not serving | ❌ No |
| `switching` | Demotion in progress, waiting for standby to promote | ❌ No |

The `generation` field is a monotonically increasing counter that prevents split-brain.
Every demote/promote increments it by 1.

## Security Warnings

### ⚠️ CRITICAL

1. **This repository MUST remain PRIVATE.** It contains deployment infrastructure for agents that have access to personal data.
2. **Never change the repository to public.** If this happens, immediately rotate ALL API keys, channel tokens, device credentials, and Feishu/Weixin platform secrets.
3. **The `agent-state.tar.zst` Release contains ALL secrets.** Anyone with access to the Release can access your API keys, auth tokens, and device identity.
4. **Only download Releases on machines you fully control.**
5. **If the repository or any Release is leaked/exposed**, you MUST:
   - Rotate all API keys (SiliconFlow, DeepSeek, ARK, Xiaomi MIMO, OpenCode, OpenRouter, etc.)
   - Rotate all Feishu app credentials
   - Rotate all Weixin platform tokens
   - Rotate all webhook secrets
   - Re-pair all channel/platform connections
   - Verify no unauthorized gateway processes are running

### Operational Security

- `export.sh` sets `umask 077` before creating sensitive files
- Sensitive files restored with permissions `0600`, directories `0700`
- `.gitignore` blocks: `*.sqlite`, `*.db`, `.env`, `auth.json`, `sessions/`, `credentials/`, `identity/`, archives
- `preflight-check.sh` scans for secrets, databases, and archives before commits
- Never run `git add -A` blindly — always run `preflight-check.sh` first
- GitHub push protection is enabled — do not disable it

## Verification (without real cron execution)

```bash
# Run all tests (no real cron payloads, no messages sent)
bash tests/run-all-tests.sh

# Preflight check for secrets/DBs/archives
bash scripts/preflight-check.sh

# Verify deployment integrity
bash scripts/verify.sh
```

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `git push` rejected | Divergent history | Follow instructions; do NOT force-push |
| `promote.sh` fails | Generation mismatch | Ensure you `git pull` first |
| `deploy.sh` version check fails | Wrong Node/OpenClaw/Hermes | Install exact versions listed above |
| Gateways won't start after deploy | Host is standby | Run `promote.sh` to become active |
| SHA-256 verification fails | Corrupted download | Re-download the Release |
| Database integrity check fails | Corrupted DB in snapshot | Re-create snapshot on source machine |
| `export.sh` fails | Not active host | Check `active-host.json` status |
| Control file push failed after demote | Network/GitHub issue | Fix connectivity, re-push manually |

## Repository Structure Notes

- `hermes/profiles/default/` corresponds to `~/.hermes/` (root-level Hermes config)
- `hermes/profiles/coder/` corresponds to `~/.hermes/profiles/coder/`
- `hermes/profiles/money-maker/` corresponds to `~/.hermes/profiles/money-maker/`
- OpenClaw agent workspaces: `workspace` (main), `workspace-coding`, `workspace-job-hunter`, `workspace-fitness`
- All paths use `${TARGET_HOME}` placeholder — rendered to `$HOME` at deploy time
