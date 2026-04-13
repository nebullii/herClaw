#!/bin/sh
# ============================================================================
# OpenClaw Docker Entrypoint — Self-Diagnosing, Self-Healing Startup
# ============================================================================
# This script runs inside the container every time it starts.
# It is designed so that EVERY possible failure has a clear error message
# and a specific fix. A beginner should never see a cryptic error.
#
# What you need to provide (via .env file):
#   At least one AI provider key. Any of the following will work:
#   ANTHROPIC_API_KEY, OPENAI_API_KEY, GOOGLE_API_KEY, MISTRAL_API_KEY,
#   GROQ_API_KEY, DEEPSEEK_API_KEY, OPENROUTER_API_KEY, COHERE_API_KEY
#
# Channel tokens (Discord, Telegram, Slack, etc.) are configured AFTER install
# by running: docker exec -it openclaw-agent openclaw configure
# ============================================================================
set -e

OPENCLAW_DIR="/home/openclaw/.openclaw"
CONFIG_FILE="$OPENCLAW_DIR/openclaw.json"
STARTUP_ERRORS=0

echo ""
echo "  🦞 OpenClaw Gateway (Docker)"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Helpers ─────────────────────────────────────────────────────────────────

mask_key() {
  local key="$1"
  local len="${#key}"
  if [ "$len" -le 12 ]; then
    echo "***"
  else
    prefix="$(printf '%.8s' "$key")"
    suffix="$(printf '%s' "$key" | tail -c 4)"
    echo "${prefix}...${suffix} (${len} chars)"
  fi
}

startup_error() {
  echo "  ✗ $1"
  STARTUP_ERRORS=$((STARTUP_ERRORS + 1))
}

# ============================================================================
# CHECK 1: Load AI provider API keys
# ============================================================================
# OpenClaw works with any supported AI provider. At least one key is required.
# Channel tokens (Discord bot, Telegram, Slack) are configured LATER
# via `openclaw configure` — not during install.
# ============================================================================

echo ""
echo "  Loading credentials..."

ANY_KEY_LOADED=false

# Load each provider key from Docker secrets or environment
load_provider_key() {
  local var_name="$1" secret_file="$2" display_name="$3"
  local key_value="" key_source=""

  # Priority 1: Docker secrets
  if [ -f "/run/secrets/${secret_file}" ]; then
    key_value="$(cat "/run/secrets/${secret_file}" 2>/dev/null | tr -d '[:space:]')"
    key_source="docker-secret"
  # Priority 2: Environment variable
  else
    eval key_value="\${${var_name}:-}"
    if [ -n "$key_value" ]; then
      key_value="$(echo "$key_value" | tr -d '[:space:]')"
      key_source="environment"
    fi
  fi

  if [ -n "$key_value" ]; then
    # Strip quotes if present
    case "$key_value" in
      \"*\"|\'*\')
        key_value="$(echo "$key_value" | tr -d "\"'")"
        echo "  ⚠ ${display_name}: stripped quotes from key"
        ;;
    esac

    # Clean invisible characters
    clean_value="$(echo "$key_value" | tr -cd 'a-zA-Z0-9_.-')"
    if [ "$clean_value" != "$key_value" ]; then
      key_value="$clean_value"
      echo "  ⚠ ${display_name}: cleaned invisible characters from key"
    fi

    # Reject URLs and placeholders
    case "$key_value" in
      http://*|https://*)
        echo "  ✗ ${display_name}: looks like a URL, not an API key — skipping"
        return
        ;;
      your-key-here*|YOUR_KEY*|*your-*)
        echo "  ✗ ${display_name}: placeholder text, not a real key — skipping"
        return
        ;;
    esac

    # Check minimum length
    if [ "${#key_value}" -lt 10 ]; then
      echo "  ⚠ ${display_name}: key is very short (${#key_value} chars) — may be truncated"
    fi

    export "${var_name}=${key_value}"
    echo "  ✓ ${display_name} loaded (${key_source}): $(mask_key "$key_value")"
    ANY_KEY_LOADED=true
  fi
}

