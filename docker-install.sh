#!/usr/bin/env bash
# ============================================================================
# OpenClaw Docker Installer — Super Easy, Beginner-Friendly, Auto-Healing
# ============================================================================
# If you can install Docker, you can run an AI agent. That's the promise.
#
# What this does:
#   1. Checks Docker + auto-fixes 15+ common issues beginners hit
#   2. Asks for your API key (one question, validated before continuing)
#   3. Builds & starts with automatic retry and diagnostics on failure
#   4. Runs a security audit and self-heals anything that's wrong
#   5. Opens the dashboard — type "hello" and get a response immediately
#
# Channels (Slack, Discord, Telegram, etc.) are optional — add later with:
#   ./docker-install.sh --channels
#
# Usage:
#   ./docker-install.sh
#   ./docker-install.sh --keys           # Change or fix your API key
#   ./docker-install.sh --channels      # Interactive channel picker
#   ./docker-install.sh --stop          # Stop the agent
#   ./docker-install.sh --uninstall     # Remove everything
#   ./docker-install.sh --status        # Check if agent is running
#   ./docker-install.sh --doctor        # Diagnose and fix problems
#   ./docker-install.sh --dry-run       # Preview without doing anything
#   ./docker-install.sh --help          # Show help
# ============================================================================

set -euo pipefail

# ── OS Detection ──────────────────────────────────────────────────────────────
# Detect OS early so we can set paths and behavior correctly.
# Windows users run this via Git Bash, MSYS2, or WSL.

detect_os() {
  local uname_out
  uname_out="$(uname -s 2>/dev/null || echo 'Unknown')"

  case "$uname_out" in
    Darwin)           HOST_OS="macos" ;;
    Linux)
      # Check if running inside WSL (Windows Subsystem for Linux)
      if grep -qi microsoft /proc/version 2>/dev/null; then
        HOST_OS="wsl"
      else
        HOST_OS="linux"
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*)  HOST_OS="windows" ;;
    *)                      HOST_OS="unknown" ;;
  esac
}

detect_os

# ── Globals ─────────────────────────────────────────────────────────────────

INSTALLER_VERSION="2.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Temp directory: Windows Git Bash uses /tmp mapped to AppData, which works fine
if [[ "$HOST_OS" == "windows" ]]; then
  LOG_FILE="${TEMP:-/tmp}/openclaw-docker-install-$(date +%Y%m%d-%H%M%S).log"
else
  LOG_FILE="/tmp/openclaw-docker-install-$(date +%Y%m%d-%H%M%S).log"
fi

# Lock down log file permissions (contains diagnostic info, not keys)
touch "$LOG_FILE" 2>/dev/null && chmod 600 "$LOG_FILE" 2>/dev/null || true

ENV_FILE="$SCRIPT_DIR/.env"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
CONTAINER_NAME="openclaw-agent"
GATEWAY_PORT=18789
IMAGE_NAME="openclaw-docker-installer-openclaw"

# Flags
FLAG_CHANNELS=false
FLAG_UNINSTALL=false
FLAG_STOP=false
FLAG_STATUS=false
FLAG_DOCTOR=false
FLAG_VERBOSE=false
FLAG_NO_COLOR=false
FLAG_DRY_RUN=false
FLAG_KEYS=false

# Re-run mode: "fresh" | "update_keys" | "restart_only" | "" (first install)
RERUN_MODE=""

# Track auto-fixes applied
FIXES_APPLIED=()

# Gateway token (generated during configure_keys, used in verify_and_finish)
GENERATED_GATEWAY_TOKEN=""

# ── Color Output ────────────────────────────────────────────────────────────

setup_colors() {
  if [[ "$FLAG_NO_COLOR" == true ]] || [[ ! -t 1 ]]; then
    BOLD="" DIM="" UNDERLINE="" RESET=""
    RED="" GREEN="" YELLOW="" BLUE="" CYAN="" MAGENTA=""
  else
    BOLD='\033[1m' DIM='\033[2m' UNDERLINE='\033[4m' RESET='\033[0m'
    RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
    BLUE='\033[0;34m' CYAN='\033[0;36m' MAGENTA='\033[0;35m'
  fi
}

# ── Logging ─────────────────────────────────────────────────────────────────

log()     { echo "[$(date +%H:%M:%S)] $*" >> "$LOG_FILE"; }
info()    { echo -e "  ${CYAN}ℹ${RESET}  $*"; log "INFO: $*"; }
success() { echo -e "  ${GREEN}✓${RESET}  $*"; log "OK: $*"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET}  $*"; log "WARN: $*"; }
error()   { echo -e "  ${RED}✗${RESET}  $*" >&2; log "ERROR: $*"; }
fatal()   { error "$*"; echo -e "\n  ${DIM}Log: $LOG_FILE${RESET}"; exit 1; }
step()    { echo -e "\n${BOLD}${BLUE}[$1/$2]${RESET} ${BOLD}$3${RESET}"; log "STEP $1/$2: $3"; }
verbose() { [[ "$FLAG_VERBOSE" == true ]] && info "$*" || log "VERBOSE: $*"; }
dry_run() { [[ "$FLAG_DRY_RUN" == true ]] && info "${DIM}[dry-run]${RESET} $*" && return 0 || return 1; }
fix()     { echo -e "  ${MAGENTA}↻${RESET}  ${BOLD}Auto-fix:${RESET} $*"; log "FIX: $*"; FIXES_APPLIED+=("$*"); }

banner() {
  echo ""
  echo -e "${BOLD}${RED}  🦞 OpenClaw Docker Installer ${DIM}v${INSTALLER_VERSION}${RESET}"
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  if [[ "$HOST_OS" == "windows" ]]; then
    echo -e "  ${DIM}Running on Windows (Git Bash/MSYS2)${RESET}"
  elif [[ "$HOST_OS" == "wsl" ]]; then
    echo -e "  ${DIM}Running on WSL (Windows Subsystem for Linux)${RESET}"
  fi
  echo ""
}

# ── Utility Functions ───────────────────────────────────────────────────────

command_exists() { command -v "$1" &>/dev/null; }

prompt_yn() {
  local prompt="$1" default="${2:-y}"
  local yn
  if [[ "$default" == "y" ]]; then
    read -rp "  $prompt [Y/n]: " yn
    yn="${yn:-y}"
  else
    read -rp "  $prompt [y/N]: " yn
    yn="${yn:-n}"
  fi
  [[ "$yn" =~ ^[Yy] ]]
}

prompt_secret() {
  local prompt="$1" varname="$2"
  local value
  echo -ne "  $prompt"
  read -rs value
  echo ""
  printf -v "$varname" '%s' "$value"
}

# ── Parse Arguments ─────────────────────────────────────────────────────────

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --channels)     FLAG_CHANNELS=true ;;
      --uninstall)    FLAG_UNINSTALL=true ;;
      --stop)         FLAG_STOP=true ;;
      --status)       FLAG_STATUS=true ;;
      --doctor)       FLAG_DOCTOR=true ;;
      --verbose|-v)   FLAG_VERBOSE=true ;;
      --no-color)     FLAG_NO_COLOR=true ;;
      --dry-run)      FLAG_DRY_RUN=true ;;
      --keys)         FLAG_KEYS=true ;;
      --help|-h)      usage; exit 0 ;;
      *) warn "Unknown option: $1" ;;
    esac
    shift
  done
}

usage() {
  cat <<'USAGE'
Usage: ./docker-install.sh [OPTIONS]

Options:
  --channels        Add chat channels (Slack, Discord, Telegram, etc.)
  --stop            Stop the running agent
  --status          Check if the agent is running
  --doctor          Diagnose and auto-fix common problems
  --uninstall       Remove containers, images, and data
  --verbose, -v     Show detailed output
  --no-color        Disable colored output
  --keys            Re-enter or change your AI provider API keys
  --dry-run         Preview actions without executing
  --help, -h        Show this help message

Examples:
  ./docker-install.sh                  # Install → type "hello" in browser
  ./docker-install.sh --keys           # Change or fix your API key
  ./docker-install.sh --channels       # Add Slack/Discord/Telegram later
  ./docker-install.sh --stop           # Stop the agent
  ./docker-install.sh --status         # Is it running?
  ./docker-install.sh --doctor         # Something broken? Run this
  ./docker-install.sh --uninstall      # Remove everything
USAGE
}

# ── Compose command helper ──
compose_cmd() {
  if docker compose version &>/dev/null 2>&1; then
    docker compose -f "$COMPOSE_FILE" "$@"
  else
    docker-compose -f "$COMPOSE_FILE" "$@"
  fi
}

# ============================================================================
# PHASE 1: Pre-Flight Checks + Auto-Troubleshooting
# ============================================================================

preflight_checks() {
  step 1 4 "Pre-flight checks"

  check_docker_installed
  check_docker_running
  check_docker_compose
  check_docker_permissions
  check_docker_version
  check_disk_space
  check_port_available
  check_existing_container
  check_network_connectivity
}

check_docker_installed() {
  if command_exists docker; then
    success "Docker is installed"
    return 0
  fi

  echo ""
  echo -e "  ${YELLOW}Docker is not installed.${RESET}"
  echo ""
  echo -e "  Docker is a free tool that runs apps in isolated containers."
  echo -e "  It's like a mini computer inside your computer — safe and easy to clean up."
  echo ""

  # Offer to auto-install on supported platforms
  case "$HOST_OS" in
    macos)
      local docker_installed=false

      # ── Attempt 1: Homebrew ──
      if command_exists brew; then
        echo -e "  ${BOLD}Homebrew detected.${RESET} We can install Docker for you."
        echo ""
        if prompt_yn "Install Docker Desktop via Homebrew?" "y"; then
          fix "Installing Docker Desktop via Homebrew..."
          info "This may take a few minutes. Please wait..."
          echo ""

          # Update Homebrew first (stale taps are the #1 cause of cask failures)
          log "Updating Homebrew..."
          brew update >> "$LOG_FILE" 2>&1 || true

          if brew install --cask docker >> "$LOG_FILE" 2>&1; then
            docker_installed=true
          else
            # ── Attempt 2: Clean retry ──
            warn "First attempt failed. Cleaning up and retrying..."
            log "Homebrew cask install failed. Checking common causes..."

            # Fix: stale cask cache
            brew cleanup >> "$LOG_FILE" 2>&1 || true

            # Fix: quarantine / Gatekeeper issues
            if brew install --cask docker --no-quarantine >> "$LOG_FILE" 2>&1; then
              docker_installed=true
            else
              # ── Attempt 3: Direct DMG download ──
              warn "Homebrew install failed twice. Trying direct download..."
              log "Attempting direct Docker Desktop DMG download"

              local arch
              arch="$(uname -m)"
              local dmg_url=""
              if [[ "$arch" == "arm64" ]]; then
                dmg_url="https://desktop.docker.com/mac/main/arm64/Docker.dmg"
              else
                dmg_url="https://desktop.docker.com/mac/main/amd64/Docker.dmg"
              fi

              local dmg_path="/tmp/Docker.dmg"
              if curl -fSL -o "$dmg_path" "$dmg_url" >> "$LOG_FILE" 2>&1; then
                info "Downloaded Docker Desktop. Installing..."
                # Mount, copy, unmount
                local mount_point
                mount_point="$(hdiutil attach "$dmg_path" -nobrowse 2>/dev/null | grep '/Volumes/' | awk '{print $NF}')" || true

                if [[ -n "$mount_point" ]] && [[ -d "$mount_point/Docker.app" ]]; then
                  cp -R "$mount_point/Docker.app" /Applications/ 2>/dev/null || \
                    sudo cp -R "$mount_point/Docker.app" /Applications/ >> "$LOG_FILE" 2>&1 || true
                  hdiutil detach "$mount_point" -quiet 2>/dev/null || true
                  rm -f "$dmg_path"

                  if [[ -d "/Applications/Docker.app" ]]; then
                    docker_installed=true
                    success "Docker Desktop installed via direct download"
                  fi
                else
                  hdiutil detach "$mount_point" -quiet 2>/dev/null || true
                  rm -f "$dmg_path"
                fi
              fi
            fi
          fi
        fi
      else
        # ── No Homebrew: try direct DMG download ──
        echo -e "  ${BOLD}We can download and install Docker Desktop for you.${RESET}"
        echo ""
        if prompt_yn "Download and install Docker Desktop?" "y"; then
          local arch
          arch="$(uname -m)"
          local dmg_url=""
          if [[ "$arch" == "arm64" ]]; then
            dmg_url="https://desktop.docker.com/mac/main/arm64/Docker.dmg"
          else
            dmg_url="https://desktop.docker.com/mac/main/amd64/Docker.dmg"
          fi

          info "Downloading Docker Desktop (this may take a few minutes)..."
          local dmg_path="/tmp/Docker.dmg"
          if curl -fSL -o "$dmg_path" "$dmg_url" >> "$LOG_FILE" 2>&1; then
            info "Installing..."
            local mount_point
            mount_point="$(hdiutil attach "$dmg_path" -nobrowse 2>/dev/null | grep '/Volumes/' | awk '{print $NF}')" || true

            if [[ -n "$mount_point" ]] && [[ -d "$mount_point/Docker.app" ]]; then
              cp -R "$mount_point/Docker.app" /Applications/ 2>/dev/null || \
                sudo cp -R "$mount_point/Docker.app" /Applications/ >> "$LOG_FILE" 2>&1 || true
              hdiutil detach "$mount_point" -quiet 2>/dev/null || true
              rm -f "$dmg_path"

              if [[ -d "/Applications/Docker.app" ]]; then
                docker_installed=true
                success "Docker Desktop installed"
              fi
            else
              hdiutil detach "$mount_point" -quiet 2>/dev/null || true
              rm -f "$dmg_path"
            fi
          else
            error "Download failed. Check your internet connection."
          fi
        fi
      fi

      if [[ "$docker_installed" == true ]]; then
        echo ""
        info "Opening Docker Desktop..."
        open -a Docker 2>/dev/null || true

        # Wait for Docker to start (up to 90 seconds)
        info "Waiting for Docker to start (this takes 30-60 seconds on first launch)..."
        local wait_count=0
        while [[ $wait_count -lt 90 ]]; do
          if command_exists docker && docker info &>/dev/null 2>&1; then
            success "Docker is running"
            return 0
          fi
          wait_count=$((wait_count + 1))
          sleep 1
          if [[ $((wait_count % 15)) -eq 0 ]]; then
            info "Still starting... (${wait_count}s)"
          fi
        done

        # Docker installed but not ready yet — keep waiting instead of quitting
        warn "Docker Desktop is still starting (this can take 2+ minutes on first launch)..."
        info "Waiting a bit longer..."
        local extra_wait=0
        while [[ $extra_wait -lt 120 ]]; do
          if command_exists docker && docker info &>/dev/null 2>&1; then
            success "Docker is running"
            return 0
          fi
          extra_wait=$((extra_wait + 2))
          sleep 2
          if [[ $((extra_wait % 15)) -eq 0 ]]; then
            info "Still starting... ($((wait_count + extra_wait))s total) — be patient, first launch is slow"
          fi
        done

        # Truly timed out after 90 + 120 = ~210 seconds
        warn "Docker Desktop installed but still not responding after ~3 minutes."
        info "Please wait for the whale icon in your menu bar to stop animating, then re-run:"
        echo -e "    ${BOLD}./docker-install.sh${RESET}"
        echo ""
        exit 0
      fi

      # All auto-install attempts failed — show manual instructions
      echo ""
      echo -e "  ${BOLD}Automatic install didn't work. Here's how to do it manually:${RESET}"
      echo ""
      echo -e "    1. Go to ${UNDERLINE}https://docker.com/products/docker-desktop${RESET}"
      echo -e "    2. Click \"Download for Mac\""
      echo -e "    3. Open the .dmg file and drag Docker to Applications"
      echo -e "    4. Open Docker from your Applications folder"
      echo -e "    5. Wait for the whale icon in your menu bar"
      echo -e "    6. Re-run: ${BOLD}./docker-install.sh${RESET}"
      echo ""
      ;;
    linux|wsl)
      echo -e "  ${BOLD}We can try to install Docker for you.${RESET}"
      echo ""
      if prompt_yn "Auto-install Docker via get.docker.com?" "y"; then
        fix "Installing Docker via get.docker.com"
        curl -fsSL https://get.docker.com | sh >> "$LOG_FILE" 2>&1 || {
          error "Automatic install failed."
          info "Try manually: ${BOLD}curl -fsSL https://get.docker.com | sh${RESET}"
          exit 1
        }
        # Add user to docker group
        if ! groups 2>/dev/null | grep -q docker; then
          fix "Adding your user to the docker group"
          sudo usermod -aG docker "$USER" >> "$LOG_FILE" 2>&1 || true
          warn "You need to log out and back in for group changes to take effect."
          warn "After logging back in, re-run: ${BOLD}./docker-install.sh${RESET}"
          exit 0
        fi
        # Start docker
        sudo systemctl start docker >> "$LOG_FILE" 2>&1 || sudo service docker start >> "$LOG_FILE" 2>&1 || true
        success "Docker installed"
        return 0
      fi
      echo -e "  ${BOLD}To install Docker on Linux:${RESET}"
      echo ""
      echo -e "    ${CYAN}Ubuntu/Debian:${RESET}"
      echo -e "    → Run: ${BOLD}curl -fsSL https://get.docker.com | sh${RESET}"
      echo -e "    → Then: ${BOLD}sudo usermod -aG docker \$USER${RESET}"
      echo -e "    → Log out and back in"
      echo ""
      echo -e "    ${CYAN}Fedora:${RESET}"
      echo -e "    → Run: ${BOLD}sudo dnf install docker-ce${RESET}"
      echo ""
      ;;
    windows)
      echo -e "  ${BOLD}To install Docker on Windows:${RESET}"
      echo ""
      echo -e "    ${CYAN}Step 1: Install Docker Desktop${RESET}"
      echo -e "    → Go to ${UNDERLINE}https://docker.com/products/docker-desktop${RESET}"
      echo -e "    → Click \"Download for Windows\""
      echo -e "    → Run the installer (.exe)"
      echo -e "    → Restart your computer if prompted"
      echo ""
      echo -e "    ${CYAN}Step 2: Open Docker Desktop${RESET}"
      echo -e "    → Search for \"Docker Desktop\" in the Start Menu"
      echo -e "    → Wait for the whale icon in the system tray to stop animating"
      echo ""
      echo -e "    ${CYAN}Step 3: Open Git Bash and re-run this script${RESET}"
      echo -e "    → Right-click in the project folder → \"Git Bash Here\""
      echo -e "    → Run: ${BOLD}./docker-install.sh${RESET}"
      echo ""
      ;;
    *)
      echo -e "  Visit ${UNDERLINE}https://docs.docker.com/get-docker/${RESET} for install instructions."
      echo ""
      ;;
  esac

  echo -e "  After installing Docker, run this script again:"
  echo -e "    ${BOLD}./docker-install.sh${RESET}"
  echo ""
  exit 1
}

