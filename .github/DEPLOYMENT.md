# Deployment notes for rev-pro

Last updated: 2026-10-23 (branch `fix/ionos-deploy-now-build`)

## TL;DR

| Pipeline | Files | What it does | Can run this app? |
|---|---|---|---|
| IONOS Deploy Now | `rev-pro-orchestration.yaml` -> `rev-pro-build.yaml` -> `deploy-to-ionos.yaml` | Builds in GitHub Actions, uploads a folder to IONOS shared (static/PHP) hosting | **No.** Deploy Now has no Node.js runtime, so `next start`, API routes, `proxy.ts`, Supabase SSR auth and Stripe webhooks cannot execute there. |
| Docker + nginx on the IONOS VPS | `deploy.yml` -> `deploy.sh` + `Dockerfile` + `docker-compose.yml` + `nginx/` | rsync the repo to the VPS, build the standalone image, run behind nginx with Let's Encrypt | **Yes.** This is the pipeline that serves https://rev-pro.dev. |

IONOS states that Deploy Now supports static sites, SPAs and PHP projects only and does not provide a Node.js runtime
(https://docs.ionos.space/docs/faq/, https://www.ionos.com/help/hosting/deploy-now/deploy-now-supported-technologies-and-scope-of-customer-service/).
Switching this app to `output: 'export'` is **not** an option: it would drop `/api/*`, `src/proxy.ts`, server-side
Supabase cookies and the Stripe webhook handlers.

## VPS pipeline - how it works

```
GitHub Actions (deploy.yml)                      IONOS VPS 217.154.11.234
---------------------------                      -------------------------
checkout (contents: read, no persisted creds)
ssh key from SERVER_SSH_KEY  ------ rsync ------> <DEPLOY_PATH>/   (code only; .env.production preserved)
ssh "bash deploy.sh"         ------ ssh --------> deploy.sh:
                                                    1. verify .env.production (names only), chmod 600
                                                    2. docker compose --env-file .env.production build
                                                         -> NEXT_PUBLIC_* become image build args
                                                    3. certbot bootstrap only if no certificate exists
                                                    4. docker compose up -d ; nginx -t ; nginx -s reload
                                                    5. smoke tests via https://rev-pro.dev (status codes)
```

### Credential model (least privilege)

| Credential | Where it lives | Scope | Why |
|---|---|---|---|
| `SERVER_SSH_KEY` | GitHub secret -> runner `~/.ssh/deploy_key` (deleted at job end) | Login as the deploy user on the VPS | The only credential that crosses the boundary. |
| `SERVER_SSH_KNOWN_HOSTS` | GitHub secret | Pins the VPS host key | Prevents MITM on first connection. Create with `ssh-keyscan -H 217.154.11.234`. Falls back to TOFU with a warning if unset. |
| `GITHUB_TOKEN` | Runner only, `contents: read` | `actions/checkout` | `persist-credentials: false`; `.git/` is excluded from rsync, so the token never reaches the server. |
| Nothing | VPS | - | **The server never authenticates to GitHub.** No PAT, no deploy key, no token in `.git/config`. The old flow embedded `GITHUB_TOKEN` in the remote URL and printed it via `set -x`; `deploy.sh` strips it from `.git/config` on first run. |

Why not a deploy key or PAT on the server? Both would be a long-lived credential sitting on an internet-facing host, with
read access to the repository, that has to be rotated. Push-based rsync needs no credential on the server at all.

### Docker image

- Multi-stage; runtime stage contains only `.next/standalone`, `.next/static`, `public/` and runs `node server.js` as
  user `node`. The old image shipped the full `/app` tree (including `.env.production`) and ran `npm start`.
- Build args (`NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `NEXT_PUBLIC_SITE_URL`) are **public**
  values inlined into the browser bundle. Secrets are never build args (they would be stored in image metadata).
- Runtime secrets come exclusively from compose `env_file: .env.production`. `.dockerignore` excludes `.env*`.
- The app container is not published on the host; only nginx (80/443) is. nginx forwards `Host`, `X-Forwarded-Proto`,
  `X-Forwarded-Host`, which `src/app/auth/callback/route.ts` and the Stripe checkout routes rely on.

## Required configuration

Names only - values are never printed by any workflow or script.

### GitHub Actions secrets

| Secret | Used by | Required |
|---|---|---|
| `SERVER_USER` | `deploy.yml` | yes |
| `SERVER_SSH_KEY` | `deploy.yml` | yes |
| `SERVER_SSH_KNOWN_HOSTS` | `deploy.yml` | recommended |
| `NEXT_PUBLIC_SUPABASE_URL` | `ci-build.yaml`, `rev-pro-build.yaml` | for CI builds |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | `ci-build.yaml`, `rev-pro-build.yaml` | for CI builds |
| `IONOS_API_KEY`, `IONOS_SSH_KEY`, `IONOS_DEPLOYMENT_<ID>_SSH_USERNAME` | Deploy Now workflows | only if Deploy Now is kept |

GitHub Actions **variable** (optional): `DEPLOY_PATH` - absolute directory on the VPS (default: `rev-pro` under the
deploy user's home, matching the previous behaviour; `TODO.md` mentions `/opt/rev-pro`).

### `.env.production` on the VPS (never committed, `chmod 600`)

| Variable | Needed at | Read by |
|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | build + runtime | `src/utils/supabase/*`, `src/proxy.ts`, `api/keys`, `api/webhooks/stripe` |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | build + runtime | same |
| `NEXT_PUBLIC_SITE_URL` | build + runtime | OAuth `redirectTo`, `auth/callback`, Stripe success/cancel URLs |
| `SUPABASE_URL` | runtime | `api/ai-tool`, `api/stripe-webhook` (set to the same value as the public URL) |
| `SUPABASE_SERVICE_ROLE_KEY` | runtime | `api/keys`, `api/ai-tool`, `api/stripe-webhook`, `api/webhooks/stripe` |
| `STRIPE_SECRET_KEY` | runtime | `api/checkout`, `api/checkout-session`, both webhook routes |
| `STRIPE_WEBHOOK_SECRET_KEY` | runtime | `api/stripe-webhook`, `api/webhooks/stripe` |
| `BASIC_PRICE_ID`, `PRO_PRICE_ID` | runtime | `api/checkout`, `api/stripe-webhook` |
| `LANGDOCK_API_KEY`, `LANGDOCK_REV_AI_AGENT_ID` | runtime | `api/ai-tool` |
| `USE_MOCK_TRANSCRIPTION` | runtime | `api/ai-tool` (optional, `true` disables Langdock calls) |

`deploy.sh` fails if the two build-time Supabase variables are missing and warns (by name) about missing runtime ones.

## Smoke tests run by `deploy.sh`

| Request | Expected | Proves |
|---|---|---|
| `GET /` | 200 | SSR works through nginx/TLS |
| `GET /login` | 200 | browser Supabase client was built with URL + key |
| `GET /dashboard` | 307/308 | `src/proxy.ts` runs and redirects unauthenticated users |
| `GET /auth/callback` | 307/308 | OAuth callback route is served |
| `POST /api/stripe-webhook` | 400 | route reachable, signature verification active (500 would mean `STRIPE_SECRET_KEY` missing) |
| `POST /api/webhooks/stripe` | 400 | same for the second webhook path |
| `POST /api/transcribe` | 503 | route reachable (currently a stub) |

These prove routing and configuration, not business logic. A real Stripe test event (Stripe CLI / dashboard) and a
real OAuth login are still required after the first deploy.

## Known gaps / follow-ups

- Two Stripe webhook routes exist (`/api/stripe-webhook`, `/api/webhooks/stripe`). Only one should be registered in
  the Stripe dashboard; consider deleting the other.
- `/api/transcribe` is a 503 stub; `yt-dlp`/`ffmpeg` stay in the image for the planned implementation (`TODO.md`).
- Certificate renewal: `certbot` only runs during bootstrap. Add a cron/systemd timer on the VPS running
  `docker compose --env-file .env.production run --rm certbot renew` followed by `nginx -s reload`, or the cert will
  expire after 90 days.
- `nginx/conf.d/rev-pro.conf` is mounted read-only; `deploy.sh` renames it on the host during bootstrap, which is fine.