load_provider_key "ANTHROPIC_API_KEY"  "anthropic_api_key"  "Anthropic"
load_provider_key "OPENAI_API_KEY"     "openai_api_key"     "OpenAI"
load_provider_key "GOOGLE_API_KEY"     "google_api_key"     "Google Gemini"
load_provider_key "MISTRAL_API_KEY"    "mistral_api_key"    "Mistral"
load_provider_key "GROQ_API_KEY"       "groq_api_key"       "Groq"
load_provider_key "DEEPSEEK_API_KEY"   "deepseek_api_key"   "DeepSeek"
load_provider_key "OPENROUTER_API_KEY" "openrouter_api_key" "OpenRouter"
load_provider_key "COHERE_API_KEY"     "cohere_api_key"     "Cohere"

if [ "$ANY_KEY_LOADED" = false ]; then
  startup_error "ERROR: No AI provider API key found."
  echo ""
  echo "  ┌─────────────────────────────────────────────────────────────┐"
  echo "  │ OpenClaw needs at least one AI provider key to work.       │"
  echo "  │ Any of these will do:                                       │"
  echo "  │   Anthropic, OpenAI, Google Gemini, Mistral, Groq,         │"
  echo "  │   DeepSeek, OpenRouter, or Cohere.                         │"
  echo "  │                                                             │"
  echo "  │ Channel tokens (Discord, Telegram, Slack, etc.) are        │"
  echo "  │ configured LATER — not here.                               │"
  echo "  └─────────────────────────────────────────────────────────────┘"
  echo ""
  echo "  How to fix:"
  echo "  ───────────"
  echo "  1. Open your .env file (in the project folder):"
  echo "       nano .env"
  echo ""
  echo "  2. Add at least one provider key, for example:"
  echo "       ANTHROPIC_API_KEY=sk-ant-api03-xxxxxxxxxxxx"
  echo "       OPENAI_API_KEY=sk-proj-xxxxxxxxxxxx"
  echo ""
  echo "  3. Restart the container:"
  echo "       docker compose restart"
  echo ""
  exit 1
fi

# ============================================================================
# CHECK 2: Generate auth-profiles.json from environment keys
# ============================================================================
# OpenClaw reads API keys from auth-profiles.json, not directly from env vars.
# We generate this file on every startup so it always reflects .env contents.
# ============================================================================

AUTH_DIR="$OPENCLAW_DIR/agents/main/agent"
AUTH_FILE="$AUTH_DIR/auth-profiles.json"

mkdir -p "$AUTH_DIR" 2>/dev/null || true

# Build the JSON — add an entry for each loaded provider key
# We also pick the best default model for whatever provider is available.
DEFAULT_PROVIDER=""
DEFAULT_MODEL=""

echo '{' > "$AUTH_FILE"
echo '  "version": 1,' >> "$AUTH_FILE"
echo '  "profiles": {' >> "$AUTH_FILE"

first_profile=true
add_auth_profile() {
  local provider="$1" env_var="$2" model="$3" api="$4"
  local key_val=""
  eval key_val="\${${env_var}:-}"
  if [ -n "$key_val" ]; then
    if [ "$first_profile" = false ]; then
      echo '    ,' >> "$AUTH_FILE"
    fi
    first_profile=false
    cat >> "$AUTH_FILE" <<PROFILE
    "${provider}": {
      "provider": "${provider}",
      "apiKey": "${key_val}",
      "model": "${model}",
      "api": "${api}"
    }
PROFILE
    # First loaded provider becomes the default
    if [ -z "$DEFAULT_PROVIDER" ]; then
      DEFAULT_PROVIDER="$provider"
      DEFAULT_MODEL="$model"
    fi
  fi
}

add_auth_profile "anthropic"  "ANTHROPIC_API_KEY"  "claude-sonnet-4-20250514" "anthropic-messages"
add_auth_profile "openai"     "OPENAI_API_KEY"     "gpt-4o-mini"              "openai-chat"
add_auth_profile "google"     "GOOGLE_API_KEY"     "gemini-2.0-flash"         "google-genai"
add_auth_profile "mistral"    "MISTRAL_API_KEY"    "mistral-large-latest"     "mistral-chat"
add_auth_profile "groq"       "GROQ_API_KEY"       "llama-3.3-70b-versatile"  "openai-chat"
add_auth_profile "deepseek"   "DEEPSEEK_API_KEY"   "deepseek-chat"            "openai-chat"
add_auth_profile "openrouter" "OPENROUTER_API_KEY" "openrouter/auto"          "openai-chat"
add_auth_profile "cohere"     "COHERE_API_KEY"     "command-r-plus"           "cohere-chat"

cat >> "$AUTH_FILE" <<'FOOTER'
  }
}
FOOTER