check_docker_running() {
  if docker info &>/dev/null 2>&1; then
    success "Docker daemon is running"
    return 0
  fi

  warn "Docker is installed but not running"

  # ── Auto-fix: Try to start Docker ──
  case "$HOST_OS" in
    macos)
      fix "Opening Docker Desktop..."
      open -a Docker 2>/dev/null || true

      # First launch can take 2+ minutes (VM init, component download)
      info "Waiting for Docker to start (first launch can take up to 2 minutes)..."
      local wait_count=0
      while [[ $wait_count -lt 150 ]]; do
        if docker info &>/dev/null 2>&1; then
          success "Docker is now running"
          return 0
        fi
        sleep 2
        wait_count=$((wait_count + 2))
        if [[ $((wait_count % 15)) -eq 0 ]]; then
          info "Still starting... (${wait_count}s) — this is normal on first launch"
        fi
      done

      # Still not running — try one more thing: kill and relaunch
      warn "Docker is slow to start. Trying to restart it..."
      pkill -f "Docker Desktop" 2>/dev/null || true
      sleep 3
      open -a Docker 2>/dev/null || true

      local retry_count=0
      while [[ $retry_count -lt 60 ]]; do
        if docker info &>/dev/null 2>&1; then
          success "Docker is now running"
          return 0
        fi
        sleep 2
        retry_count=$((retry_count + 2))
      done

      # Last resort: ask user to open manually but DON'T exit
      warn "Docker Desktop is taking longer than expected."
      echo ""
      echo -e "  ${BOLD}Please open Docker Desktop manually:${RESET}"
      echo -e "    → Open ${BOLD}Finder → Applications → Docker${RESET}"
      echo -e "    → Wait for the whale icon in your menu bar to stop animating"
      echo ""
      read -rp "  Press Enter once Docker is running... "
      echo ""

      if docker info &>/dev/null 2>&1; then
        success "Docker is now running"
        return 0
      fi

      error "Docker still not responding."
      echo -e "  ${BOLD}Fix:${RESET} Restart your Mac, open Docker Desktop, then re-run:"
      echo -e "    ${BOLD}./docker-install.sh${RESET}"
      exit 1
      ;;
    windows)
      fix "Trying to start Docker Desktop..."
      cmd.exe /c "start \"\" \"C:\\Program Files\\Docker\\Docker\\Docker Desktop.exe\"" >> "$LOG_FILE" 2>&1 || \
        powershell.exe -Command "Start-Process 'Docker Desktop'" >> "$LOG_FILE" 2>&1 || true

      info "Waiting for Docker to start (first launch can take up to 2 minutes)..."
      local wait_count=0
      while [[ $wait_count -lt 150 ]]; do
        if docker info &>/dev/null 2>&1; then
          success "Docker is now running"
          return 0
        fi
        sleep 2
        wait_count=$((wait_count + 2))
        if [[ $((wait_count % 15)) -eq 0 ]]; then
          info "Still starting... (${wait_count}s) — this is normal on first launch"
        fi
      done

      warn "Docker Desktop is taking longer than expected."
      echo ""
      echo -e "  ${BOLD}Please open Docker Desktop manually:${RESET}"
      echo -e "    → Open the ${BOLD}Start Menu${RESET} → search for ${BOLD}Docker Desktop${RESET} → click it"
      echo -e "    → Wait for the whale icon in the system tray to stop animating"
      echo ""
      read -rp "  Press Enter once Docker is running... "
      echo ""

      if docker info &>/dev/null 2>&1; then
        success "Docker is now running"
        return 0
      fi

      error "Docker still not responding."
      echo -e "  ${BOLD}Fix:${RESET} Restart your computer, open Docker Desktop, then re-run:"
      echo -e "    ${BOLD}./docker-install.sh${RESET}"
      exit 1
      ;;
    wsl)
      # WSL uses Docker Desktop from Windows host, or dockerd directly
      if command_exists systemctl; then
        fix "Starting Docker daemon via systemctl..."
        sudo systemctl start docker >> "$LOG_FILE" 2>&1 && {
          success "Docker daemon started"
          return 0
        }
      fi
      error "Docker is not running."
      echo ""
      echo -e "  ${BOLD}If using Docker Desktop for Windows:${RESET}"
      echo -e "    1. Open ${BOLD}Docker Desktop${RESET} on Windows"
      echo -e "    2. Go to Settings → Resources → WSL Integration"
      echo -e "    3. Enable integration with your WSL distro"
      echo -e "    4. Re-run: ${BOLD}./docker-install.sh${RESET}"
      echo ""
      echo -e "  ${BOLD}If using native Docker in WSL:${RESET}"
      echo -e "    ${BOLD}sudo service docker start${RESET}"
      echo ""
      exit 1
      ;;
    linux)
      fix "Starting Docker daemon..."
      if command_exists systemctl; then
        sudo systemctl start docker >> "$LOG_FILE" 2>&1 && {
          success "Docker daemon started"
          return 0
        }
      elif command_exists service; then
        sudo service docker start >> "$LOG_FILE" 2>&1 && {
          success "Docker daemon started"
          return 0
        }
      fi

      error "Could not start Docker."
      echo ""
      echo -e "  ${BOLD}Try:${RESET}"
      echo -e "    ${BOLD}sudo systemctl start docker${RESET}"
      echo -e "    ${BOLD}sudo systemctl enable docker${RESET}  (to start on boot)"
      echo ""
      exit 1
      ;;
    *)
      error "Could not start Docker."
      echo -e "  Please start Docker manually, then re-run: ${BOLD}./docker-install.sh${RESET}"
      exit 1
      ;;
  esac
}

check_docker_compose() {
  if docker compose version &>/dev/null 2>&1; then
    local compose_ver
    compose_ver="$(docker compose version --short 2>/dev/null || echo 'v2+')"
    success "Docker Compose available (${compose_ver})"
    return 0
  fi

  if command_exists docker-compose; then
    local compose_ver
    compose_ver="$(docker-compose --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo 'v1')"
    success "Docker Compose available (legacy v${compose_ver})"
    return 0
  fi

  # ── Auto-fix: Try to install docker-compose ──
  warn "Docker Compose not found"

  if [[ "$HOST_OS" == "linux" || "$HOST_OS" == "wsl" ]]; then
    fix "Installing Docker Compose plugin..."
    sudo apt-get update -qq >> "$LOG_FILE" 2>&1 || true
    sudo apt-get install -y docker-compose-plugin >> "$LOG_FILE" 2>&1 || {
      # Fallback: standalone binary
      fix "Trying standalone docker-compose binary..."
      local arch
      arch="$(uname -m)"
      sudo curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}" \
        -o /usr/local/bin/docker-compose >> "$LOG_FILE" 2>&1 || {
        fatal "Could not install Docker Compose. Please update Docker Desktop or install docker-compose manually."
      }
      sudo chmod +x /usr/local/bin/docker-compose
    }
    success "Docker Compose installed"
    return 0
  fi

  fatal "Docker Compose not found. Please update Docker Desktop (it includes Compose)."
}

check_docker_permissions() {
  # Only relevant on Linux / WSL
  if [[ "$HOST_OS" != "linux" && "$HOST_OS" != "wsl" ]]; then return 0; fi

  if docker ps &>/dev/null 2>&1; then
    verbose "Docker permissions OK"
    return 0
  fi

  # Check if it's a permission issue specifically
  if docker ps 2>&1 | grep -qi "permission denied"; then
    warn "Your user doesn't have permission to use Docker"

    if groups 2>/dev/null | grep -q docker; then
      # User is in group but it hasn't taken effect
      fix "You're in the docker group but it hasn't taken effect yet"
      echo ""
      echo -e "  ${BOLD}You need to log out and back in${RESET}, or run:"
      echo -e "    ${BOLD}newgrp docker${RESET}"
      echo -e "  Then re-run: ${BOLD}./docker-install.sh${RESET}"
      echo ""
      exit 1
    else
      fix "Adding your user to the docker group..."
      sudo usermod -aG docker "$USER" >> "$LOG_FILE" 2>&1 || {
        error "Could not add user to docker group."
        echo -e "  Run manually: ${BOLD}sudo usermod -aG docker \$USER${RESET}"
        exit 1
      }
      echo ""
      echo -e "  ${GREEN}Added you to the docker group.${RESET}"
      echo -e "  ${BOLD}You need to log out and back in${RESET} for this to take effect."
      echo -e "  Then re-run: ${BOLD}./docker-install.sh${RESET}"
      echo ""
      exit 0
    fi
  fi
}

check_docker_version() {
  local docker_ver
  docker_ver="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '')"

  # If we couldn't get the version, Docker might still be starting up
  if [[ -z "$docker_ver" ]]; then
    verbose "Could not determine Docker version (daemon may still be initializing)"
    return 0
  fi

  # Extract major version (handle non-numeric gracefully)
  local major
  major="${docker_ver%%.*}"
  # Strip any non-numeric characters (e.g., "v27" → "27")
  major="${major//[^0-9]/}"

  if [[ -z "$major" ]]; then
    verbose "Docker version: ${docker_ver} (could not parse major version)"
    return 0
  fi

  if [[ "$major" -ge 20 ]] 2>/dev/null; then
    verbose "Docker version ${docker_ver} (meets minimum 20.x)"
    return 0
  fi

  warn "Docker version ${docker_ver} is old (recommend 20.x+)"
  info "Some security features may not work. Consider updating Docker."
  info "Update: ${UNDERLINE}https://docs.docker.com/engine/install/${RESET}"
}

check_disk_space() {
  local available_mb
  available_mb="$(df -m "$SCRIPT_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo '')"
  # Strip non-numeric characters
  available_mb="${available_mb//[^0-9]/}"
  available_mb="${available_mb:-0}"

  if [[ "$available_mb" -eq 0 ]] 2>/dev/null; then
    verbose "Could not determine disk space"
    return 0
  fi

  if [[ "$available_mb" -lt 1024 ]]; then
    warn "Low disk space: ${available_mb}MB available (need ~1GB for Docker image)"
    echo ""
    echo -e "  ${BOLD}To free up Docker space:${RESET}"
    echo -e "    ${BOLD}docker system prune -a${RESET}  (removes unused images/containers)"
    echo ""

    if [[ "$available_mb" -lt 512 ]]; then
      # Try to auto-clean
      if prompt_yn "Try to free space by cleaning unused Docker data?" "y"; then
        fix "Cleaning unused Docker data..."
        docker system prune -f >> "$LOG_FILE" 2>&1 || true

        # Re-check
        if [[ "$(uname -s)" == "Darwin" ]]; then
          available_mb=$(df -m "$SCRIPT_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
        else
          available_mb=$(df -m "$SCRIPT_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
        fi

        if [[ "$available_mb" -lt 512 ]]; then
          fatal "Still only ${available_mb}MB free. Need at least 512MB. Free up disk space and try again."
        fi
        success "Freed up space (${available_mb}MB now available)"
      fi
    fi
  else
    verbose "Disk space OK (${available_mb}MB available)"
  fi
}

# ── Cross-platform port check helpers ──
# Returns 0 if port is in use, 1 if free
_is_port_in_use() {
  local port="$1"
  if command_exists lsof; then
    lsof -i ":$port" -sTCP:LISTEN &>/dev/null 2>&1 && return 0
  elif command_exists ss; then
    ss -tlnp 2>/dev/null | grep -q ":$port " && return 0
  elif command_exists netstat; then
    # Windows netstat uses different flags than Linux
    if [[ "$HOST_OS" == "windows" ]]; then
      netstat -an 2>/dev/null | grep -q "LISTENING.*:$port " && return 0
      netstat -an 2>/dev/null | grep -q ":$port .*LISTENING" && return 0
    else
      netstat -tln 2>/dev/null | grep -q ":$port " && return 0
    fi
  fi
  return 1
}

# Get PID and name of process using a port (sets _PORT_PID and _PORT_NAME)
_get_port_blocker() {
  local port="$1"
  _PORT_PID=""
  _PORT_NAME=""

  if command_exists lsof; then
    _PORT_NAME="$(lsof -i ":$port" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1}' || echo '')"
    _PORT_PID="$(lsof -i ":$port" -sTCP:LISTEN -t 2>/dev/null | head -1 || echo '')"
  elif [[ "$HOST_OS" == "windows" ]] && command_exists netstat; then
    # On Windows, netstat -ano shows PID in last column
    local line
    line="$(netstat -ano 2>/dev/null | grep "LISTENING" | grep ":$port " | head -1 || echo '')"
    if [[ -n "$line" ]]; then
      _PORT_PID="$(echo "$line" | awk '{print $NF}' || echo '')"
      if [[ -n "$_PORT_PID" ]]; then
        _PORT_NAME="$(tasklist.exe //FI "PID eq $_PORT_PID" //FO CSV //NH 2>/dev/null | head -1 | cut -d',' -f1 | tr -d '"' || echo 'unknown')"
      fi
    fi
  fi
}

# Kill a process by PID (cross-platform)
_kill_process() {
  local pid="$1"
  if [[ "$HOST_OS" == "windows" ]]; then
    taskkill.exe //PID "$pid" //F >> "$LOG_FILE" 2>&1 || kill "$pid" 2>/dev/null || true
  else
    kill "$pid" 2>/dev/null || true
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
      sleep 1
    fi
  fi
}

check_port_available() {
  local our_container_running=false

  # Check if our container is already running
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "$CONTAINER_NAME"; then
    our_container_running=true
    verbose "Port $GATEWAY_PORT in use by our container (will be restarted in phase 3)"
  fi

  # Always check for non-Docker processes on the port, even if our container is running.
  # Phase 3 does `compose down` before `up`, so if a native node process is ALSO bound
  # to this port, it will block the container from restarting.
  if command_exists lsof; then
    local non_docker_pid=""
    non_docker_pid="$(lsof -i ":$GATEWAY_PORT" -sTCP:LISTEN -t 2>/dev/null | while read -r pid; do
      local cmd_name
      cmd_name="$(ps -p "$pid" -o comm= 2>/dev/null || echo '')"
      if [[ "$cmd_name" != *"com.docker"* && "$cmd_name" != *"containerd"* && "$cmd_name" != *"docker"* && "$cmd_name" != *"Docker"* ]]; then
        echo "$pid"
      fi
    done | head -1 || true)"

    if [[ -n "$non_docker_pid" ]]; then
      local non_docker_name
      non_docker_name="$(ps -p "$non_docker_pid" -o comm= 2>/dev/null || echo 'unknown')"
      warn "Non-Docker process $non_docker_name (PID $non_docker_pid) is also on port $GATEWAY_PORT"
      info "This will block the container from starting"
      if prompt_yn "Stop it to free the port?" "y"; then
        fix "Stopping process $non_docker_pid..."
        _kill_process "$non_docker_pid"
        success "Port blocker removed"
        FIXES_APPLIED+=("Stopped $non_docker_name (PID $non_docker_pid) blocking port $GATEWAY_PORT")
      else
        warn "Continuing — container may fail to bind port"
      fi
      return 0
    fi
  elif [[ "$HOST_OS" == "windows" ]]; then
    # On Windows, check for non-Docker processes via netstat
    _get_port_blocker "$GATEWAY_PORT"
    if [[ -n "$_PORT_PID" && "$_PORT_NAME" != "com.docker"* && "$_PORT_NAME" != "Docker"* ]]; then
      warn "Process $_PORT_NAME (PID $_PORT_PID) is using port $GATEWAY_PORT"
      info "This will block the container from starting"
      if prompt_yn "Stop it to free the port?" "y"; then
        fix "Stopping process $_PORT_PID..."
        _kill_process "$_PORT_PID"
        sleep 2
        success "Port blocker removed"
        FIXES_APPLIED+=("Stopped $_PORT_NAME (PID $_PORT_PID) blocking port $GATEWAY_PORT")
      else
        warn "Continuing — container may fail to bind port"
      fi
      return 0
    fi
  fi

  # If our container is running and no other process conflicts, we're fine
  if [[ "$our_container_running" == true ]]; then
    return 0
  fi

  # Check if something else is using the port
  if _is_port_in_use "$GATEWAY_PORT"; then
    warn "Port $GATEWAY_PORT is already in use by another application"

    # Identify what's using it
    _get_port_blocker "$GATEWAY_PORT"
    if [[ -n "$_PORT_NAME" ]]; then
      info "Used by: ${DIM}${_PORT_NAME} (PID ${_PORT_PID})${RESET}"
    fi

    # ── Auto-fix: If it's a node process (likely native OpenClaw), offer to kill it ──
    if [[ "$_PORT_NAME" == "node"* && -n "$_PORT_PID" ]]; then
      info "This looks like a previous OpenClaw run (native installer)"
      if prompt_yn "Stop it to free the port?" "y"; then
        fix "Stopping process $_PORT_PID..."
        _kill_process "$_PORT_PID"
        if _is_port_in_use "$GATEWAY_PORT"; then
          warn "Process didn't stop. Container may fail to bind port."
        else
          success "Port $GATEWAY_PORT is now free"
          FIXES_APPLIED+=("Stopped Node.js process (PID $_PORT_PID) blocking port $GATEWAY_PORT")
        fi
      else
        warn "Continuing — container may fail to bind port"
      fi

    # ── Auto-fix: If it's our own Docker container ──
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q "$CONTAINER_NAME"; then
      fix "Our own container is already using the port. Stopping it..."
      compose_cmd down >> "$LOG_FILE" 2>&1 || docker rm -f "$CONTAINER_NAME" >> "$LOG_FILE" 2>&1 || true
      sleep 1
      success "Previous container stopped"
      FIXES_APPLIED+=("Stopped previous OpenClaw container to free port $GATEWAY_PORT")

    # ── Manual fix needed ──
    else
      echo ""
      echo -e "  ${BOLD}Options:${RESET}"
      echo -e "    1. Stop the application using port $GATEWAY_PORT"
      if [[ -n "$_PORT_PID" ]]; then
        if [[ "$HOST_OS" == "windows" ]]; then
          echo -e "       ${CYAN}taskkill /PID $_PORT_PID /F${RESET}"
        else
          echo -e "       ${CYAN}kill $_PORT_PID${RESET}"
        fi
      fi
      echo -e "    2. Edit ${BOLD}docker-compose.yml${RESET} to use a different port"
      echo -e "       Change: ${CYAN}127.0.0.1:18789:18789${RESET} → ${CYAN}127.0.0.1:18790:18789${RESET}"
      echo ""

      if prompt_yn "Try to continue anyway? (might fail)" "y"; then
        warn "Continuing — container may fail to bind port"
      else
        exit 1
      fi
    fi
  else
    verbose "Port $GATEWAY_PORT is available"
  fi
}

