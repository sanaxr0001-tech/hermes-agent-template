#!/bin/bash
set -e

# Mirror dashboard-ref-only's startup: create every directory hermes expects
# and seed a default config.yaml if the volume is empty. Without these,
# `hermes dashboard` endpoints that hit logs/, sessions/, cron/, etc. can fail
# with opaque errors even though no auth is actually involved.
mkdir -p /data/.hermes/cron /data/.hermes/sessions /data/.hermes/logs \
         /data/.hermes/memories /data/.hermes/skills /data/.hermes/pairing \
         /data/.hermes/hooks /data/.hermes/image_cache /data/.hermes/audio_cache \
         /data/.hermes/workspace /data/.hermes/skins /data/.hermes/plans \
         /data/.hermes/home

if [ ! -f /data/.hermes/config.yaml ] && [ -f /opt/hermes-agent/cli-config.yaml.example ]; then
  cp /opt/hermes-agent/cli-config.yaml.example /data/.hermes/config.yaml
fi

[ ! -f /data/.hermes/.env ] && touch /data/.hermes/.env

# Bootstrap OAuth tokens from env var (e.g. xAI Grok SuperGrok).
# Set HERMES_AUTH_JSON_BOOTSTRAP to the contents of a locally-generated
# ~/.hermes/auth.json. Written only once — subsequent token refreshes update
# the file in place on the persistent volume.
if [ ! -f /data/.hermes/auth.json ] && [ -n "${HERMES_AUTH_JSON_BOOTSTRAP}" ]; then
  printf '%s' "${HERMES_AUTH_JSON_BOOTSTRAP}" > /data/.hermes/auth.json
  chmod 600 /data/.hermes/auth.json
fi

# Clear any stale gateway PID file left over from the previous container.
# `hermes gateway` writes /data/.hermes/gateway.pid on start but does not
# remove it on SIGTERM. Since /data is a persistent volume, the file
# survives container restarts and causes every subsequent boot to exit with
# "ERROR gateway.run: PID file race lost to another gateway instance".
# No hermes process can be running at this point (we're pre-exec in a fresh
# container), so removing the file unconditionally is safe.
rm -f /data/.hermes/gateway.pid

# ── gbrain setup ─────────────────────────────────────────────────────────────
echo "[gbrain] starting setup..."
mkdir -p /data/.gbrain

# Verify gbrain binary exists
if ! command -v gbrain >/dev/null 2>&1; then
  echo "[gbrain] ERROR: gbrain binary not found in PATH=$(echo $PATH)"
  echo "[gbrain] checking /opt/bun/bin..."
  ls /opt/bun/bin/ 2>&1 || echo "[gbrain] /opt/bun/bin not found"
else
  echo "[gbrain] binary found at $(which gbrain)"
fi

# Bootstrap gbrain config pointing at Supabase on first run.
if [ ! -f /data/.gbrain/config.json ] && [ -n "${GBRAIN_DATABASE_URL}" ]; then
  echo "[gbrain] writing config.json..."
  printf '{"engine":"postgres","database_url":"%s"}\n' "${GBRAIN_DATABASE_URL}" \
    > /data/.gbrain/config.json
  chmod 600 /data/.gbrain/config.json
  echo "[gbrain] config.json written"
elif [ -z "${GBRAIN_DATABASE_URL}" ]; then
  echo "[gbrain] WARNING: GBRAIN_DATABASE_URL is not set — skipping setup"
else
  echo "[gbrain] config.json already exists"
fi

# Inject API keys and apply any pending schema migrations.
if [ -n "${GBRAIN_DATABASE_URL}" ] && command -v gbrain >/dev/null 2>&1; then
  _ZE_KEY="${ZEROENTROPY_API_KEY:-${ZEROENTROPHY_API_KEY}}"
  if [ -n "$_ZE_KEY" ]; then
    echo "[gbrain] setting zeroentropy_api_key..."
    gbrain config set zeroentropy_api_key "$_ZE_KEY" && echo "[gbrain] zeroentropy key set" || echo "[gbrain] WARNING: failed to set zeroentropy key"
  fi
  if [ -n "${ANTHROPIC_API_KEY}" ]; then
    echo "[gbrain] setting anthropic_api_key..."
    gbrain config set anthropic_api_key "${ANTHROPIC_API_KEY}" && echo "[gbrain] anthropic key set" || echo "[gbrain] WARNING: failed to set anthropic key"
  fi

  echo "[gbrain] applying migrations..."
  gbrain apply-migrations --yes && echo "[gbrain] migrations done" || echo "[gbrain] WARNING: migrations failed"

  if [ ! -f /data/.hermes/skills/RESOLVER.md ]; then
    echo "[gbrain] scaffolding skillpack into hermes..."
    cd /data/.hermes && gbrain skillpack scaffold --all && echo "[gbrain] skillpack scaffolded" || echo "[gbrain] WARNING: skillpack scaffold failed"
  else
    echo "[gbrain] skillpack already scaffolded"
  fi
fi

echo "[gbrain] setup complete"

exec python /app/server.py