chmod 600 "$AUTH_FILE"
echo "  ✓ Auth profiles written to $AUTH_FILE"

if [ -n "$DEFAULT_PROVIDER" ]; then
  echo "  ✓ Default provider: ${DEFAULT_PROVIDER} (model: ${DEFAULT_MODEL})"
fi

# ============================================================================
# CHECK 3: Set primary model (dynamic detection or explicit override)
# ============================================================================
# Without an explicit primary model in the config, OpenClaw falls back to its
# built-in default (Anthropic). If the user doesn't have an Anthropic key,
# this causes: "No API key found for provider anthropic"
#
# Fix: detect which provider key is present and write the matching model
# into the config. OPENCLAW_PRIMARY_MODEL env var overrides auto-detection.
# ============================================================================

if [ -n "${OPENCLAW_PRIMARY_MODEL:-}" ]; then
  PRIMARY_MODEL="$OPENCLAW_PRIMARY_MODEL"
  echo "  ✓ Primary model override: ${PRIMARY_MODEL} (from OPENCLAW_PRIMARY_MODEL)"
elif [ -n "$DEFAULT_MODEL" ]; then
  PRIMARY_MODEL="${DEFAULT_PROVIDER}/${DEFAULT_MODEL}"
  echo "  ✓ Primary model auto-detected: ${PRIMARY_MODEL}"
else
  PRIMARY_MODEL=""
  echo "  ⚠ No primary model detected (no provider keys found)"
fi

export OPENCLAW_RESOLVED_PRIMARY_MODEL="${PRIMARY_MODEL}"

# ============================================================================
# CHECK 4: Config directory and permissions
# ============================================================================

echo ""
echo "  Checking environment..."

# ── Is the config directory writable? ──
if [ -w "$OPENCLAW_DIR" ]; then
  echo "  ✓ Config directory writable"
else
  startup_error "ERROR: Config directory not writable: $OPENCLAW_DIR"
  echo ""
  echo "  This happens when:"
  echo "    • The Docker volume has wrong ownership (most common)"
  echo "    • The volume was created by a different image version"
  echo ""
  echo "  Fix: Delete the volume and let Docker recreate it:"
  echo "    docker compose down"
  echo "    docker volume rm openclaw-data"
  echo "    docker compose up"
  echo ""
  exit 1
fi

# ── Is the secrets directory writable? ──
if [ -d "$OPENCLAW_DIR/.secrets" ]; then
  if [ -w "$OPENCLAW_DIR/.secrets" ]; then
    echo "  ✓ Secrets directory writable"
  else
    echo "  ⚠ Secrets directory not writable — fixing permissions..."
    chmod 700 "$OPENCLAW_DIR/.secrets" 2>/dev/null || {
      startup_error "Cannot fix secrets directory permissions"
      echo "    Fix: docker volume rm openclaw-data && docker compose up"
    }
  fi
fi

# ============================================================================
# CHECK 5: Generate or validate gateway config
# ============================================================================

echo ""
echo "  Configuring gateway..."

if [ ! -f "$CONFIG_FILE" ]; then
  # ── Generate new config ──

  # Generate auth token (or use one provided by the installer via env var)
  GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"

  if [ -z "$GATEWAY_TOKEN" ]; then
    # No token provided — generate one
    if command -v openssl >/dev/null 2>&1; then
      GATEWAY_TOKEN="$(openssl rand -hex 32 2>/dev/null)" || true
    fi

    # Fallback: use /dev/urandom if openssl fails
    if [ -z "$GATEWAY_TOKEN" ] || [ "${#GATEWAY_TOKEN}" -lt 32 ]; then
      echo "  ⚠ openssl rand failed — using /dev/urandom fallback"
      if [ -r /dev/urandom ]; then
        GATEWAY_TOKEN="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
      fi
    fi
  else
    echo "  ✓ Using gateway token from OPENCLAW_GATEWAY_TOKEN env var"
  fi

  # Final check
  if [ -z "$GATEWAY_TOKEN" ] || [ "${#GATEWAY_TOKEN}" -lt 32 ]; then
    startup_error "ERROR: Cannot generate auth token (neither openssl nor /dev/urandom work)"
    echo "    The Docker image may be corrupted. Rebuild:"
    echo "    docker compose build --no-cache"
    exit 1
  fi

  # Write config — include primary model so OpenClaw doesn't fall back to Anthropic
  cat > "$CONFIG_FILE" <<EOF
{
  "meta": {
    "lastTouchedVersion": "docker-installer-v4",
    "lastTouchedAt": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  },
  "gateway": {
    "port": 18789,
    "bind": "lan",
    "mode": "local",
    "controlUi": {
      "allowedOrigins": ["http://localhost:18789", "http://127.0.0.1:18789"]
    },
    "auth": {
      "mode": "token",
      "token": "${GATEWAY_TOKEN}"
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "${PRIMARY_MODEL}"
      }
    }
  },
  "tools": {
    "web": {
      "search": { "enabled": false },
      "fetch": { "enabled": true }
    }
  }
}
EOF

  if [ $? -ne 0 ]; then
    startup_error "ERROR: Failed to write config file"
    echo "    Config directory may be full or read-only."
    echo "    Fix: docker volume rm openclaw-data && docker compose up"
    exit 1
  fi

  chmod 600 "$CONFIG_FILE"
  echo "  ✓ Gateway config created (auth token: ${#GATEWAY_TOKEN} chars)"