show_rerun_menu() {
  echo ""
  echo -e "  ${BOLD}OpenClaw is already installed. What would you like to do?${RESET}"
  echo ""
  echo -e "    ${CYAN}1${RESET}) ${BOLD}Fresh install${RESET}      — wipe everything (containers, data, keys) and start over"
  echo -e "    ${CYAN}2${RESET}) ${BOLD}Update API keys${RESET}   — keep Docker, just change your provider keys"
  echo -e "    ${CYAN}3${RESET}) ${BOLD}Restart${RESET}           — keep everything as-is and restart the container"
  echo ""
  local choice=""
  while [[ -z "$choice" ]]; do
    read -rp "  Choose [1/2/3]: " choice
    case "$choice" in
      1) RERUN_MODE="fresh" ;;
      2) RERUN_MODE="update_keys" ;;
      3) RERUN_MODE="restart_only" ;;
      *) choice=""; warn "Please enter 1, 2, or 3" ;;
    esac
  done
}

check_existing_container() {
  # Check for stale/crashed containers with the same name
  local container_state
  container_state="$(docker inspect --format='{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo 'none')"

  # --keys flag: skip the re-run menu, just stop the container for key re-entry
  if [[ "$FLAG_KEYS" == true ]]; then
    if [[ "$container_state" == "running" ]]; then
      fix "Stopping container for key update..."
      compose_cmd down >> "$LOG_FILE" 2>&1 || true
    fi
    RERUN_MODE="update_keys"
    return 0
  fi

  case "$container_state" in
    running)
      local health
      health="$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo 'unknown')"

      echo ""
      if [[ "$health" == "healthy" ]]; then
        echo -e "  ${BOLD}${GREEN}OpenClaw is already running and healthy!${RESET}"
      else
        echo -e "  ${BOLD}${YELLOW}OpenClaw is running (health: ${health})${RESET}"
      fi

      # Show the dashboard URL for context
      local token
      token="$(grep '^OPENCLAW_GATEWAY_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
      if [[ -n "$token" ]]; then
        echo -e "  ${DIM}Dashboard: http://localhost:${GATEWAY_PORT}/#token=${token}${RESET}"
      fi

      show_rerun_menu

      case "$RERUN_MODE" in
        fresh)
          fix "Wiping existing installation..."
          compose_cmd down -v >> "$LOG_FILE" 2>&1 || true
          docker rmi "$(docker images --format '{{.ID}}' --filter "reference=*openclaw*" 2>/dev/null)" >> "$LOG_FILE" 2>&1 || true
          if [[ -f "$ENV_FILE" ]]; then
            rm -f "$ENV_FILE"
          fi
          success "Previous installation wiped — starting fresh"
          ;;
        update_keys)
          fix "Stopping container for key update..."
          compose_cmd down >> "$LOG_FILE" 2>&1 || true
          success "Container stopped — let's update your keys"
          ;;
        restart_only)
          fix "Restarting container..."
          compose_cmd restart >> "$LOG_FILE" 2>&1
          echo ""
          success "Container restarted"
          if [[ -n "$token" ]]; then
            echo ""
            echo -e "  ${BOLD}Dashboard:${RESET}"
            echo -e "    ${CYAN}${UNDERLINE}http://localhost:${GATEWAY_PORT}/#token=${token}${RESET}"
          fi
          exit 0
          ;;
      esac
      ;;
    exited|dead)
      fix "Removing crashed/stopped container from a previous run..."
      docker rm -f "$CONTAINER_NAME" >> "$LOG_FILE" 2>&1 || true
      success "Stale container cleaned up"
      # Check if .env exists — offer the menu
      if [[ -f "$ENV_FILE" ]] && env_has_any_provider_key "$ENV_FILE"; then
        show_rerun_menu
        if [[ "$RERUN_MODE" == "fresh" ]]; then
          docker volume rm openclaw-data >> "$LOG_FILE" 2>&1 || true
          rm -f "$ENV_FILE"
          success "Previous configuration wiped"
        fi
      fi
      ;;
    created)
      fix "Removing container that was created but never started..."
      docker rm -f "$CONTAINER_NAME" >> "$LOG_FILE" 2>&1 || true
      success "Orphaned container cleaned up"
      ;;
    none)
      # No container — but check if there's a previous .env
      if [[ -f "$ENV_FILE" ]] && env_has_any_provider_key "$ENV_FILE"; then
        echo ""
        echo -e "  ${BOLD}${YELLOW}Previous OpenClaw configuration found${RESET}"
        show_rerun_menu
        if [[ "$RERUN_MODE" == "fresh" ]]; then
          docker volume rm openclaw-data >> "$LOG_FILE" 2>&1 || true
          rm -f "$ENV_FILE"
          success "Previous configuration wiped"
        fi
      else
        verbose "No existing container found"
      fi
      ;;
  esac

  # ── Clean up stale containers from previous Compose project names ──
  # If someone ran a different compose project (e.g., "openclaw" vs "openclaw-docker-installer"),
  # there may be leftover containers like "openclaw-openclaw-gateway-1" that conflict.
  local stale_containers
  stale_containers="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -i 'openclaw' 2>/dev/null | grep -v "$CONTAINER_NAME" 2>/dev/null || echo '')"
  if [[ -n "$stale_containers" ]]; then
    verbose "Found other openclaw containers: $stale_containers"
    while IFS= read -r stale; do
      [[ -z "$stale" ]] && continue
      fix "Removing stale container from previous install: $stale"
      docker rm -f "$stale" >> "$LOG_FILE" 2>&1 || true
      FIXES_APPLIED+=("Removed stale container: $stale")
    done <<< "$stale_containers"
  fi

  # ── Clean up stale networks from previous runs ──
  local stale_networks
  stale_networks="$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -i 'openclaw' 2>/dev/null || echo '')"
  if [[ -n "$stale_networks" ]]; then
    while IFS= read -r net; do
      [[ -z "$net" ]] && continue
      verbose "Removing stale network: $net"
      docker network rm "$net" >> "$LOG_FILE" 2>&1 || true
    done <<< "$stale_networks"
  fi
}

check_network_connectivity() {
  # Quick check that we can reach the internet (needed for npm install in Dockerfile)
  # Use host-level check FIRST (fast, no image pull needed).
  # Only try docker-level check if host check fails AND an image is already cached.
  if curl -sf --max-time 5 "https://registry.npmjs.org/" > /dev/null 2>&1 || \
     wget -q --spider --timeout=5 "https://registry.npmjs.org/" 2>/dev/null; then
    verbose "Network connectivity OK (can reach npm registry)"
    return 0
  fi

  # Host-level check failed — try from inside Docker only if alpine is already cached
  # (don't pull images during pre-flight on a fresh install)
  if docker image inspect alpine:3.19 &>/dev/null 2>&1; then
    local net_ok=false
    if docker run --rm alpine:3.19 sh -c "wget -q --spider --timeout=10 http://registry.npmjs.org/ 2>/dev/null" >> "$LOG_FILE" 2>&1; then
      net_ok=true
    fi
    if [[ "$net_ok" == true ]]; then
      verbose "Network connectivity OK (Docker-level check passed)"
      return 0
    fi
  fi

  warn "Cannot reach npm registry from Docker"
  echo ""
  echo -e "  ${BOLD}This usually means one of:${RESET}"
  echo -e "    • Your internet connection is down"
  echo -e "    • Docker DNS is misconfigured"
  echo -e "    • A corporate firewall/proxy is blocking connections"
  echo ""

  # ── Auto-fix: DNS issues (Linux/WSL only — macOS/Windows Docker Desktop manages its own DNS) ──
  if [[ "$HOST_OS" == "linux" || "$HOST_OS" == "wsl" ]]; then
    info "Trying Google DNS as a workaround..."
    local dns_fix_worked=false
    if docker run --rm --dns=8.8.8.8 alpine:3.19 sh -c "wget -q --spider --timeout=10 http://registry.npmjs.org/ 2>/dev/null" >> "$LOG_FILE" 2>&1; then
      dns_fix_worked=true
    fi
    if [[ "$dns_fix_worked" == true ]]; then
      fix "Docker DNS was broken. Adding Google DNS (8.8.8.8) as fallback."
      # Write Docker daemon DNS config
      if [[ -w /etc/docker/daemon.json ]] || [[ ! -f /etc/docker/daemon.json ]]; then
        local daemon_json="/etc/docker/daemon.json"
        if [[ -f "$daemon_json" ]]; then
          sudo cp "$daemon_json" "${daemon_json}.bak" 2>/dev/null || true
          # Merge DNS into existing config
          if command_exists jq; then
            sudo sh -c "jq '. + {\"dns\": [\"8.8.8.8\", \"8.8.4.4\"]}' $daemon_json > ${daemon_json}.tmp && mv ${daemon_json}.tmp $daemon_json" 2>/dev/null || true
          fi
        else
          sudo mkdir -p /etc/docker 2>/dev/null || true
          echo '{"dns": ["8.8.8.8", "8.8.4.4"]}' | sudo tee "$daemon_json" > /dev/null 2>&1 || true
        fi
        sudo systemctl restart docker >> "$LOG_FILE" 2>&1 || sudo service docker restart >> "$LOG_FILE" 2>&1 || true
        sleep 3
        success "DNS fix applied"
        return 0
      fi
    fi
  fi

  echo -e "  ${BOLD}Quick fixes:${RESET}"
  echo -e "    • Check your internet connection"
  echo -e "    • Restart Docker Desktop"
  echo -e "    • On Mac: Docker Desktop → Settings → Resources → Network → DNS"
  echo ""

  if ! prompt_yn "Continue anyway? (build will likely fail)" "n"; then
    exit 1
  fi
}

# ============================================================================
# PHASE 2: Configure API Keys (with validation)
# ============================================================================

