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
export GBRAIN_HOME="${GBRAIN_HOME:-/data}"
export OPENCLAW_WORKSPACE="${OPENCLAW_WORKSPACE:-/data/.hermes}"
if [ -n "${GBRAIN_DATABASE_URL}" ]; then
  export DATABASE_URL="${GBRAIN_DATABASE_URL}"
fi
mkdir -p /data/.gbrain

echo "[gbrain] embedding model ${GBRAIN_EMBEDDING_MODEL:-unset}"
echo "[gbrain] embedding dimensions ${GBRAIN_EMBEDDING_DIMENSIONS:-unset}"

# Verify gbrain binary exists
if ! command -v gbrain >/dev/null 2>&1; then
  echo "[gbrain] ERROR: gbrain binary not found in PATH=$(echo $PATH)"
  echo "[gbrain] checking /opt/bun/bin..."
  ls /opt/bun/bin/ 2>&1 || echo "[gbrain] /opt/bun/bin not found"
else
  echo "[gbrain] binary found at $(which gbrain)"
  if [ -d /opt/gbrain/.git ]; then
    echo "[gbrain] source commit $(cd /opt/gbrain && git rev-parse --short HEAD)"
  fi
  if gbrain providers list >/tmp/gbrain-providers.txt 2>&1 && grep -qi 'zeroentropy' /tmp/gbrain-providers.txt; then
    echo "[gbrain] zeroentropy provider registered"
  else
    echo "[gbrain] WARNING: zeroentropy provider not visible in gbrain providers list"
    sed -n '1,40p' /tmp/gbrain-providers.txt 2>/dev/null || true
  fi
fi

# Bootstrap or refresh gbrain config from Railway env. /data is persistent, so
# the previous config can outlive Railway var changes unless we update it here.
if [ -n "${GBRAIN_DATABASE_URL}" ]; then
  echo "[gbrain] refreshing config.json from GBRAIN_DATABASE_URL..."
  node -e '
const fs = require("fs");
const path = "/data/.gbrain/config.json";
let cfg = {};
try { cfg = JSON.parse(fs.readFileSync(path, "utf8")); } catch {}
cfg.engine = "postgres";
cfg.database_url = process.env.GBRAIN_DATABASE_URL;
fs.writeFileSync(path, JSON.stringify(cfg, null, 2) + "\n", { mode: 0o600 });
fs.chmodSync(path, 0o600);
try {
  const url = new URL(process.env.GBRAIN_DATABASE_URL);
  const port = url.port || "(default)";
  console.log(`[gbrain] database target ${url.hostname}:${port}`);
  if (url.port === "5432") {
    console.log("[gbrain] NOTE: Supabase direct port 5432 may be unreachable from Railway; use the pooler URL/port 6543 if connection is refused");
  }
} catch {
  console.log("[gbrain] WARNING: GBRAIN_DATABASE_URL could not be parsed for diagnostics");
}
'
  echo "[gbrain] config.json refreshed"
else
  echo "[gbrain] WARNING: GBRAIN_DATABASE_URL is not set — skipping setup"
fi

# Upstream gbrain reads provider credentials from process env. Keep secrets out
# of persistent config.json. Run migrations / skillpack setup after the web
# server starts so Railway's healthcheck is not blocked by long idempotent
# migration logs on existing Supabase databases.
run_gbrain_post_boot_setup() {
  echo "[gbrain] applying migrations..."
  gbrain apply-migrations --yes && echo "[gbrain] migrations done" || echo "[gbrain] WARNING: migrations failed"

  if [ ! -f /data/.hermes/skills/RESOLVER.md ] || [ ! -d /data/.hermes/skills/brain-ops ]; then
    echo "[gbrain] installing skillpack into hermes..."
    if [ ! -d /opt/gbrain ]; then
      echo "[gbrain] WARNING: /opt/gbrain source checkout not found; skillpack install skipped"
    else
      if [ ! -f /data/.hermes/skills/RESOLVER.md ]; then
        printf '# Hermes Skills Resolver\n\n' > /data/.hermes/skills/RESOLVER.md
      fi

      if (cd /opt/gbrain && OPENCLAW_WORKSPACE=/data/.hermes gbrain skillpack scaffold --all) && [ -d /data/.hermes/skills/brain-ops ]; then
        echo "[gbrain] skillpack scaffolded"
      else
        echo "[gbrain] skillpack scaffold did not populate Hermes; trying skillpack install --all..."
        if (cd /opt/gbrain && OPENCLAW_WORKSPACE=/data/.hermes gbrain skillpack install --all); then
          echo "[gbrain] skillpack installed"
        else
          _SKILLPACK_STATUS=$?
          if [ "$_SKILLPACK_STATUS" -eq 1 ]; then
            echo "[gbrain] skillpack install completed with local-edit skips"
          else
            echo "[gbrain] WARNING: skillpack install failed"
          fi
        fi
      fi
    fi
  else
    echo "[gbrain] skillpack already scaffolded"
  fi
  echo "[gbrain] setup complete"
}

if [ -n "${GBRAIN_DATABASE_URL}" ] && command -v gbrain >/dev/null 2>&1; then
  run_gbrain_post_boot_setup &
fi

echo "[gbrain] setup scheduled"

exec python /app/server.py