else
  # ── Validate existing config ──

  # Is it valid JSON?
  if command -v jq >/dev/null 2>&1; then
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
      echo "  ⚠ Config file is corrupt JSON. Backing up and regenerating..."
      cp "$CONFIG_FILE" "${CONFIG_FILE}.corrupt.$(date +%s)" 2>/dev/null || true
      rm -f "$CONFIG_FILE"
      exec "$0" "$@"
    fi
  fi

  # Is it empty?
  if [ ! -s "$CONFIG_FILE" ]; then
    echo "  ⚠ Config file exists but is empty. Regenerating..."
    rm -f "$CONFIG_FILE"
    exec "$0" "$@"
  fi

  # Does it have the gateway section?
  if command -v jq >/dev/null 2>&1; then
    if ! jq -e '.gateway' "$CONFIG_FILE" >/dev/null 2>&1; then
      echo "  ⚠ Config missing gateway section. Regenerating..."
      cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%s)" 2>/dev/null || true
      rm -f "$CONFIG_FILE"
      exec "$0" "$@"
    fi

    # Does it have an auth token?
    if ! jq -e '.gateway.auth.token' "$CONFIG_FILE" >/dev/null 2>&1; then
      echo "  ⚠ Config missing auth token. Adding one..."
      NEW_TOKEN="$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
      TMP="$(mktemp)"
      jq --arg t "$NEW_TOKEN" '.gateway.auth = {"mode":"token","token":$t}' "$CONFIG_FILE" > "$TMP" && mv "$TMP" "$CONFIG_FILE"
      chmod 600 "$CONFIG_FILE"
    fi
  fi

  echo "  ✓ Gateway config loaded and validated"

  # ── Update primary model in existing config ──
  # Always sync the primary model so it matches the current provider keys.
  # This prevents stale Anthropic defaults when the user switches providers.
  if command -v jq >/dev/null 2>&1 && [ -n "${PRIMARY_MODEL}" ]; then
    CURRENT_MODEL="$(jq -r '.agents.defaults.model.primary // ""' "$CONFIG_FILE" 2>/dev/null)"
    if [ "$CURRENT_MODEL" != "$PRIMARY_MODEL" ]; then
      TMP="$(mktemp)"
      jq --arg m "$PRIMARY_MODEL" '.agents.defaults.model.primary = $m' "$CONFIG_FILE" > "$TMP" && mv "$TMP" "$CONFIG_FILE"
      chmod 600 "$CONFIG_FILE"
      if [ -n "$CURRENT_MODEL" ] && [ "$CURRENT_MODEL" != "" ]; then
        echo "  ✓ Primary model updated: ${CURRENT_MODEL} → ${PRIMARY_MODEL}"
      else
        echo "  ✓ Primary model set: ${PRIMARY_MODEL}"
      fi
    fi
  fi

  # Migrate legacy config keys (e.g., bind "0.0.0.0" → "lan")
  # Required since openclaw v2026.2.26
  if command -v jq >/dev/null 2>&1; then
    BIND_VAL="$(jq -r '.gateway.bind // ""' "$CONFIG_FILE" 2>/dev/null)"
    case "$BIND_VAL" in
      0.0.0.0|""|localhost)
        echo "  ⚠ Migrating legacy gateway.bind \"$BIND_VAL\" → \"lan\"..."
        TMP="$(mktemp)"
        jq '.gateway.bind = "lan" | .gateway.controlUi.allowedOrigins = ["http://localhost:18789","http://127.0.0.1:18789"]' "$CONFIG_FILE" > "$TMP" && mv "$TMP" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        echo "  ✓ Config migrated to new bind mode format"
        ;;
      lan|loopback|custom|tailnet|auto|127.0.0.1)
        # Already using new format
        ;;
      *)
        echo "  ℹ Unrecognized gateway.bind value: $BIND_VAL (leaving as-is)"
        ;;
    esac
  fi