configure_keys() {
  step 2 4 "Configuring API keys"

  # Check if .env already exists with at least one provider key
  if [[ -f "$ENV_FILE" ]] && env_has_any_provider_key "$ENV_FILE"; then
    success "API key(s) already configured in .env"
    # Read existing gateway token if present
    if grep -q '^OPENCLAW_GATEWAY_TOKEN=' "$ENV_FILE" 2>/dev/null; then
      GENERATED_GATEWAY_TOKEN="$(grep '^OPENCLAW_GATEWAY_TOKEN=' "$ENV_FILE" | cut -d= -f2-)"
    else
      # Existing .env doesn't have a gateway token — add one
      local gt=""
      gt="$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' 2>/dev/null || printf '%04x%04x%04x%04x%04x%04x%04x%04x' $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM)"
      GENERATED_GATEWAY_TOKEN="$gt"
      echo "" >> "$ENV_FILE"
      echo "# Gateway token — auto-generated" >> "$ENV_FILE"
      echo "OPENCLAW_GATEWAY_TOKEN=${gt}" >> "$ENV_FILE"
      log "Added OPENCLAW_GATEWAY_TOKEN to existing .env"
    fi

    # --keys flag or re-run menu "update keys": skip the prompt, go straight to key entry
    if [[ "$FLAG_KEYS" == true ]] || [[ "$RERUN_MODE" == "update_keys" ]]; then
      info "Let's update your API keys"
    elif prompt_yn "Want to update your API keys?" "n"; then
      : # fall through to prompts
    else
      # Check .env permissions while we're here
      fix_env_permissions
      return 0
    fi
  fi

  echo ""
  info "Your API key connects OpenClaw to an AI provider."
  info "Pick at least one — you can add more now or later."
  echo ""

  # ── AI Provider picker ──
  echo -e "  ${BOLD}Which AI providers do you want to use?${RESET}"
  echo ""
  echo -e "    ${CYAN}1${RESET}) Anthropic (Claude)         ${DIM}console.anthropic.com${RESET}"
  echo -e "    ${CYAN}2${RESET}) OpenAI (GPT-4)             ${DIM}platform.openai.com${RESET}"
  echo -e "    ${CYAN}3${RESET}) Google Gemini               ${DIM}aistudio.google.com${RESET}"
  echo -e "    ${CYAN}4${RESET}) Mistral                     ${DIM}console.mistral.ai${RESET}"
  echo -e "    ${CYAN}5${RESET}) Groq (fast Llama/Mixtral)   ${DIM}console.groq.com${RESET}"
  echo -e "    ${CYAN}6${RESET}) DeepSeek                    ${DIM}platform.deepseek.com${RESET}"
  echo -e "    ${CYAN}7${RESET}) OpenRouter (100+ models)    ${DIM}openrouter.ai${RESET}"
  echo -e "    ${CYAN}8${RESET}) Cohere                      ${DIM}dashboard.cohere.com${RESET}"
  echo ""
  echo -e "  ${DIM}Enter numbers separated by spaces (e.g. 1 2), at least one required${RESET}"
  local llm_selection=""
  while [[ -z "$llm_selection" ]]; do
    read -rp "  Select providers: " llm_selection
    if [[ -z "$llm_selection" ]]; then
      warn "You need at least one AI provider. Pick a number from the list above."
    fi
  done

  local anthropic_key="" openai_key="" google_key="" mistral_key="" groq_key="" deepseek_key="" openrouter_key="" cohere_key=""
  local any_key_set=false

  for num in $llm_selection; do
    case "$num" in
      1)
        prompt_secret "  Anthropic API key (sk-ant-...): " anthropic_key
        if [[ -n "$anthropic_key" ]]; then
          if validate_provider_key "anthropic" "$anthropic_key"; then
            any_key_set=true
          else
            warn "Doesn't look like a standard Anthropic key. Saving anyway."
            any_key_set=true
          fi
        fi
        ;;
      2)
        prompt_secret "  OpenAI API key (sk-proj-...): " openai_key
        if [[ -n "$openai_key" ]]; then
          if validate_provider_key "openai" "$openai_key"; then
            any_key_set=true
          else
            warn "Doesn't look like a standard OpenAI key. Saving anyway."
            any_key_set=true
          fi
        fi
        ;;
      3)
        prompt_secret "  Google Gemini API key (AIza...): " google_key
        [[ -n "$google_key" ]] && any_key_set=true
        ;;
      4)
        prompt_secret "  Mistral API key: " mistral_key
        [[ -n "$mistral_key" ]] && any_key_set=true
        ;;
      5)
        prompt_secret "  Groq API key (gsk_...): " groq_key
        [[ -n "$groq_key" ]] && any_key_set=true
        ;;
      6)
        prompt_secret "  DeepSeek API key: " deepseek_key
        [[ -n "$deepseek_key" ]] && any_key_set=true
        ;;
      7)
        prompt_secret "  OpenRouter API key (sk-or-...): " openrouter_key
        [[ -n "$openrouter_key" ]] && any_key_set=true
        ;;
      8)
        prompt_secret "  Cohere API key: " cohere_key
        [[ -n "$cohere_key" ]] && any_key_set=true
        ;;
      *)
        warn "Invalid selection: $num (skipping)"
        ;;
    esac
  done

  if [[ "$any_key_set" != true ]]; then
    warn "No keys entered. You can add them later by editing .env"
    if [[ ! -f "$ENV_FILE" ]]; then
      cp "$SCRIPT_DIR/.env.example" "$ENV_FILE"
      chmod 600 "$ENV_FILE"
    fi
    return 0
  fi

  # ── Channel selection (opt-in only — default is webchat via dashboard) ──
  # The core install gives users a working webchat in the browser immediately.
  # Channels (Discord, Slack, Telegram, etc.) are optional and can be added
  # later via: ./docker-install.sh --channels
  local channels=""
  if [[ "$FLAG_CHANNELS" == true ]]; then
    channels="$(select_channels_interactive)"
  fi

  # ── Generate gateway token ──
  # We generate it here so the installer knows the token and can print
  # the full dashboard URL at the end — true one-step experience.
  local gateway_token=""
  if command -v openssl >/dev/null 2>&1; then
    gateway_token="$(openssl rand -hex 32 2>/dev/null)" || true
  fi
  if [[ -z "$gateway_token" ]] || [[ ${#gateway_token} -lt 32 ]]; then
    gateway_token="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' 2>/dev/null)" || true
  fi
  if [[ -z "$gateway_token" ]] || [[ ${#gateway_token} -lt 32 ]]; then
    # Last resort: use $RANDOM-based fallback
    gateway_token="$(printf '%04x%04x%04x%04x%04x%04x%04x%04x' $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM)"
  fi

  # Save token globally so verify_and_finish can use it
  GENERATED_GATEWAY_TOKEN="$gateway_token"

  # ── Write .env file ──
  if dry_run "Write API keys to .env"; then return 0; fi

  cat > "$ENV_FILE" <<EOF
# OpenClaw Docker — API Keys
# Generated by docker-install.sh on $(date)
# This file is git-ignored and never committed.

# Gateway token — used to authenticate with the dashboard
# The installer auto-generates this and prints the full URL at the end
OPENCLAW_GATEWAY_TOKEN=${gateway_token}
EOF

  # Write all configured provider keys
  [[ -n "$anthropic_key" ]]  && echo "ANTHROPIC_API_KEY=${anthropic_key}" >> "$ENV_FILE"
  [[ -n "$openai_key" ]]     && echo "OPENAI_API_KEY=${openai_key}" >> "$ENV_FILE"
  [[ -n "$google_key" ]]     && echo "GOOGLE_API_KEY=${google_key}" >> "$ENV_FILE"
  [[ -n "$mistral_key" ]]    && echo "MISTRAL_API_KEY=${mistral_key}" >> "$ENV_FILE"
  [[ -n "$groq_key" ]]       && echo "GROQ_API_KEY=${groq_key}" >> "$ENV_FILE"
  [[ -n "$deepseek_key" ]]   && echo "DEEPSEEK_API_KEY=${deepseek_key}" >> "$ENV_FILE"
  [[ -n "$openrouter_key" ]] && echo "OPENROUTER_API_KEY=${openrouter_key}" >> "$ENV_FILE"
  [[ -n "$cohere_key" ]]     && echo "COHERE_API_KEY=${cohere_key}" >> "$ENV_FILE"

  if [[ -n "$channels" ]]; then
    echo "OPENCLAW_CHANNELS=${channels}" >> "$ENV_FILE"
  fi

  # Lock down permissions
  chmod 600 "$ENV_FILE"

  success "API keys saved securely"

  # Show what was configured
  local providers=""
  [[ -n "$anthropic_key" ]]  && providers+="Anthropic, "
  [[ -n "$openai_key" ]]     && providers+="OpenAI, "
  [[ -n "$google_key" ]]     && providers+="Google Gemini, "
  [[ -n "$mistral_key" ]]    && providers+="Mistral, "
  [[ -n "$groq_key" ]]       && providers+="Groq, "
  [[ -n "$deepseek_key" ]]   && providers+="DeepSeek, "
  [[ -n "$openrouter_key" ]] && providers+="OpenRouter, "
  [[ -n "$cohere_key" ]]     && providers+="Cohere, "
  providers="${providers%, }"  # strip trailing ", "
  info "LLM providers: ${BOLD}${providers}${RESET}"

  if [[ -n "$channels" ]]; then
    success "Channels configured: ${BOLD}${channels}${RESET}"
  fi
}


validate_provider_key() {
  local provider="$1" key="$2"
  case "$provider" in
    anthropic)  [[ "$key" =~ ^sk-ant-[a-zA-Z0-9_-]{20,}$ ]] ;;
    openai)     [[ "$key" =~ ^sk-[a-zA-Z0-9_-]{20,}$ ]] ;;
    google)     [[ "$key" =~ ^AIza[a-zA-Z0-9_-]{20,}$ ]] ;;
    groq)       [[ "$key" =~ ^gsk_[a-zA-Z0-9_-]{20,}$ ]] ;;
    openrouter) [[ "$key" =~ ^sk-or-[a-zA-Z0-9_-]{20,}$ ]] ;;
    *)          [[ ${#key} -ge 20 ]] ;;  # Generic: just check length
  esac
}

# Check if an .env file has at least one provider API key set
env_has_any_provider_key() {
  local env_file="$1"
  local providers="ANTHROPIC_API_KEY OPENAI_API_KEY GOOGLE_API_KEY MISTRAL_API_KEY GROQ_API_KEY DEEPSEEK_API_KEY OPENROUTER_API_KEY COHERE_API_KEY"
  for var in $providers; do
    local val
    val="$(grep "^${var}=" "$env_file" 2>/dev/null | cut -d= -f2-)"
    if [[ -n "$val" ]]; then
      return 0
    fi
  done
  return 1
}

fix_env_permissions() {
  if [[ ! -f "$ENV_FILE" ]]; then return 0; fi

  # Windows (Git Bash/MINGW) doesn't support Unix permissions — skip silently
  if [[ "$HOST_OS" == "windows" ]]; then
    log "Skipping .env permission check on Windows (not supported)"
    return 0
  fi

  local perms
  perms="$(stat -f '%A' "$ENV_FILE" 2>/dev/null || stat -c '%a' "$ENV_FILE" 2>/dev/null || echo '')"

  if [[ -z "$perms" ]]; then
    log "Could not read file permissions — skipping"
    return 0
  fi

  if [[ "$perms" != "600" ]]; then
    fix "Fixing .env permissions from ${perms} to 600"
    chmod 600 "$ENV_FILE" 2>/dev/null || true
  fi
}

# ============================================================================
# CHANNEL SELECTOR (same channels as native installer)
# ============================================================================

SUPPORTED_CHANNELS=(
  "slack:Slack:Team chat & chat-ops"
  "discord:Discord:Community servers & bots"
  "telegram:Telegram:Personal & group messaging"
  "whatsapp:WhatsApp:Personal messaging (via WhatsApp Business API)"
  "msteams:Microsoft Teams:Enterprise collaboration"
  "google-chat:Google Chat:Google Workspace messaging"
  "signal:Signal:Encrypted private messaging"
  "matrix:Matrix:Decentralized, self-hosted chat"
  "irc:IRC:Classic internet relay chat"
  "mattermost:Mattermost:Self-hosted Slack alternative"
  "webchat:WebChat:Browser-based chat widget"
  "bluebubbles:BlueBubbles (iMessage):iMessage bridge for non-Apple devices"
  "imessage:iMessage (Legacy):Native macOS iMessage"
  "twitch:Twitch:Live streaming chat"
  "line:LINE:Popular in Japan/SE Asia"
  "feishu:Feishu (Lark):ByteDance enterprise messaging"
  "nostr:Nostr:Decentralized social protocol"
  "nextcloud-talk:Nextcloud Talk:Self-hosted video & chat"
  "synology-chat:Synology Chat:NAS-based team chat"
  "tlon:Tlon (Urbit):Urbit-based messaging"
  "zalo:Zalo:Popular in Vietnam"
  "zalo-personal:Zalo Personal:Personal Zalo messaging"
  "macos:macOS Native:System-level macOS integration"
  "ios-android:iOS/Android:Mobile app companion"
)

select_channels_interactive() {
  echo "" >&2
  echo -e "  ${BOLD}Select channels to enable:${RESET}" >&2
  echo -e "  ${DIM}(Enter numbers separated by spaces, or 'a' for all, 's' for Slack only)${RESET}" >&2
  echo "" >&2

  local i=1
  for entry in "${SUPPORTED_CHANNELS[@]}"; do
    local id name desc
    IFS=':' read -r id name desc <<< "$entry"
    printf "    ${CYAN}%2d${RESET}) %-28s ${DIM}%s${RESET}\n" "$i" "$name" "$desc" >&2
    i=$((i + 1))
  done

  echo "" >&2
  local selection
  read -rp "  Select [s]: " selection
  selection="${selection:-s}"

  local selected_ids=()

  if [[ "$selection" == "a" ]] || [[ "$selection" == "all" ]]; then
    for entry in "${SUPPORTED_CHANNELS[@]}"; do
      local id
      IFS=':' read -r id _ _ <<< "$entry"
      selected_ids+=("$id")
    done
  elif [[ "$selection" == "s" ]] || [[ "$selection" == "slack" ]]; then
    selected_ids=("slack")
  else
    for num in $selection; do
      if [[ "$num" =~ ^[0-9]+$ ]] && [[ "$num" -ge 1 ]] && [[ "$num" -le ${#SUPPORTED_CHANNELS[@]} ]]; then
        local entry="${SUPPORTED_CHANNELS[$((num - 1))]}"
        local id
        IFS=':' read -r id _ _ <<< "$entry"
        selected_ids+=("$id")
      else
        warn "Invalid selection: $num (skipping)" >&2
      fi
    done
  fi

  echo "" >&2
  for id in "${selected_ids[@]}"; do
    for entry in "${SUPPORTED_CHANNELS[@]}"; do
      local eid ename
      IFS=':' read -r eid ename _ <<< "$entry"
      if [[ "$eid" == "$id" ]]; then
        success "Enabled: ${BOLD}${ename}${RESET}" >&2
        break
      fi
    done
  done

  echo "" >&2
  for id in "${selected_ids[@]}"; do
    case "$id" in
      slack)    info "${DIM}Slack: Create a Slack App at api.slack.com/apps → get Bot Token + App Token${RESET}" >&2 ;;
      discord)  info "${DIM}Discord: Create app at discord.com/developers → get Bot Token${RESET}" >&2 ;;
      telegram) info "${DIM}Telegram: Message @BotFather → /newbot → get HTTP API token${RESET}" >&2 ;;
      whatsapp) info "${DIM}WhatsApp: Set up via Meta Business Suite → WhatsApp Business API${RESET}" >&2 ;;
      msteams)  info "${DIM}Teams: Register a bot in Azure → Bot Framework → get App ID + Password${RESET}" >&2 ;;
    esac
  done

  local IFS=','
  echo "${selected_ids[*]}"
}

# ============================================================================
# PHASE 3: Build & Start (with auto-recovery)
# ============================================================================

build_and_start() {
  step 3 4 "Building and starting OpenClaw"

  if dry_run "Build Docker image and start container"; then return 0; fi

  # ── Build the image ──
  info "Building Docker image (this takes ~1-2 minutes the first time)..."

  local build_success=false

  # Check if we should force a no-cache build:
  # If the entrypoint or Dockerfile changed since the last image was built,
  # Docker's layer cache may serve stale files. Force a clean build.
  local force_no_cache=false
  local image_created
  image_created="$(docker inspect --format='{{.Created}}' "$IMAGE_NAME:latest" 2>/dev/null || echo '')"
  if [[ -z "$image_created" ]]; then
    # No existing image — first build, normal is fine
    :
  elif [[ "$SCRIPT_DIR/docker/entrypoint.sh" -nt "$SCRIPT_DIR/.last-build" ]] 2>/dev/null || \
       [[ "$SCRIPT_DIR/Dockerfile" -nt "$SCRIPT_DIR/.last-build" ]] 2>/dev/null || \
       [[ "$SCRIPT_DIR/docker-compose.yml" -nt "$SCRIPT_DIR/.last-build" ]] 2>/dev/null; then
    info "Config files changed since last build — rebuilding from scratch"
    force_no_cache=true
  fi

  # Attempt 1: Normal build (or no-cache if files changed)
  local build_cmd="build"
  if [[ "$force_no_cache" == true ]]; then
    build_cmd="build --no-cache"
  fi
  if compose_cmd $build_cmd >> "$LOG_FILE" 2>&1; then
    build_success=true
  else
    warn "Build failed on first attempt. Diagnosing..."
    diagnose_build_failure

    # Attempt 2: Clean build (no cache)
    fix "Retrying build with no cache..."
    if compose_cmd build --no-cache >> "$LOG_FILE" 2>&1; then
      build_success=true
    else
      # Attempt 3: Pull fresh base image and retry
      fix "Pulling fresh base image and retrying..."
      docker pull node:22-alpine >> "$LOG_FILE" 2>&1 || true
      if compose_cmd build --no-cache >> "$LOG_FILE" 2>&1; then
        build_success=true
      fi
    fi
  fi

  if [[ "$build_success" != true ]]; then
    error "Docker build failed after 3 attempts."
    echo ""
    echo -e "  ${BOLD}What to check:${RESET}"
    echo -e "    1. Internet connection (image needs to download packages)"
    echo -e "    2. Disk space: ${BOLD}docker system df${RESET}"
    echo -e "    3. Full build log: ${BOLD}cat $LOG_FILE${RESET}"
    echo ""
    echo -e "  ${BOLD}Quick fixes:${RESET}"
    echo -e "    • ${BOLD}docker system prune -a${RESET}  (free space)"
    echo -e "    • Restart Docker Desktop"
    echo -e "    • Run with ${BOLD}--verbose${RESET}: ${CYAN}./docker-install.sh --verbose${RESET}"
    echo ""
    exit 1
  fi

  success "Docker image built"

  # Record build timestamp so we know when to force rebuild next time
  touch "$SCRIPT_DIR/.last-build" 2>/dev/null || true

  # ── Start the container ──
  info "Starting OpenClaw agent..."

  # Clean up any stale Docker Compose state before starting.
  # This fixes "No such container" errors when a previous container was
  # partially removed (e.g., `docker rm` without `docker compose down`).
  compose_cmd down --remove-orphans >> "$LOG_FILE" 2>&1 || true

  if ! compose_cmd up -d >> "$LOG_FILE" 2>&1; then
    warn "Failed to start container. Diagnosing..."
    diagnose_start_failure

    # Retry after diagnosis/fix
    fix "Retrying container start..."
    if ! compose_cmd up -d >> "$LOG_FILE" 2>&1; then
      # Last resort: full nuke and recreate
      fix "Full cleanup and fresh start..."
      docker rm -f "$CONTAINER_NAME" >> "$LOG_FILE" 2>&1 || true
      compose_cmd down -v --remove-orphans >> "$LOG_FILE" 2>&1 || true
      if ! compose_cmd up -d --force-recreate >> "$LOG_FILE" 2>&1; then
        error "Container still won't start after full cleanup."
        echo ""
        echo -e "  ${BOLD}Check logs:${RESET} ${CYAN}docker logs $CONTAINER_NAME${RESET}"
        echo -e "  ${BOLD}Full log:${RESET} ${CYAN}cat $LOG_FILE${RESET}"
        exit 1
      fi
    fi
  fi

  # ── Wait for healthy status ──
  info "Waiting for agent to be ready..."
  local attempts=0
  local max_attempts=45

  while [[ $attempts -lt $max_attempts ]]; do
    local health
    health="$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo 'none')"

    if [[ "$health" == "healthy" ]]; then
      break
    fi

    # Check if container exited
    local state
    state="$(docker inspect --format='{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo 'unknown')"

    if [[ "$state" == "exited" ]]; then
      local exit_code
      exit_code="$(docker inspect --format='{{.State.ExitCode}}' "$CONTAINER_NAME" 2>/dev/null || echo '?')"

      error "Container crashed (exit code: ${exit_code})"
      echo ""

      # Show last few lines of logs
      echo -e "  ${BOLD}Container output:${RESET}"
      docker logs "$CONTAINER_NAME" 2>&1 | tail -15 | while IFS= read -r line; do
        echo -e "    ${DIM}${line}${RESET}"
      done
      echo ""

      # Diagnose based on exit code and logs
      diagnose_container_crash "$exit_code"
      exit 1
    fi

    attempts=$((attempts + 1))
    sleep 1

    # Progress update every 10 seconds
    if [[ $((attempts % 10)) -eq 0 ]]; then
      verbose "Still waiting for health check... (${attempts}s, status: ${health:-starting})"
    fi
  done

  if [[ $attempts -ge $max_attempts ]]; then
    warn "Agent hasn't reported healthy yet (may still be starting)"
    info "Check status: ${BOLD}docker logs -f $CONTAINER_NAME${RESET}"
  else
    success "OpenClaw agent is running and healthy"
  fi
}

