#!/usr/bin/env bash
# =============================================================================
# Rev-Pro production deploy - runs ON the IONOS VPS.
#
# Invoked by .github/workflows/deploy.yml over SSH after the repository contents
# were rsync'ed into this directory. Can also be run manually on the server:
#     cd <deploy dir> && bash deploy.sh
#
# Security properties:
#   - No shell tracing (never `set -x`): commands reference secret files.
#   - No Git credentials: the server never authenticates against GitHub.
#   - Secret VALUES are never printed; checks print variable NAMES only.
#   - .env.production is never created or overwritten by this script (only a
#     legacy copy from /opt/.env.production when the file is absent).
# =============================================================================
set -euo pipefail

DOMAIN="${DOMAIN:-rev-pro.dev}"
ENV_FILE=".env.production"
REPO_SLUG="${REPO_SLUG:-coderxp1/rev-pro}"
cd "$(dirname "${BASH_SOURCE[0]}")"

log()  { printf '[deploy %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
err()  { printf '[deploy %s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
warn() { printf '[deploy %s] WARNING: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# ---------------------------------------------------------------------------
# 0. Docker Compose detection. --env-file makes the NEXT_PUBLIC_* values from
#    .env.production available for build-arg interpolation in docker-compose.yml
# ---------------------------------------------------------------------------
if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  err "Docker Compose not found in PATH"; exit 1
fi
COMPOSE+=(--env-file "$ENV_FILE")

# ---------------------------------------------------------------------------
# 1. One-time cleanup: the previous deploy flow stored a GitHub token inside
#    .git/config on this server. Strip it if it is still there.
# ---------------------------------------------------------------------------
if [ -f .git/config ] && grep -q 'x-access-token' .git/config; then
  git remote set-url origin "https://github.com/${REPO_SLUG}.git"
  log "Removed embedded access token from .git remote URL (legacy deploy flow)."
  log "The .git directory is no longer needed on this server and can be deleted."
fi

# ---------------------------------------------------------------------------
# 2. Environment file: must exist, must be private, must contain the
#    build-time public Supabase configuration. Values are never echoed.
# ---------------------------------------------------------------------------
if [ ! -f "$ENV_FILE" ] && [ -f /opt/.env.production ]; then
  cp /opt/.env.production "$ENV_FILE"
  log "Copied /opt/.env.production -> $ENV_FILE (legacy location)."
fi
if [ ! -f "$ENV_FILE" ]; then
  err "$ENV_FILE not found in $(pwd). Create it on the server; it must never be committed."
  exit 1
fi
chmod 600 "$ENV_FILE"

has_var() { grep -Eq "^[[:space:]]*(export[[:space:]]+)?$1=[^[:space:]]" "$ENV_FILE"; }

# Inlined into the browser bundle by `next build` -> required before the image build.
BUILD_REQUIRED=(NEXT_PUBLIC_SUPABASE_URL NEXT_PUBLIC_SUPABASE_ANON_KEY)
# Read at runtime by API routes / proxy. Missing ones degrade specific features.
RUNTIME_REQUIRED=(
  NEXT_PUBLIC_SITE_URL          # OAuth redirect + Stripe success/cancel URLs
  SUPABASE_URL                  # api/ai-tool, api/stripe-webhook (service-role client)
  SUPABASE_SERVICE_ROLE_KEY     # api/keys, api/ai-tool, both Stripe webhook routes
  STRIPE_SECRET_KEY             # api/checkout, api/checkout-session, webhooks
  STRIPE_WEBHOOK_SECRET_KEY     # api/stripe-webhook, api/webhooks/stripe
  BASIC_PRICE_ID PRO_PRICE_ID   # api/checkout, api/stripe-webhook
  LANGDOCK_API_KEY LANGDOCK_REV_AI_AGENT_ID  # api/ai-tool
)
fail=0
for v in "${BUILD_REQUIRED[@]}"; do
  has_var "$v" || { err "$v is missing/empty in $ENV_FILE (required at build time)"; fail=1; }
done
for v in "${RUNTIME_REQUIRED[@]}"; do
  has_var "$v" || warn "$v is missing/empty in $ENV_FILE (the feature that reads it will fail at runtime)"
done
[ "$fail" -eq 0 ] || exit 1
log "Environment file check passed (names verified, values not shown)."

# ---------------------------------------------------------------------------
# 3. Build the application image (public config is passed as build args by
#    docker-compose.yml; secrets stay in env_file and never enter the image).
# ---------------------------------------------------------------------------
log "Building rev-pro image ..."
"${COMPOSE[@]}" build --pull rev-pro

# ---------------------------------------------------------------------------
# 4. TLS bootstrap (only when no certificate exists in the certbot volume).
#    Uses compose's own volume mapping, so the compose project prefix is
#    handled correctly.
# ---------------------------------------------------------------------------
have_certs() {
  "${COMPOSE[@]}" run --rm --no-deps --entrypoint sh certbot \
    -c "test -f /etc/letsencrypt/live/${DOMAIN}/fullchain.pem" >/dev/null 2>&1
}
if have_certs; then
  log "TLS certificate for ${DOMAIN} present - skipping bootstrap."
else
  log "No TLS certificate for ${DOMAIN} - running HTTP-01 bootstrap."
  [ -f nginx/conf.d/rev-pro.conf ] && mv nginx/conf.d/rev-pro.conf nginx/conf.d/rev-pro.conf.disabled
  "${COMPOSE[@]}" up -d nginx
  sleep 5
  "${COMPOSE[@]}" run --rm certbot
  [ -f nginx/conf.d/rev-pro.conf.disabled ] && mv nginx/conf.d/rev-pro.conf.disabled nginx/conf.d/rev-pro.conf
fi

# ---------------------------------------------------------------------------
# 5. Start / update services and reload nginx so config changes are picked up.
# ---------------------------------------------------------------------------
log "Starting services ..."
"${COMPOSE[@]}" up -d --remove-orphans
"${COMPOSE[@]}" exec -T nginx nginx -t >/dev/null 2>&1 || { err "nginx configuration test failed"; "${COMPOSE[@]}" exec -T nginx nginx -t; exit 1; }
"${COMPOSE[@]}" exec -T nginx nginx -s reload >/dev/null 2>&1 || "${COMPOSE[@]}" restart nginx

# ---------------------------------------------------------------------------
# 6. Smoke tests through nginx (TLS, Host header = real domain). Status codes
#    only - no response bodies, no secrets.
# ---------------------------------------------------------------------------
http_code() { # method path
  curl -sS -o /dev/null -w '%{http_code}' -k --max-time 20 \
    --resolve "${DOMAIN}:443:127.0.0.1" -X "$1" "https://${DOMAIN}$2" 2>/dev/null || echo "000"
}
if ! command -v curl >/dev/null 2>&1; then
  warn "curl not installed on the server - smoke tests skipped."
else
  log "Waiting for the app to answer ..."
  for _ in $(seq 1 30); do
    [ "$(http_code GET /robots.txt)" = "200" ] && break
    sleep 2
  done
  smoke_fail=0
  check() { # method path expected-regex description
    local code; code="$(http_code "$1" "$2")"
    if printf '%s' "$code" | grep -Eq "^($3)$"; then
      log "PASS $1 $2 -> $code  ($4)"
    else
      err "FAIL $1 $2 -> $code, expected $3  ($4)"; smoke_fail=1
    fi
  }
  check GET  /                         200      "landing page renders (SSR)"
  check GET  /login                    200      "login page renders (Supabase browser client has URL+key)"
  check GET  /dashboard                "307|308" "proxy.ts redirects unauthenticated users to /login"
  check GET  /auth/callback            "307|308" "OAuth callback route is live (redirects without code)"
  check POST /api/stripe-webhook       400      "Stripe webhook reachable; signature verification rejects unsigned request"
  check POST /api/webhooks/stripe      400      "Stripe webhook (alt path) reachable; signature verification rejects unsigned request"
  check POST /api/transcribe           503      "transcribe route reachable (currently a 503 stub by design)"
  if [ "$smoke_fail" -ne 0 ]; then
    err "Smoke tests failed. Containers are running; inspect with: ${COMPOSE[*]} logs --tail=200 rev-pro nginx"
    exit 1
  fi
fi

log "Deploy complete: https://${DOMAIN}"