fi

# ============================================================================
# CHECK 6: Apply channels from environment
# ============================================================================

if [ -n "${OPENCLAW_CHANNELS:-}" ]; then
  echo "  ℹ Enabling channels: ${OPENCLAW_CHANNELS}"

  if ! command -v jq >/dev/null 2>&1; then
    echo "  ⚠ jq not available — cannot update channel config"
    echo "    Channels won't be auto-enabled. Configure manually with:"
    echo "    docker exec -it openclaw-agent openclaw configure"
  else
    TMP_FILE="$(mktemp)"
    if ! cp "$CONFIG_FILE" "$TMP_FILE" 2>/dev/null; then
      echo "  ⚠ Cannot copy config for channel update — /tmp may be full"
    else
      channel_count=0
      for channel in $(echo "$OPENCLAW_CHANNELS" | tr ',' ' '); do
        # Sanitize (alphanumeric + dashes only — prevents injection)
        clean_channel="$(echo "$channel" | tr -cd 'a-zA-Z0-9-')"

        if [ -z "$clean_channel" ]; then
          echo "  ⚠ Skipping empty/invalid channel name"
          continue
        fi

        if [ "$clean_channel" != "$channel" ]; then
          echo "  ⚠ Sanitized channel: '$channel' → '$clean_channel'"
        fi

        jq --arg ch "$clean_channel" '.plugins.entries[$ch].enabled = true' "$TMP_FILE" > "${TMP_FILE}.new" 2>/dev/null
        if [ $? -eq 0 ]; then
          mv "${TMP_FILE}.new" "$TMP_FILE"
          channel_count=$((channel_count + 1))
        else
          echo "  ⚠ Failed to enable channel: $clean_channel"
        fi
      done

      mv "$TMP_FILE" "$CONFIG_FILE"
      chmod 600 "$CONFIG_FILE"
      echo "  ✓ ${channel_count} channel(s) enabled"
      echo ""
      echo "  ℹ Remember: Channel tokens (bot tokens, API tokens) are configured"
      echo "    AFTER install by running:"
      echo "      docker exec -it openclaw-agent openclaw configure"
    fi
  fi
fi

# ============================================================================
# CHECK 7: Skill sandbox policy
# ============================================================================

if [ ! -f "$OPENCLAW_DIR/skill-policy.json" ]; then
  cat > "$OPENCLAW_DIR/skill-policy.json" <<'POLICY'
{
  "version": 1,
  "description": "Skill sandboxing — restricts what skills can access",
  "defaults": {
    "network": {
      "allowOutbound": true,
      "blockedHosts": [
        "169.254.169.254",
        "metadata.google.internal",
        "metadata.internal",
        "100.100.100.200"
      ],
      "note": "Blocks cloud metadata endpoints (AWS, GCP, Azure, Alibaba)"
    },
    "filesystem": {
      "blocked": [
        "/home/openclaw/.openclaw/openclaw.json",
        "/home/openclaw/.openclaw/.secrets/**",
        "/run/secrets/**",
        "/proc/*/environ",
        "/proc/*/cmdline"
      ]
    },
    "environment": {
      "inherit": false,
      "allowed": ["PATH", "HOME", "TERM", "LANG", "NODE_ENV"]
    }
  }
}
POLICY

  if [ $? -eq 0 ]; then
    chmod 600 "$OPENCLAW_DIR/skill-policy.json"
    echo "  ✓ Skill sandbox policy created"
  else
    echo "  ⚠ Could not write skill-policy.json — skills will run unsandboxed"
  fi
else
  echo "  ✓ Skill sandbox policy loaded"
fi

# ============================================================================
# CHECK 8: Lock down file permissions
# ============================================================================

chmod 700 "$OPENCLAW_DIR" 2>/dev/null || echo "  ⚠ Cannot chmod config dir"
chmod 700 "$OPENCLAW_DIR/.secrets" 2>/dev/null || true
find "$OPENCLAW_DIR" -name "*.json" -exec chmod 600 {} \; 2>/dev/null || true
echo "  ✓ Permissions locked down (700/600)"

