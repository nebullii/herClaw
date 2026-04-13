# herClaw

**A personal AI agent with her own phone number and email, hardened for distribution to nontechnical users.**

herClaw is a one-command install of [OpenClaw](https://openclaw.ai) wired to [Inkbox](https://inkbox.ai) for real-world comms. Send her an email, she replies. Over time she'll answer texts and calls too. The whole stack runs in Docker on your laptop — no cloud bill, no vendor account beyond your model provider and Inkbox.

Built for a hackathon project targeting security-conscious, nontechnical women who want their own always-on assistant without handing a third party the keys.

---

## Why this exists

Raw OpenAI (or Claude, or any frontier model) is a one-shot chat. It has no memory, no tools, no identity, no way to reach you when you're not looking at the API playground. Consumer products layered on top (ChatGPT, Claude.ai) fix that for power users but:

- Live in someone else's cloud — your conversations are theirs to store, train on, or lose.
- Don't have their own phone number or mailbox.
- Can't be handed to someone who's never opened a terminal.

herClaw bundles the missing pieces:

```
          ┌─────────────────────────────────────────────┐
          │  Model  (gpt-4o-mini / Claude / your key)   │  raw intelligence
          ├─────────────────────────────────────────────┤
          │  OpenClaw  — agent runtime                  │  memory, tools, skills,
          │    identity / user / memory / workspace     │  session routing
          ├─────────────────────────────────────────────┤
          │  Inkbox   — comms layer                     │  mailbox, phone number,
          │    email · sms · voice · vault              │  webhooks
          ├─────────────────────────────────────────────┤
          │  Docker installer — distribution layer      │  hardened defaults,
          │    one command, no YAML for the user        │  auto-doctor, security audit
          └─────────────────────────────────────────────┘
```

Same agent answers email today, Telegram tomorrow, voice calls next month — because the brain (OpenClaw) is separate from the pipes (Inkbox).

---

## What works today

- **Email round-trip.** Write to the agent's Inkbox address from any mail client; reply arrives within ~15s.
- **Persistent identity + memory.** `IDENTITY.md`, `USER.md`, per-session state survive restarts.
- **Hardened Docker.** All Linux capabilities dropped, no-new-privileges, file perms 700/600, DNS via host resolver (works behind restrictive networks), memory/PID limits.
- **One-command install.** `./docker-install.sh` auto-detects 15+ common issues and fixes them before the agent starts.
- **Provider-flexible.** Drop in an OpenAI, Anthropic, Google, Mistral, or OpenRouter key — the installer picks a sensible default model for each.

## Roadmap

- Telegram channel (OpenClaw supports natively; ~10 min setup).
- SMS reply via Inkbox (blocked on outbound-send API; Inkbox CLI v0.1.0 only has inbound).
- Voice calls via Inkbox WebSocket + OpenAI Realtime API.
- Named Cloudflare tunnel + webhook signature verification (production hardening).
- Community-specific skills (scheduling, triage, research).

---

## Quickstart

### 1. Install OpenClaw

```bash
git clone https://github.com/nebullii/herClaw.git
cd herClaw
./docker-install.sh
```

The installer asks for **one** API key (OpenAI recommended — `gpt-4o-mini` is the tuned default for tier-1 rate limits), builds the container, and starts the gateway. At the end it prints a token-embedded dashboard URL you can open in any browser.

### 2. (Optional) Wire up Inkbox email

Lets the agent handle email from a real mailbox.

```bash
# Install the Inkbox CLI
npm install -g @inkbox/cli
export INKBOX_API_KEY="<your-inkbox-api-key>"

# Provision (or look up) a mailbox for your agent identity
inkbox --base-url https://inkbox.ai mailbox list

# Start the local bridge
cd bridges/inkbox-email
INKBOX_API_KEY="$INKBOX_API_KEY" \
INKBOX_MAILBOX="<your-mailbox@inkboxmail.com>" \
node bridge.js

# Expose it to Inkbox via Cloudflare Tunnel (separate terminal)
cloudflared tunnel --url http://127.0.0.1:3838

# Attach the tunnel URL as the mailbox webhook
inkbox --base-url https://inkbox.ai mailbox update \
  <your-mailbox@inkboxmail.com> \
  --webhook-url https://<your-tunnel>.trycloudflare.com/webhook
```

Send an email to the mailbox from any address — the agent reads it, answers, and the reply lands back in the sender's inbox.

See [`bridges/inkbox-email/`](bridges/inkbox-email/) for bridge source.

---

## Security posture

Built for a user who does not want their agent, key material, or conversations in a third-party cloud:

- **API keys live only in `.env`** (git-ignored) with permissions 600.
- **Container drops all Linux capabilities** — even root inside the container cannot override file perms.
- **`no-new-privileges:true`** blocks setuid escalation.
- **PID, memory, CPU, and log-size limits** prevent runaway or log-flooding agents.
- **DNS uses the host resolver** — no public DNS requests leak the agent's identity.
- **Docker volume is chmod 700**, individual config files 600.

Known gaps (honest list, to fix before real distribution):

- Inkbox webhook has no signature verification yet.
- Cloudflare quick-tunnel URLs rotate on restart; switch to a named tunnel for production.
- Bridge runs outside the Docker security boundary; moving it into a sidecar is on the roadmap.

---

## Installer commands

```bash
./docker-install.sh              # first install / fix up
./docker-install.sh --status     # check if the agent is running
./docker-install.sh --doctor     # diagnose and self-heal
./docker-install.sh --keys       # rotate or change API key
./docker-install.sh --channels   # interactive channel picker
./docker-install.sh --stop       # stop the agent
./docker-install.sh --uninstall  # remove everything
```

Under the hood: the installer lives in [`docker-install.sh`](docker-install.sh), container build in [`Dockerfile`](Dockerfile), runtime config in [`docker-compose.yml`](docker-compose.yml), and startup orchestration in [`docker/entrypoint.sh`](docker/entrypoint.sh).

---

## Credits

- **[OpenClaw](https://openclaw.ai)** — the agent runtime (workspace, tools, skills, sessions).
- **[Inkbox](https://inkbox.ai)** — agent-native email, SMS, and phone number provisioning.
- Installer scaffolding originally from [`shilpa-kulkarni-14/openclaw-docker-installer`](https://github.com/shilpa-kulkarni-14/openclaw-docker-installer); this fork adds the Inkbox bridge and distribution-readiness fixes (DNS hardening, startup race on `doctor --fix`, sane default model for tier-1 rate limits).