diagnose_build_failure() {
  local log_tail
  log_tail="$(tail -100 "$LOG_FILE" 2>/dev/null)"

  # ── Disk full ──
  if echo "$log_tail" | grep -qi "no space left on device\|ENOSPC"; then
    fix "Disk space exhausted. Cleaning Docker cache..."
    docker system prune -f >> "$LOG_FILE" 2>&1 || true
    docker builder prune -f >> "$LOG_FILE" 2>&1 || true

  # ── Network / DNS failure ──
  elif echo "$log_tail" | grep -qi "network.*unreachable\|could not resolve\|ETIMEDOUT\|EAI_AGAIN\|getaddrinfo"; then
    warn "Network issue during build (DNS or connectivity)"
    info "Check your internet connection"
    info "If on corporate network, you may need proxy settings"
    info "Try: Docker Desktop → Settings → Resources → Proxies"

  # ── Base image not found / Docker Hub rate limit ──
  elif echo "$log_tail" | grep -qi "manifest.*not found\|pull access denied\|toomanyrequests\|429"; then
    if echo "$log_tail" | grep -qi "toomanyrequests\|429"; then
      warn "Docker Hub rate limit hit (too many image pulls)"
      info "Wait a few minutes and try again, or log in: ${BOLD}docker login${RESET}"
    else
      fix "Base image issue. Pulling fresh copy..."
      docker pull node:22-alpine >> "$LOG_FILE" 2>&1 || true
    fi

  # ── Missing git in builder (spawn git ENOENT) ──
  elif echo "$log_tail" | grep -qi "spawn git\|syscall.*spawn.*git\|ENOENT.*git"; then
    fix "npm dependency requires git but git is not in Docker image. Patching Dockerfile..."
    # Auto-patch the Dockerfile to install git in the builder stage
    if grep -q "apk add --no-cache git" "$SCRIPT_DIR/Dockerfile" 2>/dev/null; then
      info "Dockerfile already includes git — clearing build cache..."
    else
      # Add git install before npm install in the builder stage
      sed -i.bak 's|RUN npm install -g openclaw@latest|RUN apk add --no-cache git \&\& npm install -g openclaw@latest|' "$SCRIPT_DIR/Dockerfile" 2>/dev/null || \
      sed -i '.bak' 's|RUN npm install -g openclaw@latest|RUN apk add --no-cache git \&\& npm install -g openclaw@latest|' "$SCRIPT_DIR/Dockerfile" 2>/dev/null
      FIXES_APPLIED+=("Patched Dockerfile to include git in builder stage")
    fi
    docker builder prune -f >> "$LOG_FILE" 2>&1 || true

  # ── npm install failure ──
  elif echo "$log_tail" | grep -qi "npm ERR\|npm error\|ERESOLVE\|npm warn\|EBADENGINE"; then
    if echo "$log_tail" | grep -qi "ERESOLVE"; then
      fix "npm dependency conflict. Retrying with clean state..."
    elif echo "$log_tail" | grep -qi "EBADENGINE"; then
      warn "Node.js version mismatch in npm package"
      info "The openclaw package may need a different Node version"
    else
      fix "npm install error. Retrying with clean cache..."
    fi
    docker builder prune -f >> "$LOG_FILE" 2>&1 || true

  # ── Dockerfile syntax error ──
  elif echo "$log_tail" | grep -qi "failed to solve\|dockerfile parse error\|unknown instruction"; then
    error "Dockerfile has a syntax error"
    info "This shouldn't happen with the included Dockerfile."
    info "If you edited it, check for typos. Otherwise, re-download the repo."

  # ── Docker daemon connection lost ──
  elif echo "$log_tail" | grep -qi "Cannot connect to the Docker daemon\|connection refused\|Is the docker daemon running"; then
    warn "Docker daemon disconnected during build"
    fix "Checking if Docker is still running..."
    if docker info &>/dev/null 2>&1; then
      info "Docker is running — may have been a transient error"
    else
      error "Docker stopped. Restart Docker Desktop and try again."
    fi

  # ── Permission denied during build ──
  elif echo "$log_tail" | grep -qi "permission denied\|EACCES.*mkdir\|EACCES.*open"; then
    warn "Permission error during build"
    fix "Cleaning build cache..."
    docker builder prune -f >> "$LOG_FILE" 2>&1 || true

  # ── Timeout during build ──
  elif echo "$log_tail" | grep -qi "timed out\|context deadline exceeded\|TLS handshake timeout"; then
    warn "Build timed out (slow network or overloaded registry)"
    info "This is usually a temporary issue. Retrying will help."

  # ── Out of memory during build ──
  elif echo "$log_tail" | grep -qi "killed\|signal: killed\|OOMKilled"; then
    warn "Build was killed (likely out of memory)"
    info "Increase Docker memory: Docker Desktop → Settings → Resources → Memory"
    info "Recommend at least 4GB for building images"

  # ── Unknown build error ──
  else
    warn "Unrecognized build error"
    info "Last few lines of log:"
    tail -5 "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
      echo -e "    ${DIM}${line}${RESET}"
    done
  fi
}

diagnose_start_failure() {
  local log_tail
  log_tail="$(tail -30 "$LOG_FILE" 2>/dev/null)"

  # ── "No such container" — stale Docker Compose state ──
  if echo "$log_tail" | grep -qi "No such container"; then
    fix "Stale container reference found. Cleaning up Docker Compose state..."
    docker rm -f "$CONTAINER_NAME" >> "$LOG_FILE" 2>&1 || true
    compose_cmd down --remove-orphans >> "$LOG_FILE" 2>&1 || true
    FIXES_APPLIED+=("Cleaned stale Docker Compose container reference")

  # ── Port conflict ──
  elif echo "$log_tail" | grep -qi "port.*already.*allocated\|address already in use\|bind.*failed"; then
    warn "Port $GATEWAY_PORT is already in use"

    # Remove our own failed container first (compose created it but couldn't start it)
    docker rm -f "$CONTAINER_NAME" >> "$LOG_FILE" 2>&1 || true

    # Identify what's actually holding the port (cross-platform)
    _get_port_blocker "$GATEWAY_PORT"
    if [[ -n "$_PORT_NAME" ]]; then
      info "Blocked by: $_PORT_NAME (PID $_PORT_PID)"
    fi

    # Kill the process that's holding the port
    if [[ -n "$_PORT_PID" ]]; then
      fix "Stopping process $_PORT_PID ($_PORT_NAME) to free port $GATEWAY_PORT..."
      _kill_process "$_PORT_PID"
      # Final check
      if _is_port_in_use "$GATEWAY_PORT"; then
        warn "Port $GATEWAY_PORT is still in use after killing PID $_PORT_PID"
      else
        success "Port $GATEWAY_PORT is now free"
        FIXES_APPLIED+=("Killed $_PORT_NAME (PID $_PORT_PID) blocking port $GATEWAY_PORT")
      fi
    else
      warn "Could not identify what's using port $GATEWAY_PORT"
      if [[ "$HOST_OS" == "windows" ]]; then
        info "Try manually: ${BOLD}netstat -ano | findstr :$GATEWAY_PORT${RESET}"
      else
        info "Try manually: ${BOLD}lsof -i :$GATEWAY_PORT${RESET}"
      fi
    fi

  # ── Container name conflict ──
  elif echo "$log_tail" | grep -qi "name.*already in use"; then
    fix "Container name conflict. Removing old container..."
    docker rm -f "$CONTAINER_NAME" >> "$LOG_FILE" 2>&1 || true
    FIXES_APPLIED+=("Removed container name conflict")
  fi
}

diagnose_container_crash() {
  local exit_code="$1"
  local logs
  logs="$(docker logs "$CONTAINER_NAME" 2>&1 || echo '')"

  # ── Missing API key ──
  if echo "$logs" | grep -qi "API.key.*not found\|API_KEY.*not found\|No.*API key"; then
    error "The container can't find any AI provider API key."
    echo ""
    echo -e "  ${BOLD}You need at least one API key to power the AI.${RESET}"
    echo ""
    echo -e "  ${BOLD}Fix:${RESET}"
    echo -e "    1. Check your .env file: ${CYAN}cat .env${RESET}"
    echo -e "    2. Make sure at least one provider key is set (e.g. ANTHROPIC_API_KEY, OPENAI_API_KEY, etc.)"
    echo -e "    3. Re-run: ${CYAN}./docker-install.sh${RESET}"
    return
  fi

  # ── Empty API key ──
  if echo "$logs" | grep -qi "API_KEY is.*empty\|empty.*blank"; then
    error "An API key line exists in .env but has no value after the = sign."
    echo ""
    echo -e "  ${BOLD}Fix:${RESET} Open .env and paste your full key next to the provider you chose."
    echo -e "    Then: ${CYAN}docker compose restart${RESET}"
    return
  fi

  # ── Key too short (truncated copy-paste) ──
  if echo "$logs" | grep -qi "too short\|only.*characters"; then
    error "Your API key is too short — it was probably cut off during copy-paste."
    echo ""
    echo -e "  ${BOLD}Fix:${RESET} Go to your AI provider's console, copy the FULL key, paste into .env"
    echo -e "    Then: ${CYAN}docker compose restart${RESET}"
    return
  fi

  # ── Placeholder left in .env ──
  if echo "$logs" | grep -qi "placeholder\|your-key-here\|YOUR_KEY"; then
    error "You left the placeholder text in .env instead of pasting your real key."
    echo ""
    echo -e "  ${BOLD}Fix:${RESET} Open .env and replace the placeholder with your actual key"
    echo -e "    Then: ${CYAN}docker compose restart${RESET}"
    return
  fi

  # ── Permission denied ──
  if echo "$logs" | grep -qi "permission denied\|EACCES"; then
    error "Permission error inside the container."
    echo ""
    echo -e "  ${BOLD}This usually means the data volume has wrong ownership.${RESET}"
    echo ""
    echo -e "  ${BOLD}Fix:${RESET}"
    echo -e "    ${CYAN}docker compose down${RESET}"
    echo -e "    ${CYAN}docker volume rm openclaw-data${RESET}"
    echo -e "    ${CYAN}./docker-install.sh${RESET}"
    return
  fi

  # ── Config directory not writable ──
  if echo "$logs" | grep -qi "Config directory not writable\|not writable"; then
    error "Config directory has wrong permissions inside container."
    echo ""
    echo -e "  ${BOLD}Fix:${RESET} Remove the data volume and recreate it:"
    echo -e "    ${CYAN}docker compose down && docker volume rm openclaw-data && ./docker-install.sh${RESET}"
    return
  fi

  # ── Missing dist/entry.mjs (symlink broken by COPY --from) ──
  if echo "$logs" | grep -qi "missing dist/entry\|dist/entry.*build output"; then
    error "OpenClaw binary can't find its build output (dist/entry.mjs)."
    echo ""
    echo -e "  ${BOLD}Root cause:${RESET} The Docker image copied the openclaw binary as a flat file"
    echo -e "  instead of preserving the symlink, breaking path resolution."
    echo ""
    echo -e "  ${BOLD}Fix:${RESET} Rebuild with the corrected Dockerfile:"
    echo -e "    ${CYAN}docker compose down${RESET}"
    echo -e "    ${CYAN}docker compose build --no-cache${RESET}"
    echo -e "    ${CYAN}docker compose up -d${RESET}"
    echo ""
    echo -e "  If you pulled the latest installer, the Dockerfile already has the fix."
    echo -e "  If not: ${CYAN}git pull && ./docker-install.sh${RESET}"
    return
  fi

  # ── npm/node module errors ──
  if echo "$logs" | grep -qi "MODULE_NOT_FOUND\|Cannot find module\|ERR_MODULE\|Error: Cannot find"; then
    error "OpenClaw module not found — image may be corrupted."
    echo ""
    echo -e "  ${BOLD}Fix:${RESET} Rebuild from scratch:"
    echo -e "    ${CYAN}./docker-install.sh --uninstall${RESET}"
    echo -e "    ${CYAN}./docker-install.sh${RESET}"
    return
  fi

  # ── Node.js not found ──
  if echo "$logs" | grep -qi "node.*not found\|Node.js.*not found"; then
    error "Node.js is missing from the container image."
    echo ""
    echo -e "  ${BOLD}Fix:${RESET} Rebuild: ${CYAN}docker compose build --no-cache && docker compose up${RESET}"
    return
  fi

  # ── Corrupt JSON config ──
  if echo "$logs" | grep -qi "invalid JSON\|corrupt.*JSON\|SyntaxError.*JSON\|Unexpected token"; then
    error "Gateway config file is corrupted."
    echo ""
    echo -e "  ${BOLD}Fix:${RESET} The entrypoint auto-recovers from this."
    echo -e "    Just restart: ${CYAN}docker compose restart${RESET}"
    echo -e "    If that fails: ${CYAN}docker volume rm openclaw-data && ./docker-install.sh${RESET}"
    return
  fi

  # ── DNS / network failure inside container ──
  if echo "$logs" | grep -qi "cannot resolve\|ENETUNREACH\|getaddrinfo.*ENOTFOUND\|network.*unreachable"; then
    error "Container can't reach the internet."
    echo ""
    echo -e "  ${BOLD}Fix:${RESET}"
    echo -e "    • Restart Docker Desktop"
    echo -e "    • Check your internet connection"
    echo -e "    • If on VPN: disconnect VPN, restart Docker, reconnect VPN"
    return
  fi

  # ── TLS / certificate errors ──
  if echo "$logs" | grep -qi "CERT_\|certificate\|SSL\|unable to verify\|self.signed"; then
    error "TLS/SSL certificate error — the container can't make secure connections."
    echo ""
    echo -e "  ${BOLD}Common cause:${RESET} Corporate proxy intercepting HTTPS traffic"
    echo -e "  ${BOLD}Fix:${RESET}"
    echo -e "    • If on corporate network: ask IT about proxy CA certificate"
    echo -e "    • Try disconnecting from VPN"
    echo -e "    • Restart Docker Desktop"
    return
  fi

  # ── openssl rand failure ──
  if echo "$logs" | grep -qi "Failed to generate.*auth token\|openssl.*not working"; then
    error "Cannot generate security token inside container."
    echo ""
    echo -e "  ${BOLD}Fix:${RESET} Rebuild image: ${CYAN}docker compose build --no-cache && docker compose up${RESET}"
    return
  fi

  # ── Out of memory (exit code 137 = SIGKILL, usually OOM) ──
  if [[ "$exit_code" == "137" ]]; then
    error "Container was killed — likely out of memory (OOM)."
    echo ""
    echo -e "  ${BOLD}Fix:${RESET}"
    echo -e "    Option 1: Increase container limit in docker-compose.yml:"
    echo -e "      Change ${CYAN}memory: 512M${RESET} to ${CYAN}memory: 1G${RESET}"
    echo -e "    Option 2: Give Docker more RAM:"
    echo -e "      Docker Desktop → Settings → Resources → Memory → 4GB+"
    return
  fi

  # ── SIGTERM (exit code 143 = graceful shutdown, not an error) ──
  if [[ "$exit_code" == "143" ]]; then
    info "Container was stopped gracefully (SIGTERM). This is normal."
    info "Restart with: ${BOLD}./docker-install.sh${RESET}"
    return
  fi

  # ── Segfault (exit code 139 = SIGSEGV) ──
  if [[ "$exit_code" == "139" ]]; then
    error "Container crashed with a segmentation fault."
    echo ""
    echo -e "  ${BOLD}Fix:${RESET} Rebuild from scratch:"
    echo -e "    ${CYAN}./docker-install.sh --uninstall && ./docker-install.sh${RESET}"
    echo -e "    If it keeps happening, try updating Docker Desktop."
    return
  fi

  # ── Exit code 1 (general error — read the logs) ──
  if [[ "$exit_code" == "1" ]]; then
    error "Container exited with an error. The log above should explain why."
    echo ""
    echo -e "  ${BOLD}Common causes:${RESET}"
    echo -e "    • Missing or invalid API key in .env"
    echo -e "    • Permissions issue on the data volume"
    echo -e "    • OpenClaw gateway failed to bind to port"
    echo ""
    echo -e "  ${BOLD}Quick fix:${RESET} ${CYAN}./docker-install.sh --doctor${RESET}"
    return
  fi

  # ── Unknown exit code ──
  echo -e "  ${BOLD}Container exited with code ${exit_code}.${RESET} Not sure what went wrong."
  echo ""
  echo -e "  ${BOLD}Try:${RESET}"
  echo -e "    • Full logs: ${CYAN}docker logs $CONTAINER_NAME${RESET}"
  echo -e "    • Fresh start: ${CYAN}./docker-install.sh --uninstall && ./docker-install.sh${RESET}"
  echo -e "    • Ask for help: ${CYAN}./docker-install.sh --doctor${RESET}"
}