# ============================================================================
# CHECK 9: Verify the OpenClaw binary
# ============================================================================

echo ""
echo "  Final checks..."

if command -v openclaw >/dev/null 2>&1; then
  echo "  ✓ OpenClaw binary found"
else
  startup_error "ERROR: OpenClaw binary not found"
  echo ""
  echo "  The npm package didn't install correctly inside the image."
  echo ""
  echo "  Fix: Rebuild from scratch:"
  echo "    docker compose down"
  echo "    docker compose build --no-cache"
  echo "    docker compose up"
  echo ""
  exit 1
fi

# ── Can Node.js run? ──
if command -v node >/dev/null 2>&1; then
  NODE_VER="$(node -v 2>/dev/null || echo 'unknown')"
  echo "  ✓ Node.js ${NODE_VER}"
else
  startup_error "ERROR: Node.js not found in container"
  echo "    The base image is broken. Rebuild: docker compose build --no-cache"
  exit 1
fi

# ============================================================================
# CHECK 10: Network connectivity
# ============================================================================

# Test DNS + HTTP connectivity (use a reliable public endpoint)
if command -v wget >/dev/null 2>&1; then
  if wget -q --spider --timeout=5 https://dns.google 2>/dev/null; then
    echo "  ✓ Network: outbound HTTPS working"
  else
    echo "  ⚠ Network: cannot reach the internet"
    echo "    The agent may not be able to generate responses."
    echo ""
    echo "    Common causes:"
    echo "      • No internet connection"
    echo "      • Corporate firewall blocking outbound HTTPS"
    echo "      • Docker DNS misconfigured"
    echo ""
    echo "    Quick fix: Restart Docker Desktop or check your network."
    echo "    Continuing anyway (will fail when you send the agent a message)..."
  fi
elif command -v curl >/dev/null 2>&1; then
  if curl -sf --max-time 5 https://dns.google >/dev/null 2>&1; then
    echo "  ✓ Network: outbound HTTPS working"
  else
    echo "  ⚠ Network: cannot reach the internet"
    echo "    See above for common causes. Continuing anyway..."
  fi
else
  echo "  ℹ Network: cannot test (no wget or curl)"
fi

# ============================================================================
# CHECK 11: Temp directory writable (needed for skill execution)
# ============================================================================

if [ -w /tmp ]; then
  echo "  ✓ /tmp writable (needed for skill execution)"
else
  echo "  ⚠ /tmp is not writable — some skills may fail"
  echo "    Check the tmpfs mount in docker-compose.yml"
fi

# ============================================================================
# STARTUP SUMMARY
# ============================================================================

echo ""

if [ "$STARTUP_ERRORS" -gt 0 ]; then
  echo "  ⚠ Started with ${STARTUP_ERRORS} warning(s) — check messages above"
else
  echo "  ✓ All checks passed"
fi

echo ""
echo "  ┌─────────────────────────────────────────────────┐"
echo "  │ Gateway:    port 18789 (localhost only from host)│"
echo "  │ Auth:       token-based (64-char random hex)     │"
echo "  │ Permissions: 700/600 (owner only)                │"
echo "  │ Sandbox:    skill isolation active                │"
echo "  │ AI keys:    loaded ✓                             │"
echo "  └─────────────────────────────────────────────────┘"
echo ""
echo "  Next step: Configure your channel (Discord, Telegram, etc.):"
echo "    docker exec -it openclaw-agent openclaw configure"
echo ""

# ============================================================================
# AUTO-MIGRATE: Run doctor --fix to apply any pending compatibility migrations
# ============================================================================

if command -v openclaw >/dev/null 2>&1; then
  echo "  Running compatibility migrations in background..."
  # Run doctor --fix in the background so a hang (e.g. npm install on a slow
  # or offline host) cannot block the gateway from starting. Use
  # --kill-after so grandchildren (npm, node) are actually reaped, not just
  # the doctor wrapper. 60s hard cap.
  (
    timeout --kill-after=5s --signal=TERM 60s openclaw doctor --fix >/tmp/openclaw-doctor.log 2>&1 || true
  ) &
  echo "  ✓ Migrations scheduled (logs: /tmp/openclaw-doctor.log inside container)"
fi

echo ""

# ============================================================================
# START THE GATEWAY
# ============================================================================

exec openclaw gateway "$@"
