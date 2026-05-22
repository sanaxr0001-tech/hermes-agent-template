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
  const isPooler = url.hostname.endsWith(".pooler.supabase.com");
  console.log(`[gbrain] database target ${url.hostname}:${port}`);
  if (url.port === "5432" && !isPooler) {
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

  if [ ! -d /opt/gbrain ]; then
    echo "[gbrain] WARNING: /opt/gbrain source checkout not found; skillpack setup skipped"
  else
    echo "[gbrain] ensuring Hermes skillpack files..."
    if (cd /opt/gbrain && OPENCLAW_WORKSPACE=/data/.hermes gbrain skillpack scaffold --all --workspace /data/.hermes); then
      echo "[gbrain] skillpack scaffold complete"
    else
      echo "[gbrain] WARNING: skillpack scaffold failed"
    fi

    # The OpenClaw plugin scaffold list is smaller than gbrain's own
    # skills/RESOLVER.md + manifest.json set. Hermes uses the gbrain doctor
    # view, so restore the bundled skill dirs that doctor still routes to.
    for _GBRAIN_SKILL in publish frontmatter-guard smoke-test ask-user setup cold-start migrate; do
      if [ -d "/opt/gbrain/skills/${_GBRAIN_SKILL}" ] &&
         [ ! -f "/data/.hermes/skills/${_GBRAIN_SKILL}/SKILL.md" ]; then
        mkdir -p "/data/.hermes/skills/${_GBRAIN_SKILL}"
        cp -R "/opt/gbrain/skills/${_GBRAIN_SKILL}/." "/data/.hermes/skills/${_GBRAIN_SKILL}/"
        echo "[gbrain] restored skills/${_GBRAIN_SKILL}"
      fi
    done

    # gbrain v0.33+ scaffold intentionally leaves routing files untouched, but
    # `gbrain doctor` still validates resolver reachability and conformance.
    # Publish the bundled dispatcher/manifest into Hermes so existing volumes
    # with only a placeholder resolver self-heal on boot.
    for _GBRAIN_META in RESOLVER.md manifest.json; do
      if [ -f "/opt/gbrain/skills/${_GBRAIN_META}" ]; then
        cp "/opt/gbrain/skills/${_GBRAIN_META}" "/data/.hermes/skills/.${_GBRAIN_META}.tmp" &&
          mv "/data/.hermes/skills/.${_GBRAIN_META}.tmp" "/data/.hermes/skills/${_GBRAIN_META}" &&
          echo "[gbrain] refreshed skills/${_GBRAIN_META}"
      else
        echo "[gbrain] WARNING: /opt/gbrain/skills/${_GBRAIN_META} not found"
      fi
    done

    node <<'NODE'
const fs = require("fs");
const path = "/data/.hermes/skills/RESOLVER.md";
let resolver = fs.readFileSync(path, "utf8");
const skill = "`skills/skillpack-harvest/SKILL.md`";
const replacement = `| "harvest this skill into gbrain", "publish this skill to gbrain", "lift this skill upstream", "lift this skill back into gbrain", "publish my fork-only skill", "gbrain bundle", "harvest my skill into gbrain", "promote this skill to gbrain", "want this skill in the gbrain bundle", "custom skill into the gbrain core" | ${skill} |`;
const pattern = /^\| .* \| `skills\/skillpack-harvest\/SKILL\.md` \|$/m;
if (!resolver.includes("custom skill into the gbrain core") && pattern.test(resolver)) {
  resolver = resolver.replace(pattern, replacement);
  fs.writeFileSync(path, resolver);
  console.log("[gbrain] patched skillpack-harvest resolver synonyms");
}
NODE

    # Existing persistent volumes may carry pre-v0.37.3 copies of these bundled
    # skills. Refresh them from the pinned /opt/gbrain source of truth so the
    # v0.37.3 skill_brain_first doctor check sees the compliance metadata.
    if [ -f /opt/gbrain/skills/functional-area-resolver/SKILL.md ] &&
       [ -f /data/.hermes/skills/functional-area-resolver/SKILL.md ]; then
      cp /opt/gbrain/skills/functional-area-resolver/SKILL.md /data/.hermes/skills/functional-area-resolver/SKILL.md
      echo "[gbrain] refreshed functional-area-resolver brain-first metadata"
    fi

    if [ -f /opt/gbrain/skills/strategic-reading/SKILL.md ] &&
       [ -f /data/.hermes/skills/strategic-reading/SKILL.md ]; then
      cp /opt/gbrain/skills/strategic-reading/SKILL.md /data/.hermes/skills/strategic-reading/SKILL.md
      echo "[gbrain] refreshed strategic-reading brain-first metadata"
    fi

    _RESOLVER_STATUS=0
    gbrain check-resolvable --json --skills-dir /data/.hermes/skills >/tmp/gbrain-resolver-health.json 2>/tmp/gbrain-resolver-health.err || _RESOLVER_STATUS=$?
    if node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync("/tmp/gbrain-resolver-health.json", "utf8"));
const report = data.report || {};
const summary = report.summary || {};
const errors = Array.isArray(report.errors) ? report.errors.length : 0;
const warnings = Array.isArray(report.warnings) ? report.warnings.length : 0;
console.log(`[gbrain] resolver health ${report.ok ? "ok" : "fail"}: ${summary.reachable || 0}/${summary.total_skills || 0} reachable, ${errors} error(s), ${warnings} warning(s)`);
for (const issue of (report.errors || []).slice(0, 12)) {
  console.log(`[gbrain] resolver error ${issue.type || "unknown"}:${issue.skill || "unknown"}: ${issue.action || issue.message || ""}`);
}
process.exit(report.ok ? 0 : 1);
'; then
      :
    else
      if [ -s /tmp/gbrain-resolver-health.err ]; then
        echo "[gbrain] resolver health stderr:"
        sed -n '1,20p' /tmp/gbrain-resolver-health.err 2>/dev/null || true
      fi
      if [ "${_RESOLVER_STATUS}" -ne 0 ]; then
        echo "[gbrain] WARNING: resolver health command exited ${_RESOLVER_STATUS}"
      fi
    fi
  fi
  echo "[gbrain] setup complete"
}

if [ -n "${GBRAIN_DATABASE_URL}" ] && command -v gbrain >/dev/null 2>&1; then
  run_gbrain_post_boot_setup &
fi

echo "[gbrain] setup scheduled"

exec python /app/server.py