# ============================================================================
# PHASE 4: Security Hardening + Auto-Fix
# ============================================================================

harden_and_verify() {
  step 4 4 "Finishing up"

  if dry_run "Run security hardening checks"; then return 0; fi

  # ── Fix .env permissions ──
  fix_env_permissions

  # ── Verify .gitignore protects .env ──
  if [[ -f "$SCRIPT_DIR/.gitignore" ]]; then
    if ! grep -q "^\.env$" "$SCRIPT_DIR/.gitignore" 2>/dev/null; then
      fix "Adding .env to .gitignore (prevents accidental commit of API keys)"
      echo ".env" >> "$SCRIPT_DIR/.gitignore"
    fi
  fi

  # ── Check if .env was accidentally committed ──
  if command_exists git && [[ -d "$SCRIPT_DIR/.git" ]]; then
    if git -C "$SCRIPT_DIR" ls-files --error-unmatch .env &>/dev/null 2>&1; then
      warn ".env file is tracked by git — your API keys may be in commit history!"
      echo ""
      echo -e "  ${BOLD}Fix:${RESET}"
      echo -e "    ${CYAN}git rm --cached .env${RESET}"
      echo -e "    ${CYAN}git commit -m 'Remove .env from tracking'${RESET}"
      echo ""
    fi
  fi

  # ── Verify Docker socket isn't mounted into container ──
  local mounts
  mounts="$(docker inspect --format='{{range .Mounts}}{{.Source}} {{end}}' "$CONTAINER_NAME" 2>/dev/null || echo '')"
  if echo "$mounts" | grep -q "docker.sock"; then
    warn "Docker socket is mounted inside the container — this is a security risk!"
    warn "A compromised skill could control Docker on your host."
  fi

  success "Security hardening complete"
}

# ============================================================================
# Channel-Specific Setup Instructions
# ============================================================================
# Prints step-by-step instructions for each selected channel so beginners
# know exactly what to do before running `openclaw configure`.

print_channel_instructions() {
  local channels="$1"

  for channel in $(echo "$channels" | tr ',' ' '); do
    case "$channel" in
      slack)
        echo -e "  ${BOLD}${CYAN}Slack${RESET}"
        echo -e "    1. Go to ${UNDERLINE}https://api.slack.com/apps${RESET}"
        echo -e "    2. Click ${BOLD}Create New App${RESET} → ${BOLD}From scratch${RESET}"
        echo -e "    3. Name it (e.g. \"OpenClaw\") and pick your workspace"
        echo -e "    4. Go to ${BOLD}OAuth & Permissions${RESET} → add Bot Token Scopes:"
        echo -e "       ${DIM}chat:write, channels:read, channels:history, groups:read,"
        echo -e "       groups:history, im:read, im:history, im:write, app_mentions:read${RESET}"
        echo -e "    5. Click ${BOLD}Install to Workspace${RESET} → copy the ${BOLD}Bot User OAuth Token${RESET}"
        echo -e "       ${DIM}(starts with xoxb-)${RESET}"
        echo -e "    6. Go to ${BOLD}Basic Information${RESET} → ${BOLD}App-Level Tokens${RESET} → Generate one"
        echo -e "       with scope ${BOLD}connections:write${RESET} → copy the ${BOLD}App Token${RESET}"
        echo -e "       ${DIM}(starts with xapp-)${RESET}"
        echo -e "    7. Go to ${BOLD}Socket Mode${RESET} → enable it"
        echo -e "    8. Go to ${BOLD}Event Subscriptions${RESET} → enable → subscribe to:"
        echo -e "       ${DIM}message.channels, message.groups, message.im, app_mention${RESET}"
        echo ""
        ;;
      discord)
        echo -e "  ${BOLD}${CYAN}Discord${RESET}"
        echo -e "    1. Go to ${UNDERLINE}https://discord.com/developers/applications${RESET}"
        echo -e "    2. Click ${BOLD}New Application${RESET} → name it (e.g. \"OpenClaw\")"
        echo -e "    3. Go to the ${BOLD}Bot${RESET} tab"
        echo -e "    4. Copy the ${BOLD}Token${RESET} (click \"Copy\" under the bot's username)"
        echo -e "       ${DIM}If no token is shown, click \"Reset Token\" to generate one${RESET}"
        echo -e "    5. Scroll down → enable ${BOLD}Message Content Intent${RESET}"
        echo -e "    6. Go to ${BOLD}OAuth2${RESET} → ${BOLD}URL Generator${RESET}"
        echo -e "       Scopes: ${DIM}bot, applications.commands${RESET}"
        echo -e "       Bot Permissions: ${DIM}Send Messages, Read Message History${RESET}"
        echo -e "    7. Copy the generated URL → open it → invite the bot to your server"
        echo ""
        ;;
      telegram)
        echo -e "  ${BOLD}${CYAN}Telegram${RESET}"
        echo -e "    1. Open Telegram and search for ${BOLD}@BotFather${RESET}"
        echo -e "    2. Send ${BOLD}/newbot${RESET}"
        echo -e "    3. Choose a display name (e.g. \"My OpenClaw Agent\")"
        echo -e "    4. Choose a username (must end in ${BOLD}bot${RESET}, e.g. \"myopenclaw_bot\")"
        echo -e "    5. Copy the ${BOLD}HTTP API token${RESET} BotFather gives you"
        echo -e "       ${DIM}(looks like 123456789:ABCdefGHIjklMNO...)${RESET}"
        echo ""
        ;;
      whatsapp)
        echo -e "  ${BOLD}${CYAN}WhatsApp${RESET}"
        echo -e "    1. Go to ${UNDERLINE}https://business.facebook.com${RESET}"
        echo -e "    2. Create or select a Meta Business account"
        echo -e "    3. Go to ${UNDERLINE}https://developers.facebook.com${RESET} → create an app"
        echo -e "    4. Add the ${BOLD}WhatsApp${RESET} product to your app"
        echo -e "    5. Go to ${BOLD}WhatsApp → API Setup${RESET}"
        echo -e "    6. Copy the ${BOLD}Temporary Access Token${RESET} and ${BOLD}Phone Number ID${RESET}"
        echo -e "    7. Set up a webhook URL for incoming messages"
        echo -e "       ${DIM}(requires a public URL — use ngrok for testing)${RESET}"
        echo ""
        ;;
      msteams)
        echo -e "  ${BOLD}${CYAN}Microsoft Teams${RESET}"
        echo -e "    1. Go to ${UNDERLINE}https://portal.azure.com${RESET}"
        echo -e "    2. Search for ${BOLD}Bot Services${RESET} → create an ${BOLD}Azure Bot${RESET}"
        echo -e "    3. Under ${BOLD}Configuration${RESET}, note the ${BOLD}Microsoft App ID${RESET}"
        echo -e "    4. Go to ${BOLD}Manage Password${RESET} → create a ${BOLD}Client Secret${RESET}"
        echo -e "    5. Under ${BOLD}Channels${RESET} → add ${BOLD}Microsoft Teams${RESET}"
        echo -e "    6. In Teams Admin Center, upload your bot as a custom app"
        echo -e "       ${DIM}(or use Teams Developer Portal to create an app package)${RESET}"
        echo ""
        ;;
      google-chat)
        echo -e "  ${BOLD}${CYAN}Google Chat${RESET}"
        echo -e "    1. Go to ${UNDERLINE}https://console.cloud.google.com${RESET}"
        echo -e "    2. Create a project (or select an existing one)"
        echo -e "    3. Enable the ${BOLD}Google Chat API${RESET}"
        echo -e "    4. Go to ${BOLD}APIs & Services → Credentials${RESET}"
        echo -e "    5. Create a ${BOLD}Service Account${RESET} → download the JSON key file"
        echo -e "    6. In the Chat API settings, configure your bot and set the"
        echo -e "       connection type to ${BOLD}App URL${RESET} or ${BOLD}Cloud Pub/Sub${RESET}"
        echo ""
        ;;
      signal)
        echo -e "  ${BOLD}${CYAN}Signal${RESET}"
        echo -e "    1. Install ${BOLD}signal-cli${RESET}: ${UNDERLINE}https://github.com/AsamK/signal-cli${RESET}"
        echo -e "    2. Register a phone number with Signal:"
        echo -e "       ${CYAN}signal-cli -u +1YOURNUMBER register${RESET}"
        echo -e "       ${CYAN}signal-cli -u +1YOURNUMBER verify CODE${RESET}"
        echo -e "    3. The registered number will be used by OpenClaw to send/receive"
        echo -e "       ${DIM}(requires a dedicated number — don't use your personal one)${RESET}"
        echo ""
        ;;
      matrix)
        echo -e "  ${BOLD}${CYAN}Matrix${RESET}"
        echo -e "    1. Create a bot account on your Matrix homeserver"
        echo -e "       ${DIM}(e.g. register @openclaw-bot:your-server.org)${RESET}"
        echo -e "    2. Get an ${BOLD}Access Token${RESET} for the bot account:"
        echo -e "       Log in via Element → Settings → Help & About → Access Token"
        echo -e "    3. Note your ${BOLD}Homeserver URL${RESET} (e.g. https://matrix.your-server.org)"
        echo -e "    4. Invite the bot to the rooms you want it in"
        echo ""
        ;;
      irc)
        echo -e "  ${BOLD}${CYAN}IRC${RESET}"
        echo -e "    1. Choose an IRC server (e.g. irc.libera.chat)"
        echo -e "    2. Pick a ${BOLD}nickname${RESET} for the bot (e.g. \"openclaw-bot\")"
        echo -e "    3. Optionally register the nick with NickServ:"
        echo -e "       ${DIM}/msg NickServ REGISTER password email@example.com${RESET}"
        echo -e "    4. Note the ${BOLD}channels${RESET} to join (e.g. #my-channel)"
        echo ""
        ;;
      mattermost)
        echo -e "  ${BOLD}${CYAN}Mattermost${RESET}"
        echo -e "    1. Log in to your Mattermost server as admin"
        echo -e "    2. Go to ${BOLD}Integrations → Bot Accounts → Add Bot Account${RESET}"
        echo -e "    3. Name it (e.g. \"OpenClaw\"), set role to ${BOLD}System Admin${RESET} or ${BOLD}Member${RESET}"
        echo -e "    4. Copy the ${BOLD}Bot Access Token${RESET}"
        echo -e "    5. Note your Mattermost ${BOLD}Server URL${RESET} (e.g. https://mattermost.example.com)"
        echo ""
        ;;
      webchat)
        echo -e "  ${BOLD}${CYAN}WebChat${RESET}"
        echo -e "    No external setup needed — WebChat runs on the dashboard."
        echo -e "    Open the dashboard URL above and start chatting."
        echo ""
        ;;
      bluebubbles)
        echo -e "  ${BOLD}${CYAN}BlueBubbles (iMessage)${RESET}"
        echo -e "    1. Install BlueBubbles server on a Mac: ${UNDERLINE}https://bluebubbles.app${RESET}"
        echo -e "    2. Set up the server and connect it to your iMessage account"
        echo -e "    3. Go to ${BOLD}Settings → API${RESET} in BlueBubbles"
        echo -e "    4. Copy the ${BOLD}Server URL${RESET} and ${BOLD}Password${RESET}"
        echo ""
        ;;
      imessage)
        echo -e "  ${BOLD}${CYAN}iMessage (Legacy)${RESET}"
        echo -e "    Requires running on macOS with Messages.app signed in."
        echo -e "    The bot reads/sends via AppleScript — no token needed."
        echo -e "    ${DIM}Note: Only works when the container runs on a Mac host.${RESET}"
        echo ""
        ;;
      twitch)
        echo -e "  ${BOLD}${CYAN}Twitch${RESET}"
        echo -e "    1. Go to ${UNDERLINE}https://dev.twitch.tv/console/apps${RESET}"
        echo -e "    2. Click ${BOLD}Register Your Application${RESET}"
        echo -e "    3. Set OAuth Redirect URL to ${DIM}http://localhost${RESET}"
        echo -e "    4. Copy the ${BOLD}Client ID${RESET}"
        echo -e "    5. Generate an ${BOLD}OAuth Token${RESET} at ${UNDERLINE}https://twitchapps.com/tmi/${RESET}"
        echo -e "       ${DIM}(starts with oauth:)${RESET}"
        echo -e "    6. Note the ${BOLD}channel name${RESET} to join"
        echo ""
        ;;
      line)
        echo -e "  ${BOLD}${CYAN}LINE${RESET}"
        echo -e "    1. Go to ${UNDERLINE}https://developers.line.biz/console${RESET}"
        echo -e "    2. Create a ${BOLD}Messaging API Channel${RESET}"
        echo -e "    3. In the channel settings, copy the ${BOLD}Channel Access Token${RESET}"
        echo -e "    4. Copy the ${BOLD}Channel Secret${RESET}"
        echo -e "    5. Set the ${BOLD}Webhook URL${RESET} to your public endpoint"
        echo -e "       ${DIM}(requires a public URL — use ngrok for testing)${RESET}"
        echo ""
        ;;
      feishu)
        echo -e "  ${BOLD}${CYAN}Feishu (Lark)${RESET}"
        echo -e "    1. Go to ${UNDERLINE}https://open.feishu.cn/app${RESET} (or open.larksuite.com for Lark)"
        echo -e "    2. Create a new app → go to ${BOLD}Credentials${RESET}"
        echo -e "    3. Copy the ${BOLD}App ID${RESET} and ${BOLD}App Secret${RESET}"
        echo -e "    4. Under ${BOLD}Event Subscriptions${RESET}, set your webhook URL"
        echo -e "    5. Add the ${BOLD}im:message:receive_v1${RESET} event"
        echo ""
        ;;
      nostr)
        echo -e "  ${BOLD}${CYAN}Nostr${RESET}"
        echo -e "    1. Generate a Nostr keypair (or use an existing one)"
        echo -e "       ${CYAN}openssl rand -hex 32${RESET}"
        echo -e "    2. The private key (hex) is your bot's identity"
        echo -e "    3. Choose relay(s) to connect to (e.g. wss://relay.damus.io)"
        echo ""
        ;;
      nextcloud-talk)
        echo -e "  ${BOLD}${CYAN}Nextcloud Talk${RESET}"
        echo -e "    1. Log in to your Nextcloud instance as admin"
        echo -e "    2. Create a bot user account"
        echo -e "    3. Generate an ${BOLD}App Password${RESET} for the bot user:"
        echo -e "       Settings → Security → App Passwords"
        echo -e "    4. Note the ${BOLD}Nextcloud URL${RESET} and bot ${BOLD}username${RESET}"
        echo ""
        ;;
      synology-chat)
        echo -e "  ${BOLD}${CYAN}Synology Chat${RESET}"
        echo -e "    1. Open Synology Chat on your NAS"
        echo -e "    2. Go to ${BOLD}Integration → Bots${RESET} → create a bot"
        echo -e "    3. Copy the ${BOLD}Incoming Webhook URL${RESET} and ${BOLD}Outgoing Token${RESET}"
        echo ""
        ;;
      tlon)
        echo -e "  ${BOLD}${CYAN}Tlon (Urbit)${RESET}"
        echo -e "    1. You need a running Urbit ship"
        echo -e "    2. Get your ship's ${BOLD}URL${RESET} and ${BOLD}+code${RESET} (access key)"
        echo -e "    3. The bot will connect to your ship's chat channels"
        echo ""
        ;;
      zalo|zalo-personal)
        echo -e "  ${BOLD}${CYAN}Zalo${RESET}"
        echo -e "    1. Go to ${UNDERLINE}https://developers.zalo.me${RESET}"
        echo -e "    2. Create an app → go to ${BOLD}Settings${RESET}"
        echo -e "    3. Copy the ${BOLD}App ID${RESET} and ${BOLD}Secret Key${RESET}"
        echo -e "    4. Generate an ${BOLD}OA Access Token${RESET} (for Official Account)"
        echo ""
        ;;
      macos)
        echo -e "  ${BOLD}${CYAN}macOS Native${RESET}"
        echo -e "    No external setup needed — uses native macOS integration."
        echo -e "    ${DIM}Note: Only works when the container runs on a Mac host.${RESET}"
        echo ""
        ;;
      ios-android)
        echo -e "  ${BOLD}${CYAN}iOS/Android${RESET}"
        echo -e "    Install the OpenClaw companion app on your device."
        echo -e "    The app will pair with this gateway automatically."
        echo -e "    ${DIM}Check the OpenClaw docs for app download links.${RESET}"
        echo ""
        ;;
      *)
        echo -e "  ${BOLD}${CYAN}${channel}${RESET}"
        echo -e "    See OpenClaw docs for setup instructions."
        echo ""
        ;;
    esac
  done
}

