#!/usr/bin/env bash
# ============================================================================
# patch-primary-model.sh
# Detects which provider key is set in .env and writes OPENCLAW_PRIMARY_MODEL
# accordingly. Run from the openclaw-docker-installer project root.
# ============================================================================

set -euo pipefail
ENV_FILE=".env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Run from the project root."
  exit 1
fi

# Source .env to read current key values (ignore errors from comments/blanks)
set +e
source "$ENV_FILE" 2>/dev/null
set -e

detect_model() {
  # Walk providers — first non-empty key wins
  if   [[ -n "${ANTHROPIC_API_KEY:-}"            ]]; then echo "anthropic/claude-sonnet-4-20250514"
  elif [[ -n "${OPENAI_API_KEY:-}"               ]]; then echo "openai/gpt-4o-mini"
  elif [[ -n "${OPENROUTER_API_KEY:-}"           ]]; then echo "openrouter/auto"
  elif [[ -n "${GOOGLE_API_KEY:-}"               ]]; then echo "google/gemini-2.0-flash"
  elif [[ -n "${GOOGLE_GENERATIVE_AI_API_KEY:-}" ]]; then echo "google/gemini-2.5-flash"
  elif [[ -n "${GEMINI_API_KEY:-}"               ]]; then echo "google/gemini-2.5-flash"
  elif [[ -n "${MISTRAL_API_KEY:-}"              ]]; then echo "mistral/mistral-large-latest"
  elif [[ -n "${GROQ_API_KEY:-}"                 ]]; then echo "groq/llama-3.3-70b-versatile"
  elif [[ -n "${DEEPSEEK_API_KEY:-}"             ]]; then echo "deepseek/deepseek-chat"
  elif [[ -n "${COHERE_API_KEY:-}"               ]]; then echo "cohere/command-r-plus"
  elif [[ -n "${XAI_API_KEY:-}"                  ]]; then echo "xai/grok-3"
  elif [[ -n "${CEREBRAS_API_KEY:-}"             ]]; then echo "cerebras/llama-3.3-70b"
  elif [[ -n "${MOONSHOT_API_KEY:-}"             ]]; then echo "kimi-coding/k2p5"
  elif [[ -n "${KIMI_API_KEY:-}"                 ]]; then echo "kimi-coding/k2p5"
  else
    echo ""
  fi
}

PRIMARY=$(detect_model)

if [[ -z "$PRIMARY" ]]; then
  echo "ERROR: No provider API key detected in $ENV_FILE."
  echo "Set at least one of: ANTHROPIC_API_KEY, OPENAI_API_KEY, GOOGLE_API_KEY, etc."
  exit 1
fi

# Write or update OPENCLAW_PRIMARY_MODEL in .env
if grep -q "^OPENCLAW_PRIMARY_MODEL=" "$ENV_FILE" 2>/dev/null; then
  # Update existing entry (macOS-compatible sed)
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "s|^OPENCLAW_PRIMARY_MODEL=.*|OPENCLAW_PRIMARY_MODEL=${PRIMARY}|" "$ENV_FILE"
  else
    sed -i "s|^OPENCLAW_PRIMARY_MODEL=.*|OPENCLAW_PRIMARY_MODEL=${PRIMARY}|" "$ENV_FILE"
  fi
  echo "Updated OPENCLAW_PRIMARY_MODEL=${PRIMARY} in $ENV_FILE"
elif grep -q "^# *OPENCLAW_PRIMARY_MODEL=" "$ENV_FILE" 2>/dev/null; then
  # Uncomment and set existing commented-out entry
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "s|^# *OPENCLAW_PRIMARY_MODEL=.*|OPENCLAW_PRIMARY_MODEL=${PRIMARY}|" "$ENV_FILE"
  else
    sed -i "s|^# *OPENCLAW_PRIMARY_MODEL=.*|OPENCLAW_PRIMARY_MODEL=${PRIMARY}|" "$ENV_FILE"
  fi
  echo "Uncommented and set OPENCLAW_PRIMARY_MODEL=${PRIMARY} in $ENV_FILE"
else
  # Append
  echo "" >> "$ENV_FILE"
  echo "OPENCLAW_PRIMARY_MODEL=${PRIMARY}" >> "$ENV_FILE"
  echo "Appended OPENCLAW_PRIMARY_MODEL=${PRIMARY} to $ENV_FILE"
fi

echo ""
echo "Restart the gateway to apply:"
echo "  docker compose restart openclaw"
