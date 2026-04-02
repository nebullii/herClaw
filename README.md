# OpenClaw Docker Installer

**Three commands. One API key. Your AI agent is running.**

A beginner-friendly, auto-troubleshooting Docker installer for [OpenClaw](https://openclaw.ai) — the AI agent platform that connects to 25+ chat channels. Designed so anyone, even someone who has never used a terminal before, can set up a working AI agent in under 5 minutes. If something goes wrong, the installer tells you exactly what happened and how to fix it.

---

## 🚀 Setup Guide (No Tech Experience Needed)

Follow these steps in order. The installer handles everything — Docker, security, debugging — you just answer a few questions.

### Step 1: Get Your AI Key (2 minutes)

Before running the installer, you need an API key from at least one AI provider. This is what powers the AI brain.

**Pick at least one AI provider** (any will work — add as many as you like):

| Provider | Free Tier? | How to Get Your Key |
|---|---|---|
| **Anthropic (Claude)** | Yes | Go to [console.anthropic.com](https://console.anthropic.com) → Sign up → API Keys → Create Key → Copy it |
| **OpenAI (GPT-4)** | Yes | Go to [platform.openai.com/api-keys](https://platform.openai.com/api-keys) → Sign up → Create Key → Copy it |
| **Google Gemini** | Yes | Go to [aistudio.google.com/apikey](https://aistudio.google.com/apikey) → Create Key → Copy it |
| **Mistral** | Yes | Go to [console.mistral.ai](https://console.mistral.ai) → API Keys → Create → Copy it |
| **Groq (fast Llama)** | Yes | Go to [console.groq.com/keys](https://console.groq.com/keys) → Create Key → Copy it |
| **DeepSeek** | Yes | Go to [platform.deepseek.com](https://platform.deepseek.com) → API Keys → Create → Copy it |
| **OpenRouter (100+ models)** | Yes | Go to [openrouter.ai/keys](https://openrouter.ai/keys) → Create Key → Copy it |
| **Cohere** | Yes | Go to [dashboard.cohere.com/api-keys](https://dashboard.cohere.com/api-keys) → Create → Copy it |

**Save your key(s)** somewhere (Notepad, Notes app, etc.) — you'll paste them into the installer in Step 3.

> ⚠️ Most providers only show the key once. If you lose it, just create a new one.

### Step 2: Open a Terminal and Download the Installer

A "terminal" is a text window where you type commands. Here's how to open one:

| Your Computer | How to Open It |
|---|---|
| **Windows** | **Option A (recommended):** Install [Git for Windows](https://gitforwindows.org/) (click Next on every screen), then press `Windows key`, type **Git Bash**, click it. **Option B:** Press `Windows key`, type **PowerShell**, click it. |
| **Mac** | Press `Cmd + Space`, type **Terminal**, press Enter |
| **Linux** | Press `Ctrl + Alt + T` |

Now type these commands **one at a time** (press **Enter** after each):

**If you have Git installed:**
```bash
git clone https://github.com/shilpa-kulkarni-14/openclaw-docker-installer.git
cd openclaw-docker-installer
./docker-install.sh
```

**If you DON'T have Git** (or don't know what Git is):
```bash
curl -fsSL https://github.com/shilpa-kulkarni-14/openclaw-docker-installer/archive/refs/heads/main.tar.gz | tar xz
cd openclaw-docker-installer-main
bash docker-install.sh
```

> **What is Git?** Git is a tool that downloads code from the internet. If you don't have it, use the `curl` option above — it does the same thing without needing Git.

> **Don't have Docker?** The installer will detect this and **install it for you automatically**.

> **Windows tip:** If you see "permission denied", type `bash docker-install.sh` instead of `./docker-install.sh`.

### Step 3: Follow the Installer Prompts

The installer asks you a few simple questions. Here's what to expect:

**1. Choose your AI provider(s) and paste your key:**
```
  Which AI providers do you want to use?

    1) Anthropic (Claude)
    2) OpenAI (GPT-4)
    3) Google Gemini
    ...

  Select providers: ▊
```
Pick at least one provider by number, then paste the key when prompted. **How to paste:**
- **Windows:** Right-click → Paste, or press `Shift + Insert`
- **Mac:** Press `Cmd + V`
- **Linux:** Press `Ctrl + Shift + V`

**2. Wait ~2 minutes** while the installer does everything:
- ✅ Installs Docker (if needed)
- ✅ Checks your system
- ✅ Builds the AI agent
- ✅ Starts it up
- ✅ Sets up security
- ✅ Auto-fixes any problems it finds

### Step 4: Say Hello to Your AI Agent

When the installer finishes, it automatically opens your browser. You'll see the OpenClaw dashboard with a chat box.

**Type `hello` and press Enter.** Your AI agent should respond within a few seconds. That's it — you're talking to your own AI agent!

```
  ✓ Your OpenClaw agent is running!

  Open this URL in your browser (token included — just click!):

    http://localhost:18789/#token=abc123def456...

  Try it now: Type hello in the chat box and press Enter!
```

> **What good looks like:** You type "hello" → the AI responds with a greeting. If that works, everything is set up correctly.

### Step 5 (Optional): Connect a Chat Channel

The webchat in the browser works immediately. If you also want your AI on Slack, Discord, Telegram, or 20+ other channels, run:

```bash
./docker-install.sh --channels
```

### 🎉 That's It!

Your AI agent is running. You can close the terminal window — it keeps running in the background.

**Everyday commands** (type these in the terminal if you need them):

| What you want | What to type |
|---|---|
| Stop the agent | `./docker-install.sh --stop` |
| Start it again | `./docker-install.sh` |
| Something broken? | `./docker-install.sh --doctor` (auto-fixes most issues) |
| Remove everything | `./docker-install.sh --uninstall` |

---

## How It Works

```
You answer: 1 question (API key)
     ↓
The installer: Handles EVERYTHING else
     ↓
You get: A running AI agent in your browser — type "hello" and it responds
     ↓
Optional: Connect to Slack, Discord, Telegram, or 25+ channels later
```

**What the installer does for you (no manual steps needed):**
- Installs Docker if you don't have it
- Installs Git dependencies
- Validates your API keys (catches typos, wrong key types)
- Lets you add more AI providers (OpenAI, Gemini, Mistral, Groq, DeepSeek, OpenRouter, Cohere)
- Opens a webchat dashboard — working AI conversation in your browser immediately
- Builds and starts the agent container
- Auto-fixes 15+ common problems (port conflicts, DNS issues, permissions, disk space, etc.)
- Sets up security (11 layers of protection)
- Auto-generates and pairs the dashboard token
- Prints a clickable URL to open the control panel

**What about Discord/Telegram/Slack?** Channels are optional. The default install gives you a working webchat in the browser. To add channels later, run `./docker-install.sh --channels`.

---

## Quick Start (for developers)

```bash
git clone https://github.com/shilpa-kulkarni-14/openclaw-docker-installer.git && cd openclaw-docker-installer && ./docker-install.sh
```

Or without Git:
```bash
curl -fsSL https://github.com/shilpa-kulkarni-14/openclaw-docker-installer/archive/refs/heads/main.tar.gz | tar xz && cd openclaw-docker-installer-main && bash docker-install.sh
```

---

## What Happens When You Run The Installer

The installer runs 4 phases. Here's exactly what each one does:

### Phase 1: Pre-flight checks (9 automatic checks)

Before doing anything, the installer checks that your system is ready. If something is wrong, it tries to fix it automatically.

| Check | What it looks for | Auto-fix if it fails |
|---|---|---|
| Docker installed? | `docker` command exists | Offers to install via Homebrew (Mac) or get.docker.com (Linux) |
| Docker running? | `docker info` succeeds | Opens Docker Desktop (Mac) or starts daemon (Linux), waits 60s |
| Docker Compose? | `docker compose version` | Installs Compose plugin or standalone binary |
| Permissions OK? | `docker ps` without sudo | Adds user to docker group (Linux) |
| Version recent? | Docker 20.x+ | Warns with upgrade link |
| Disk space? | 1GB+ free | Offers `docker system prune` to free space |
| Port 18789 free? | Nothing listening on port | Shows what's blocking, offers to continue |
| Stale container? | No crashed openclaw-agent | Auto-removes crashed containers from previous runs |
| Network works? | Can reach npm registry | Tests from inside Docker, fixes DNS if broken |

### Phase 2: API key configuration

Presents a multi-provider picker — choose any combination of Anthropic, OpenAI, Google Gemini, Mistral, Groq, DeepSeek, OpenRouter, or Cohere. Validates each key before continuing:

- Checks provider-specific prefix (e.g. `sk-ant-` for Anthropic, `sk-proj-` for OpenAI)
- Checks length (catches truncated copy-paste)
- Detects if you pasted the wrong provider's key
- Detects placeholder text left from the template
- Strips invisible characters and whitespace

### Phase 3: Build and start

Builds the Docker image and starts the container. If the build fails, it automatically:

1. Diagnoses the failure (disk, network, npm, Docker daemon, permissions, timeout, OOM)
2. Applies a fix (clean cache, pull fresh image, free disk space)
3. Retries with `--no-cache`
4. Retries with a fresh base image pull
5. Only gives up after 3 attempts, with specific next steps

If the container crashes after starting, it reads the logs and diagnoses:

| Crash reason | How it's detected | What it tells you |
|---|---|---|
| Missing API key | Logs mention "No AI provider API key" | Check .env file, add at least one provider key |
| Empty API key | Logs mention "empty" or "blank" | Paste actual key after = sign |
| Wrong key type | Logs mention wrong provider | Check the key prefix matches your provider |
| Key too short | Logs mention "too short" | Copy the full key from your provider's console |
| Placeholder left | Logs mention "your-key-here" | Replace placeholder with real key |
| Permission denied | Logs mention "EACCES" | Delete volume, recreate |
| Module not found | Logs mention "MODULE_NOT_FOUND" | Uninstall and reinstall |
| Corrupt config | Logs mention "invalid JSON" | Restart (auto-recovers) |
| DNS failure | Logs mention "ENETUNREACH" | Restart Docker, check internet |
| TLS/cert error | Logs mention "certificate" | Corporate proxy issue, disconnect VPN |
| Out of memory (137) | Exit code 137 | Increase memory in compose file |
| Graceful stop (143) | Exit code 143 | Normal — just restart |
| Segfault (139) | Exit code 139 | Rebuild from scratch |

### Phase 4: Finishing up (security + dashboard)

Automatically checks and fixes:
- `.env` file permissions (must be 600)
- `.gitignore` contains `.env` (prevents accidental commit)
- Warns if `.env` is tracked by git
- Waits for gateway to be healthy
- Opens the dashboard in your browser
- Auto-pairs the dashboard (so you never see "pairing required")

#### Security scorecard (9 points)

```
  Security Scorecard (Docker)
  ┌──────────────────────────────────────────┬────────┐
  │ Container running                        │  ✓     │
  │ Port bound to localhost only             │  ✓     │
  │ Running as non-root (openclaw)           │  ✓     │
  │ API key file permissions (600)           │  ✓     │
  │ Linux capabilities dropped               │  ✓     │
  │ Privilege escalation blocked             │  ✓     │
  │ Memory limit set (2GB)                   │  ✓     │
  │ PID namespace isolated                   │  ✓     │
  │ .env protected by .gitignore             │  ✓     │
  └──────────────────────────────────────────┴────────┘
  Score: 9/9 — HARDENED
```

---

---

## Commands Reference

| What you want to do | Command |
|---|---|
| Install and start | `./docker-install.sh` |
| Install with channel picker | `./docker-install.sh --channels` |
| **Open Control Panel** | **`http://localhost:18789`** |
| **Get tokenized dashboard URL** | `docker exec -it openclaw-agent openclaw dashboard --no-open` |
| **Pair dashboard (one-time)** | `docker exec -it openclaw-agent openclaw gateway pair` |
| Stop the agent | `./docker-install.sh --stop` |
| Check if running | `./docker-install.sh --status` |
| Diagnose problems | `./docker-install.sh --doctor` |
| See live logs | `docker logs -f openclaw-agent` |
| Restart after editing .env | `docker compose restart` |
| Configure channels | `docker exec -it openclaw-agent openclaw configure` |
| Add a skill | `docker exec -it openclaw-agent openclaw skill install <name>` |
| Preview without running | `./docker-install.sh --dry-run` |
| Remove everything | `./docker-install.sh --uninstall` |

---

## The `--doctor` Command

Something broken? Run the doctor:

```bash
./docker-install.sh --doctor
```

It checks everything and auto-fixes what it can:

- Docker daemon running?
- Container state (running/stopped/crashed with logs)
- .env file exists, permissions correct, key format valid
- Port binding (localhost-only?)
- Gateway responding to health checks
- Network connectivity to AI provider APIs

Example:

```
  Container State
  ✗ Container exited (code: 1)
  Last 10 log lines:
    ✗ ERROR: No Anthropic API key found.

  ↻ Auto-fix: Remove crashed container and restart? [Y/n]: y
  ✓ Container restarted

  Found 1 problem(s) — all fixed automatically.
```

---

## Security: 11 Layers of Protection

| # | Protection | Plain English |
|---|---|---|
| 1 | Container isolation | Your agent runs in its own sandbox, separate from your computer |
| 2 | All capabilities dropped | The agent has zero special system powers |
| 3 | No privilege escalation | Nothing inside the container can become root |
| 4 | Resource limits | Max 2GB RAM, 2 CPUs, 200 processes (can't hog your machine) |
| 5 | Non-root user | Runs as a limited user, not as admin |
| 6 | Localhost-only port | Only your computer can talk to the agent (not your WiFi network) |
| 7 | Network isolation | Agent gets its own network, can't poke around your system |
| 8 | DNS hardening | Uses Cloudflare + Google DNS (resists DNS poisoning) |
| 9 | Log rotation | Logs can't fill up your disk (max 30MB) |
| 10 | SSRF protection | Blocks cloud metadata endpoints that steal credentials |
| 11 | Secure uninstall | API key file overwritten with random data before deletion |

### What the entrypoint checks on every startup

Every time the container starts, it runs 11 checks:

1. Is the API key present? (from Docker secrets or .env)
2. Is the key empty/blank?
3. Is the key the right type for the selected provider?
4. Is the key too short? (truncated copy-paste)
5. Does the key have invisible characters? (auto-cleans them)
6. Is the config directory writable?
7. Is the gateway config valid JSON?
8. Does the config have an auth token?
9. Is the OpenClaw binary installed?
10. Can the container reach the internet?
11. Is /tmp writable? (needed for skills)

Each check has a specific error message and fix instructions if it fails.

---

## Troubleshooting Every Known Error

### During install (on your machine)

| Error | Cause | Fix |
|---|---|---|
| "Docker is not installed" | Docker not on your system | Follow the install instructions shown, then re-run |
| "Docker is installed but not running" | Daemon not started | Open Docker Desktop (Mac) or `sudo systemctl start docker` (Linux) |
| "permission denied" running docker | User not in docker group (Linux) | `sudo usermod -aG docker $USER` then log out/in |
| "Docker Compose not found" | Old Docker or missing plugin | Update Docker Desktop or install compose plugin |
| "Low disk space" | <1GB free | Run `docker system prune -a` or free disk space |
| "Port 18789 already in use" | Another app on that port | Stop the other app, or change port in docker-compose.yml |
| "Cannot reach npm registry" | No internet or DNS broken | Check connection; installer tries Google DNS auto-fix |
| "Docker Hub rate limit" | Too many pulls (429 error) | Wait 15 min or `docker login` with free account |
| "Build timed out" | Slow network | Retry — usually works on second attempt |
| "Build killed (OOM)" | Docker doesn't have enough RAM | Docker Desktop → Settings → Resources → Memory → 4GB+ |
| API key validation fails | Typos or wrong key | Get a fresh key from your provider's console |

### After install (dashboard / browser)

| Error | Cause | Fix |
|---|---|---|
| **"HTTP 401 authentication_error: invalid x-api-key"** | Your Anthropic API key is invalid, expired, or over its rate limit | See **API Key 401 Error** section below |
| "unauthorized: gateway token missing" | Dashboard needs the gateway auth token | Run `docker exec -it openclaw-agent openclaw dashboard --no-open` and open the tokenized URL |
| "pairing required" | Dashboard not yet paired with gateway | Run `docker exec -it openclaw-agent openclaw gateway pair`, then refresh |
| "error empty response" / page won't load | Container running but gateway can't serve requests | Check logs: `docker logs openclaw-agent`. Rebuild: `docker compose build --no-cache` |
| Page loads but WebSocket won't connect | Token expired or volume was reset | Get a fresh token: `docker exec -it openclaw-agent openclaw dashboard --no-open` |

### API Key 401 Error — `HTTP 401 authentication_error: invalid x-api-key`

This is the most common post-install issue. You type "hello" in the dashboard and get a 401 error. This means the Anthropic API **rejected your key**. Here's why and how to fix it:

**Common causes:**

| Cause | How to tell | Fix |
|---|---|---|
| **Key was revoked or deleted** | You deleted it in the Anthropic Console | Create a new key at [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys) |
| **Free tier rate limit hit** | Works sometimes, fails other times | Go to [console.anthropic.com/settings/limits](https://console.anthropic.com/settings/limits) and request a limit increase, or add billing |
| **Key copied incorrectly** | Key is truncated or has extra spaces | Copy the full key again — it starts with `sk-ant-api03-` and is ~108 characters |
| **Using a workspace key on wrong workspace** | You have multiple Anthropic workspaces | Make sure the key belongs to an active workspace with API access |
| **Account suspended or billing issue** | Key format is correct but always fails | Log into [console.anthropic.com](https://console.anthropic.com) and check for billing alerts |

**Quick fix:**

```bash
# 1. Test your key directly (replace YOUR_KEY):
curl -s https://api.anthropic.com/v1/messages \
  -H "x-api-key: YOUR_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"claude-sonnet-4-20250514","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}'

# 2. If that returns an error, get a new key from console.anthropic.com

# 3. Update your key:
nano .env
# Replace or add your AI provider API key

# 4. Restart:
docker compose restart
```

> **Workshop tip:** Before the session, test your API key with the curl command above. If it returns a response (not an error), you're good to go.

### After install (inside the container)

| Error in logs | Cause | Fix |
|---|---|---|
| "No AI provider API key found" | No key in .env | Add at least one provider key to .env, restart |
| "key is very short" | Key truncated during copy | Copy full key from your provider's console |
| "placeholder text" | Forgot to replace example | Put real key in .env, not "your-key-here" |
| "Config directory not writable" | Volume permissions | `docker volume rm openclaw-data`, re-run installer |
| "invalid JSON" | Config file corrupted | Restart container (auto-recovers) |
| "OpenClaw binary not found" | Image corrupted | `docker compose build --no-cache` |
| "cannot reach the internet" | No internet in container | Restart Docker Desktop, check connection |
| Exit code 137 | Out of memory | Increase `memory: 2G` to `4G` in docker-compose.yml |
| Exit code 139 | Crash (segfault) | `./docker-install.sh --uninstall && ./docker-install.sh` |

---

## Files

```
openclaw-docker-installer/
├── docker-install.sh          # The installer (auto-troubleshooting + 4 phases)
├── docker-compose.yml         # Container config (security-hardened)
├── Dockerfile                 # Multi-stage minimal image
├── docker/
│   └── entrypoint.sh          # Startup: 11 checks, validates, secures, starts
├── scripts/
│   └── patch-primary-model.sh # Detects provider and sets primary model in .env
├── .env.example               # Template — copy to .env and add your key
├── .env                       # Your API keys (git-ignored, chmod 600)
├── .gitignore                 # Ensures .env is never committed
├── .github/
│   └── workflows/
│       └── test-installer.yml # Cross-platform CI tests
└── README.md                  # This file
```

---

## Supported Channels (25+)

These are configured AFTER install using `openclaw configure`:

| Channel | Where to get tokens |
|---|---|
| Slack | [api.slack.com/apps](https://api.slack.com/apps) → Bot Token + App Token |
| Discord | [discord.com/developers](https://discord.com/developers) → Bot Token |
| Telegram | @BotFather in Telegram → `/newbot` → HTTP API token |
| WhatsApp | Meta Business Suite → WhatsApp Business API |
| Microsoft Teams | Azure Bot Framework → App ID + Password |
| Google Chat | Google Cloud Console → Chat app → service account key |
| Signal | Requires signal-cli or signald running locally |
| Matrix | Homeserver URL + access token |
| IRC | Server, port, channel, optional password |
| Mattermost | Bot account → personal access token |
| WebChat | Built-in browser widget |
| Twitch | [dev.twitch.tv](https://dev.twitch.tv) → OAuth token |
| LINE | LINE Developers → Channel access token |
| And 12 more... | Run `./docker-install.sh --channels` to see all |

---

## License

MIT