# ============================================================================
# PHASE 5: Verification & Summary
# ============================================================================

verify_and_finish() {
  # Verification (part of step 4)

  local score=0
  local total=9
  local issues=()

  echo ""
  echo -e "  ${BOLD}Security Scorecard (Docker)${RESET}"
  echo -e "  ${DIM}┌──────────────────────────────────────────┬────────┐${RESET}"

  # Check 1: Container running
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "$CONTAINER_NAME"; then
    scorecard_pass "Container running"
    score=$((score + 1))
  else
    scorecard_fail "Container running"
    issues+=("Container is not running — try: ./docker-install.sh")
  fi

  # Check 2: Port bound to localhost only
  # docker port can report 0.0.0.0 on Docker Desktop for Mac even when compose
  # specifies 127.0.0.1, so fall back to inspecting PortBindings from the config.
  local port_localhost=false
  if docker port "$CONTAINER_NAME" 2>/dev/null | grep -q "127.0.0.1"; then
    port_localhost=true
  elif docker inspect --format='{{json .HostConfig.PortBindings}}' "$CONTAINER_NAME" 2>/dev/null | grep -q '"HostIp":"127.0.0.1"'; then
    port_localhost=true
  elif grep -qE '^\s*-\s*"?127\.0\.0\.1:' "$SCRIPT_DIR/docker-compose.yml" 2>/dev/null; then
    port_localhost=true
  fi
  if [[ "$port_localhost" == true ]]; then
    scorecard_pass "Port bound to localhost only"
    score=$((score + 1))
  else
    scorecard_fail "Port bound to localhost only"
    issues+=("Port exposed to network — check docker-compose.yml ports section")
  fi

  # Check 3: Running as non-root
  # docker exec whoami can fail on Docker Desktop for Mac (timing/VM issues),
  # so fall back to inspecting the image's configured User.
  local container_user
  container_user="$(docker exec "$CONTAINER_NAME" whoami 2>/dev/null || echo '')"
  if [[ -z "$container_user" ]]; then
    container_user="$(docker inspect --format='{{.Config.User}}' "$CONTAINER_NAME" 2>/dev/null || echo '')"
  fi
  if [[ -n "$container_user" ]] && [[ "$container_user" != "root" ]] && [[ "$container_user" != "0" ]]; then
    scorecard_pass "Running as non-root (${container_user})"
    score=$((score + 1))
  else
    scorecard_fail "Running as non-root"
    issues+=("Container runs as root — rebuild the image")
  fi

  # Check 4: .env file permissions
  if [[ -f "$ENV_FILE" ]]; then
    if [[ "$HOST_OS" == "windows" ]]; then
      # Windows doesn't support Unix file permissions — auto-pass
      scorecard_pass "API key file exists (permissions N/A on Windows)"
      score=$((score + 1))
    else
      local env_perms
      env_perms="$(stat -f '%A' "$ENV_FILE" 2>/dev/null || stat -c '%a' "$ENV_FILE" 2>/dev/null || echo '')"
      if [[ "$env_perms" == "600" ]]; then
        scorecard_pass "API key file permissions (600)"
        score=$((score + 1))
      elif [[ -z "$env_perms" ]]; then
        scorecard_pass "API key file exists"
        score=$((score + 1))
      else
        scorecard_fail "API key file permissions (${env_perms})"
        fix "Fixing .env permissions to 600"
        chmod 600 "$ENV_FILE" 2>/dev/null || true
        score=$((score + 1))  # Fixed, so count it
      fi
    fi
  else
    scorecard_fail "API key file exists"
    issues+=("No .env file — re-run ./docker-install.sh")
  fi

  # Check 5: Capabilities dropped
  local caps
  caps="$(docker inspect --format='{{.HostConfig.CapDrop}}' "$CONTAINER_NAME" 2>/dev/null || echo '')"
  if echo "$caps" | grep -qi "all"; then
    scorecard_pass "Linux capabilities dropped"
    score=$((score + 1))
  else
    scorecard_fail "Linux capabilities dropped"
    issues+=("Capabilities not dropped — check docker-compose.yml cap_drop section")
  fi

  # Check 6: No privilege escalation
  local no_new_privs
  no_new_privs="$(docker inspect --format='{{.HostConfig.SecurityOpt}}' "$CONTAINER_NAME" 2>/dev/null || echo '')"
  if echo "$no_new_privs" | grep -q "no-new-privileges"; then
    scorecard_pass "Privilege escalation blocked"
    score=$((score + 1))
  else
    scorecard_fail "Privilege escalation blocked"
    issues+=("no-new-privileges not set — check docker-compose.yml security_opt")
  fi

  # Check 7: Memory limit set
  local mem_limit
  mem_limit="$(docker inspect --format='{{.HostConfig.Memory}}' "$CONTAINER_NAME" 2>/dev/null || echo '0')"
  if [[ "$mem_limit" -gt 0 ]]; then
    local mem_mb=$((mem_limit / 1048576))
    scorecard_pass "Memory limit set (${mem_mb}MB)"
    score=$((score + 1))
  else
    scorecard_fail "Memory limit set"
    issues+=("No memory limit — a runaway process could use all RAM")
  fi

  # Check 8: PID namespace isolation
  local pid_mode
  pid_mode="$(docker inspect --format='{{.HostConfig.PidMode}}' "$CONTAINER_NAME" 2>/dev/null || echo '')"
  if [[ -z "$pid_mode" ]] || [[ "$pid_mode" == "container:"* ]] || [[ "$pid_mode" == "" ]]; then
    scorecard_pass "PID namespace isolated"
    score=$((score + 1))
  else
    scorecard_fail "PID namespace isolated"
    issues+=("Container can see host PIDs — remove pid_mode from compose")
  fi

  # Check 9: .gitignore protects .env
  if [[ -f "$SCRIPT_DIR/.gitignore" ]] && grep -q "^\.env$" "$SCRIPT_DIR/.gitignore" 2>/dev/null; then
    scorecard_pass ".env protected by .gitignore"
    score=$((score + 1))
  else
    scorecard_fail ".env protected by .gitignore"
    issues+=(".env not in .gitignore — API keys could be accidentally committed")
  fi

  echo -e "  ${DIM}└──────────────────────────────────────────┴────────┘${RESET}"

  local grade color
  if [[ $score -ge 8 ]]; then grade="HARDENED"; color="$GREEN"
  elif [[ $score -ge 6 ]]; then grade="GOOD"; color="$YELLOW"
  elif [[ $score -ge 4 ]]; then grade="FAIR"; color="$YELLOW"
  else grade="NEEDS ATTENTION"; color="$RED"
  fi

  echo ""
  echo -e "  ${BOLD}Score: ${color}${score}/${total} — ${grade}${RESET}"

  # Show issues if any
  if [[ ${#issues[@]} -gt 0 ]]; then
    echo ""
    echo -e "  ${BOLD}Issues to address:${RESET}"
    for issue in "${issues[@]}"; do
      echo -e "    ${RED}•${RESET} ${issue}"
    done
  fi

  # Show auto-fixes applied
  if [[ ${#FIXES_APPLIED[@]} -gt 0 ]]; then
    echo ""
    echo -e "  ${BOLD}Auto-fixes applied this run:${RESET}"
    for applied_fix in "${FIXES_APPLIED[@]}"; do
      echo -e "    ${MAGENTA}↻${RESET} ${applied_fix}"
    done
  fi

  # ── Summary ──
  echo ""
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

  # Only show the success message + URL if the container is actually running and healthy
  local final_health
  final_health="$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo 'none')"
  local final_state
  final_state="$(docker inspect --format='{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo 'unknown')"

  if [[ "$final_state" == "running" ]]; then
    echo -e "  ${BOLD}${GREEN}Your OpenClaw agent is running!${RESET}"
    echo ""

    # ── Retrieve gateway token if we don't have it yet ──
    if [[ -z "$GENERATED_GATEWAY_TOKEN" ]] && [[ -f "$ENV_FILE" ]]; then
      GENERATED_GATEWAY_TOKEN="$(grep '^OPENCLAW_GATEWAY_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || echo '')"
    fi

    # Last resort: try to extract from the container config
    if [[ -z "$GENERATED_GATEWAY_TOKEN" ]]; then
      log "Extracting gateway token from container config..."
      GENERATED_GATEWAY_TOKEN="$(docker exec "$CONTAINER_NAME" sh -c 'cat /home/openclaw/.openclaw/openclaw.json 2>/dev/null' | grep -o '"token"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"token"[[:space:]]*:[[:space:]]*"//' | sed 's/"$//' || echo '')"
    fi

    # ── Print the full dashboard URL with token ──
    if [[ -n "$GENERATED_GATEWAY_TOKEN" ]]; then
      local dashboard_url="http://localhost:${GATEWAY_PORT}/#token=${GENERATED_GATEWAY_TOKEN}"
      success "Dashboard ready"
      echo ""
      echo -e "  ${BOLD}Open this URL in your browser (token included — just click!):${RESET}"
      echo ""
      echo -e "    ${CYAN}${UNDERLINE}${dashboard_url}${RESET}"
    else
      # Absolute fallback
      echo -e "  ${BOLD}Open in your browser:${RESET}"
      echo -e "    ${CYAN}${UNDERLINE}http://localhost:${GATEWAY_PORT}${RESET}"
      echo ""
      echo -e "  ${BOLD}Get your gateway token:${RESET}"
      echo -e "    ${CYAN}docker exec -it $CONTAINER_NAME openclaw dashboard --no-open${RESET}"
    fi

    echo ""
    echo -e "  ${BOLD}${GREEN}Try it now:${RESET} Type ${BOLD}hello${RESET} in the chat box and press Enter!"
    echo -e "  ${DIM}Your AI agent should respond within a few seconds.${RESET}"
    echo ""

    # ── Auto-approve device pairing ──
    # The dashboard requires device pairing before it works. Sequence:
    #   1. Wait for the gateway to be fully healthy (HTTP 200 on /health)
    #   2. Open the browser (creates a WebSocket → pairing request)
    #   3. Poll for the pending request and auto-approve it
    # The user sees a clear 3-step progress indicator the whole time.

    echo ""
    echo -e "  ${BOLD}Setting up dashboard connection...${RESET}"
    echo ""

    # Step 1: Wait for gateway to be healthy before opening browser
    echo -ne "  [1/3] Waiting for gateway..."
    local gw_wait=0
    local gw_ready=false
    while [[ $gw_wait -lt 90 ]]; do
      if curl -sf --max-time 2 "http://127.0.0.1:${GATEWAY_PORT}/health" >/dev/null 2>&1; then
        gw_ready=true
        break
      fi
      local dots=""
      local dot_count=$(( (gw_wait / 3) % 4 ))
      for (( d=0; d<dot_count; d++ )); do dots+="."; done
      echo -ne "\r  [1/3] Waiting for gateway${dots}   "
      sleep 3
      gw_wait=$((gw_wait + 3))
    done

    if [[ "$gw_ready" == true ]]; then
      echo -e "\r  [1/3] Gateway ready             ${GREEN}✓${RESET}"
    else
      echo -e "\r  [1/3] Gateway not responding     ${YELLOW}!${RESET}"
      echo -e "        ${DIM}The gateway may still be starting. Try refreshing in a minute.${RESET}"
    fi

    # Step 2: Open the browser (now that gateway is ready)
    echo -ne "  [2/3] Opening browser..."
    local browser_opened=false
    case "$HOST_OS" in
      macos)
        open "$dashboard_url" 2>/dev/null && browser_opened=true ;;
      linux)
        if command_exists xdg-open; then
          xdg-open "$dashboard_url" 2>/dev/null && browser_opened=true
        elif command_exists sensible-browser; then
          sensible-browser "$dashboard_url" 2>/dev/null && browser_opened=true
        fi ;;
      wsl)
        cmd.exe /c start "" "$dashboard_url" >> "$LOG_FILE" 2>&1 && browser_opened=true ;;
      windows)
        cmd.exe /c start "" "$dashboard_url" >> "$LOG_FILE" 2>&1 && browser_opened=true ;;
    esac

    if [[ "$browser_opened" == true ]]; then
      echo -e "\r  [2/3] Opening browser            ${GREEN}✓${RESET}"
    else
      echo -e "\r  [2/3] Opening browser            ${YELLOW}manual${RESET}"
      echo -e "        ${BOLD}Please open the URL above in your browser now.${RESET}"
    fi

    # Step 3: Wait for the pairing request and auto-approve it
    # Give the browser a few seconds to load and establish the WebSocket connection
    sleep 3
    echo -ne "  [3/3] Pairing dashboard..."
    local pair_wait=0
    local paired=false

    while [[ $pair_wait -lt 60 ]]; do
      # Get the full device list output
      local devices_output
      devices_output="$(docker exec "$CONTAINER_NAME" openclaw devices list 2>/dev/null || true)"
      log "devices list output: $devices_output"

      # Extract pending request ID: grab ANY UUID from lines after "Pending"
      local pending_id=""
      if echo "$devices_output" | grep -q "Pending"; then
        # The UUID is in the "Request" column — extract it from between the Pending
        # header and the next section (Paired or end of output)
        pending_id="$(echo "$devices_output" | awk '/^Pending/,/^Paired|^$/' | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1 || true)"
      fi

      if [[ -n "$pending_id" ]]; then
        echo -ne "\r  [3/3] Pairing dashboard...approving"
        docker exec "$CONTAINER_NAME" openclaw devices approve "$pending_id" >> "$LOG_FILE" 2>&1 || true
        sleep 1
        echo -e "\r  [3/3] Dashboard paired            ${GREEN}✓${RESET}"
        paired=true
        break
      fi

      # Simple dot animation (avoids unicode spinner issues in piped terminals)
      local dots=""
      local dot_count=$(( (pair_wait / 2) % 4 ))
      for (( d=0; d<dot_count; d++ )); do dots+="."; done
      echo -ne "\r  [3/3] Pairing dashboard${dots}      "

      sleep 2
      pair_wait=$((pair_wait + 2))
    done

    if [[ "$paired" == true ]]; then
      echo ""
      echo -e "  ${GREEN}${BOLD}✓ Dashboard is live and connected!${RESET}"
      echo -e "    ${DIM}If it shows a blank page, just refresh (Cmd+R / Ctrl+R).${RESET}"
    else
      echo -e "\r  [3/3] Pairing dashboard          ${YELLOW}timed out${RESET}"
      echo ""
      echo -e "  ${YELLOW}⚠${RESET}  ${BOLD}Auto-pairing timed out${RESET} — the browser may not have loaded yet."
      echo ""
      echo -e "    ${BOLD}To fix:${RESET} Open the URL above in your browser, then run:"
      echo -e "      ${CYAN}docker exec openclaw-agent openclaw devices list${RESET}"
      echo -e "      ${CYAN}docker exec openclaw-agent openclaw devices approve <request-id>${RESET}"
      echo ""
      echo -e "    ${DIM}Or re-run: ${BOLD}./docker-install.sh --doctor${RESET}"
    fi

    echo ""

    # ── Channel-specific setup instructions (only if channels were selected) ──
    local selected_channels=""
    if [[ -f "$ENV_FILE" ]]; then
      selected_channels="$(grep '^OPENCLAW_CHANNELS=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
    fi

    if [[ -n "$selected_channels" ]]; then
      echo -e "  ${BOLD}Optional — Connect your channel(s):${RESET}"
      echo ""
      print_channel_instructions "$selected_channels"
      echo -e "    ${BOLD}Then run:${RESET} ${CYAN}docker exec -it $CONTAINER_NAME openclaw configure${RESET}"
      echo -e "    ${DIM}The wizard will ask you to paste the token(s) from above.${RESET}"
    else
      echo -e "  ${BOLD}Optional — Connect a chat channel later:${RESET}"
      echo -e "    ${DIM}Want to connect Slack, Discord, Telegram, or 20+ other channels?${RESET}"
      echo -e "    ${CYAN}./docker-install.sh --channels${RESET}"
    fi
  else
    echo -e "  ${BOLD}${YELLOW}OpenClaw installed but container is not running (state: ${final_state}).${RESET}"
    echo ""
    echo -e "  ${BOLD}To start it:${RESET}"
    echo -e "    ${CYAN}docker compose up -d${RESET}"
    echo ""
    echo -e "  ${BOLD}Once running, open:${RESET}"
    echo -e "    ${CYAN}${UNDERLINE}http://localhost:${GATEWAY_PORT}${RESET}"
    echo ""
    echo -e "  ${BOLD}To diagnose:${RESET}"
    echo -e "    ${CYAN}./docker-install.sh --doctor${RESET}"
  fi

  echo ""
  echo -e "  ${BOLD}Everyday commands:${RESET}"
  echo -e "    See logs:         ${CYAN}docker logs -f $CONTAINER_NAME${RESET}"
  echo -e "    Stop:             ${CYAN}./docker-install.sh --stop${RESET}"
  echo -e "    Restart:          ${CYAN}docker compose restart${RESET}"
  echo -e "    Check status:     ${CYAN}./docker-install.sh --status${RESET}"
  echo -e "    Fix problems:     ${CYAN}./docker-install.sh --doctor${RESET}"
  echo ""
  echo -e "  ${BOLD}Configuration:${RESET}"
  echo -e "    Edit API keys:    ${CYAN}nano .env${RESET}  (then: docker compose restart)"
  echo -e "    Add channels:     ${CYAN}./docker-install.sh --channels${RESET}"
  echo -e "    Full uninstall:   ${CYAN}./docker-install.sh --uninstall${RESET}"
  echo ""
  echo -e "  ${DIM}Full log: ${LOG_FILE}${RESET}"
  echo ""
}

scorecard_pass() {
  printf "  ${DIM}│${RESET} %-40s ${DIM}│${RESET}  ${GREEN}✓${RESET}  ${DIM}│${RESET}\n" "$1"
}

scorecard_fail() {
  printf "  ${DIM}│${RESET} %-40s ${DIM}│${RESET}  ${RED}✗${RESET}  ${DIM}│${RESET}\n" "$1"
}

# ============================================================================
# DOCTOR MODE — Diagnose and fix problems
# ============================================================================

run_doctor() {
  banner
  echo -e "  ${BOLD}Running diagnostics...${RESET}"
  echo ""

  local problems=0
  local fixed=0

  # ── 1. Docker running? ──
  echo -e "  ${BOLD}Docker Environment${RESET}"
  if docker info &>/dev/null 2>&1; then
    success "Docker daemon is running"
  else
    error "Docker daemon is not running"
    problems=$((problems + 1))
    case "$HOST_OS" in
      macos)   info "Fix: Open Docker Desktop from Applications" ;;
      windows) info "Fix: Open Docker Desktop from the Start Menu" ;;
      wsl)     info "Fix: Open Docker Desktop on Windows, or run: ${BOLD}sudo service docker start${RESET}" ;;
      linux)   info "Fix: ${BOLD}sudo systemctl start docker${RESET}" ;;
    esac
  fi

  # ── 2. Docker version ──
  local docker_ver
  docker_ver="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'unknown')"
  info "Docker version: ${docker_ver}"

  # ── 3. Disk space ──
  local docker_space
  docker_space="$(docker system df 2>/dev/null | head -5 || echo 'unavailable')"
  verbose "Docker disk usage:\n${docker_space}"

  # ── 4. Container state ──
  echo ""
  echo -e "  ${BOLD}Container State${RESET}"

  local state
  state="$(docker inspect --format='{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo 'not found')"

  case "$state" in
    running)
      local health
      health="$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo 'no healthcheck')"
      success "Container: running (health: ${health})"

      if [[ "$health" == "unhealthy" ]]; then
        warn "Container is unhealthy — gateway may not be responding"
        problems=$((problems + 1))
        info "Recent health check output:"
        docker inspect --format='{{range .State.Health.Log}}{{.Output}}{{end}}' "$CONTAINER_NAME" 2>/dev/null | tail -3 | while IFS= read -r line; do
          echo -e "    ${DIM}${line}${RESET}"
        done
      fi
      ;;
    exited)
      local exit_code
      exit_code="$(docker inspect --format='{{.State.ExitCode}}' "$CONTAINER_NAME" 2>/dev/null || echo '?')"
      error "Container exited (code: ${exit_code})"
      problems=$((problems + 1))

      echo -e "  ${BOLD}Last 10 log lines:${RESET}"
      docker logs "$CONTAINER_NAME" 2>&1 | tail -10 | while IFS= read -r line; do
        echo -e "    ${DIM}${line}${RESET}"
      done

      echo ""
      if prompt_yn "Remove crashed container and restart?" "y"; then
        docker rm -f "$CONTAINER_NAME" >> "$LOG_FILE" 2>&1 || true
        compose_cmd up -d >> "$LOG_FILE" 2>&1 && {
          success "Container restarted"
          fixed=$((fixed + 1))
        } || {
          error "Restart failed. Try: ${BOLD}./docker-install.sh --uninstall && ./docker-install.sh${RESET}"
        }
      fi
      ;;
    "not found")
      warn "Container doesn't exist"
      problems=$((problems + 1))
      info "Start it: ${BOLD}./docker-install.sh${RESET}"
      ;;
    *)
      warn "Container in unexpected state: ${state}"
      problems=$((problems + 1))
      ;;
  esac

  # ── 5. .env file ──
  echo ""
  echo -e "  ${BOLD}Configuration${RESET}"

  if [[ -f "$ENV_FILE" ]]; then
    success ".env file exists"

    # Check permissions (skip on Windows — not supported)
    if [[ "$HOST_OS" == "windows" ]]; then
      success ".env permissions: N/A (Windows)"
    else
      local env_perms
      env_perms="$(stat -f '%A' "$ENV_FILE" 2>/dev/null || stat -c '%a' "$ENV_FILE" 2>/dev/null || echo '')"
      if [[ -z "$env_perms" ]]; then
        success ".env file exists"
      elif [[ "$env_perms" == "600" ]]; then
        success ".env permissions: 600 (secure)"
      else
        warn ".env permissions: ${env_perms} (should be 600)"
        problems=$((problems + 1))
        fix "Setting .env permissions to 600"
        chmod 600 "$ENV_FILE" 2>/dev/null || true
        fixed=$((fixed + 1))
      fi
    fi

    # Check that at least one provider key is set
    if env_has_any_provider_key "$ENV_FILE"; then
      local found_providers=""
      while IFS='=' read -r k _; do
        found_providers="${found_providers:+$found_providers, }$k"
      done < <(grep -E '^(ANTHROPIC|OPENAI|GOOGLE|MISTRAL|GROQ|DEEPSEEK|OPENROUTER|COHERE)_API_KEY=.+' "$ENV_FILE" 2>/dev/null)
      success "API key(s) configured in .env: ${BOLD}${found_providers}${RESET}"
    else
      error "No AI provider API key found in .env"
      problems=$((problems + 1))
      info "Fix: Re-run ${BOLD}./docker-install.sh${RESET} and select at least one provider"
    fi
  else
    error ".env file missing"
    problems=$((problems + 1))
    info "Fix: Re-run ${BOLD}./docker-install.sh${RESET}"
  fi

  # ── 6. Port ──
  echo ""
  echo -e "  ${BOLD}Network${RESET}"

  if docker port "$CONTAINER_NAME" 2>/dev/null | grep -q "127.0.0.1:$GATEWAY_PORT"; then
    success "Port $GATEWAY_PORT bound to localhost only"
  elif docker port "$CONTAINER_NAME" &>/dev/null 2>&1; then
    local port_binding
    port_binding="$(docker port "$CONTAINER_NAME" 2>/dev/null || echo 'unknown')"
    warn "Port binding: ${port_binding}"
    if echo "$port_binding" | grep -q "0.0.0.0"; then
      error "Port is exposed to ALL interfaces (not just localhost)!"
      problems=$((problems + 1))
    fi
  fi

  # ── 7. Connectivity test ──
  if [[ "$state" == "running" ]]; then
    if curl -sf "http://127.0.0.1:$GATEWAY_PORT/health" &>/dev/null 2>&1; then
      success "Gateway responds to health checks"
    else
      warn "Gateway not responding on port $GATEWAY_PORT"
      info "May still be starting up. Wait 30s and try: ${BOLD}curl http://localhost:$GATEWAY_PORT/health${RESET}"
    fi
  fi

  # ── Summary ──
  echo ""
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

  if [[ $problems -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}No problems found. Everything looks healthy!${RESET}"
  elif [[ $fixed -eq $problems ]]; then
    echo -e "  ${GREEN}${BOLD}Found ${problems} problem(s) — all fixed automatically.${RESET}"
  elif [[ $fixed -gt 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}Found ${problems} problem(s) — fixed ${fixed}, $(( problems - fixed )) need manual attention.${RESET}"
  else
    echo -e "  ${RED}${BOLD}Found ${problems} problem(s). See suggestions above.${RESET}"
  fi

  echo ""
  echo -e "  ${DIM}Full diagnostic log: ${LOG_FILE}${RESET}"
  echo ""
}

# ============================================================================
# STOP
# ============================================================================

stop_agent() {
  banner
  info "Stopping OpenClaw agent..."

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "$CONTAINER_NAME"; then
    compose_cmd down >> "$LOG_FILE" 2>&1
    success "Agent stopped"
  else
    info "Agent is not running"
  fi
}

# ============================================================================
# STATUS
# ============================================================================

show_status() {
  banner

  if ! docker info &>/dev/null 2>&1; then
    error "Docker is not running"
    info "Start Docker first, then check again"
    return
  fi

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "$CONTAINER_NAME"; then
    local health
    health="$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo 'unknown')"
    local started
    started="$(docker inspect --format='{{.State.StartedAt}}' "$CONTAINER_NAME" 2>/dev/null || echo 'unknown')"
    local mem_usage
    mem_usage="$(docker stats "$CONTAINER_NAME" --no-stream --format '{{.MemUsage}}' 2>/dev/null || echo 'unknown')"

    success "Agent is ${BOLD}running${RESET} (health: ${health})"
    info "Started: ${started}"
    info "Memory: ${mem_usage}"
    info "Logs: ${BOLD}docker logs -f $CONTAINER_NAME${RESET}"
  else
    # Check if it exists but stopped
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "$CONTAINER_NAME"; then
      local exit_code
      exit_code="$(docker inspect --format='{{.State.ExitCode}}' "$CONTAINER_NAME" 2>/dev/null || echo '?')"
      warn "Agent is ${BOLD}stopped${RESET} (exit code: ${exit_code})"
      info "Start it: ${BOLD}./docker-install.sh${RESET}"
      info "Diagnose: ${BOLD}./docker-install.sh --doctor${RESET}"
    else
      warn "Agent is ${BOLD}not installed${RESET}"
      info "Install: ${BOLD}./docker-install.sh${RESET}"
    fi
  fi
}

# ============================================================================
# UNINSTALL
# ============================================================================

uninstall() {
  banner
  echo -e "  ${BOLD}${RED}Uninstalling OpenClaw (Docker)${RESET}"
  echo ""

  # Stop container
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "$CONTAINER_NAME"; then
    info "Stopping and removing container..."
    compose_cmd down >> "$LOG_FILE" 2>&1 || docker rm -f "$CONTAINER_NAME" >> "$LOG_FILE" 2>&1 || true
    success "Container removed"
  fi

  # Remove image
  if docker images --format '{{.Repository}}' 2>/dev/null | grep -q "openclaw"; then
    info "Removing Docker image..."
    docker rmi "$(docker images --format '{{.ID}}' --filter "reference=*openclaw*" 2>/dev/null)" >> "$LOG_FILE" 2>&1 || true
    success "Image removed"
  fi

  # Remove volume
  if docker volume ls --format '{{.Name}}' 2>/dev/null | grep -q "openclaw-data"; then
    if prompt_yn "Delete all OpenClaw data (config, skills, etc.)?" "n"; then
      docker volume rm openclaw-data >> "$LOG_FILE" 2>&1 || true
      success "Data volume removed"
    else
      info "Data volume preserved (openclaw-data)"
    fi
  fi

  # Remove .env (securely)
  if [[ -f "$ENV_FILE" ]]; then
    if prompt_yn "Delete .env file (contains your API key)?" "n"; then
      # Overwrite before deleting (basic secure delete)
      dd if=/dev/urandom bs=1 count="$(wc -c < "$ENV_FILE")" of="$ENV_FILE" conv=notrunc &>/dev/null 2>&1 || true
      rm -f "$ENV_FILE"
      success ".env file securely removed"
    else
      info ".env file preserved"
    fi
  fi

  # Clean up any Docker build cache for this project
  docker builder prune -f --filter "label=maintainer=OpenClaw Docker Installer" >> "$LOG_FILE" 2>&1 || true

  echo ""
  echo -e "  ${GREEN}${BOLD}OpenClaw Docker uninstalled cleanly.${RESET}"
  echo ""
}

# ============================================================================
# MAIN
# ============================================================================

main() {
  parse_args "$@"
  setup_colors

  if [[ "$FLAG_UNINSTALL" == true ]]; then
    uninstall
    exit 0
  fi

  if [[ "$FLAG_STOP" == true ]]; then
    stop_agent
    exit 0
  fi

  if [[ "$FLAG_STATUS" == true ]]; then
    show_status
    exit 0
  fi

  if [[ "$FLAG_DOCTOR" == true ]]; then
    run_doctor
    exit 0
  fi

  banner

  if [[ "$FLAG_DRY_RUN" == true ]]; then
    info "${YELLOW}Dry-run mode — no changes will be made${RESET}"
    echo ""
  fi

  preflight_checks       # Phase 1: Docker + auto-troubleshoot 15+ issues
                         # (also sets RERUN_MODE via check_existing_container)

  case "$RERUN_MODE" in
    update_keys)
      # User chose "Update API keys" — re-enter keys, rebuild, verify
      configure_keys
      build_and_start
      harden_and_verify
      verify_and_finish
      ;;
    fresh|"")
      # Fresh install or first-time — run the full flow
      configure_keys
      build_and_start
      harden_and_verify
      verify_and_finish
      ;;
  esac
}

main "$@"
