# ============================================================================
# OpenClaw Docker Image — Minimal, Secure, Beginner-Friendly
# ============================================================================
# Multi-stage build: small final image with only what OpenClaw needs.
# Security: non-root user, no unnecessary packages, minimal attack surface.
#
# Usage:
#   docker build -t openclaw .
#   docker compose up
# ============================================================================

# ── Stage 1: Build ──────────────────────────────────────────────────────────
# Install OpenClaw and its dependencies in a disposable builder stage.
# Nothing from this stage except the final npm package reaches the runtime.
FROM node:22-alpine AS builder

# Reduce npm noise and disable telemetry
ENV NPM_CONFIG_LOGLEVEL=warn \
    NPM_CONFIG_UPDATE_NOTIFIER=false

# Install git — required by some openclaw npm dependencies that use git:// URLs
RUN apk add --no-cache git \
  && npm install -g openclaw@latest \
  && npm cache clean --force \
  && apk del git

# ── Stage 2: Runtime ────────────────────────────────────────────────────────
# Minimal Alpine image with only what's needed to RUN OpenClaw.
FROM node:22-alpine

LABEL maintainer="OpenClaw Docker Installer"
LABEL description="OpenClaw AI Agent — containerized runtime"
LABEL org.opencontainers.image.source="https://github.com/shilpa-kulkarni-14/openclaw-docker-installer"

# Install only runtime dependencies (no build tools, no compilers)
# Each package is here for a reason:
#   openssl  — generate auth tokens, TLS
#   curl     — health checks
#   jq       — JSON config manipulation
#   tini     — proper PID 1 init (handles SIGTERM gracefully)
RUN apk add --no-cache \
    openssl \
    curl \
    jq \
    tini \
  # Remove apk cache and package index to shrink image
  && rm -rf /var/cache/apk/* /tmp/* \
  # Create non-root user with no login shell
  && addgroup -S openclaw \
  && adduser -S openclaw -G openclaw -h /home/openclaw -s /sbin/nologin

# Copy OpenClaw from builder (only the installed package, nothing else)
COPY --from=builder /usr/local/lib/node_modules /usr/local/lib/node_modules

# Recreate the bin symlink — COPY --from follows symlinks and copies file
# content, which breaks import.meta.url path resolution (the binary would
# look for dist/entry.mjs relative to /usr/local/bin/ instead of the
# package directory). A symlink preserves correct path resolution.
RUN ln -s /usr/local/lib/node_modules/openclaw/openclaw.mjs /usr/local/bin/openclaw

# Copy the entrypoint script
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

# Create config directory structure with correct ownership
# All directories are created as root then chowned — prevents symlink attacks
RUN mkdir -p /home/openclaw/.openclaw/.secrets \
  && chown -R openclaw:openclaw /home/openclaw \
  && chmod 700 /home/openclaw/.openclaw \
  && chmod 700 /home/openclaw/.openclaw/.secrets

# Switch to non-root user for all subsequent operations
USER openclaw
WORKDIR /home/openclaw

# Gateway port
# Inside container: binds to 0.0.0.0 (all interfaces)
# From host: docker-compose maps to 127.0.0.1 (localhost only)
EXPOSE 18789

# Health check — verifies gateway is responding
# Tries localhost first, then the container's hostname (covers all bind modes)
# start-period=30s gives the gateway time to initialize on slower machines
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -sf http://localhost:18789/health 2>/dev/null || \
      curl -sf http://$(hostname -i 2>/dev/null || echo localhost):18789/health 2>/dev/null || \
      curl -sf http://0.0.0.0:18789/health 2>/dev/null || exit 1

# Use tini as PID 1 for proper signal handling
# This ensures SIGTERM/SIGINT properly shut down Node.js
# Without this, `docker stop` can take 10s+ or leave zombie processes
ENTRYPOINT ["tini", "--", "/entrypoint.sh"]
