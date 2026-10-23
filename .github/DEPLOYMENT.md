# Deployment notes for rev-pro

Last updated: 2026-10-23 (branch `fix/ionos-deploy-now-build`)

## TL;DR

| Pipeline | File | What it does | Can run this app? |
|---|---|---|---|
| IONOS Deploy Now | `rev-pro-orchestration.yaml` -> `rev-pro-build.yaml` -> `deploy-to-ionos.yaml` | Builds in GitHub Actions, uploads the folder to IONOS shared (static/PHP) hosting | **No.** Deploy Now has no Node.js runtime, so `next start`, API routes, `proxy.ts`, Supabase SSR auth and Stripe webhooks cannot execute there. |
| Docker + Nginx on the IONOS VPS | `deploy.yml` + `Dockerfile` + `docker-compose.yml` + `nginx/` | SSH to the VPS, `docker compose up --build`, nginx TLS termination | **Yes.** This is the pipeline that actually serves https://rev-pro.dev. |

IONOS states that Deploy Now supports static sites, SPAs and PHP projects only and does not provide a Node.js runtime
(https://docs.ionos.space/docs/faq/, https://www.ionos.com/help/hosting/deploy-now/deploy-now-supported-technologies-and-scope-of-customer-service/).
Switching this app to `output: 'export'` is **not** an option: it would drop `/api/*`, `src/proxy.ts`, server-side
Supabase cookies and the Stripe webhook handlers.

The Deploy Now workflows are kept valid so the GitHub Actions UI stops reporting an invalid workflow, but the
production target with the existing IONOS subscription is the VPS (`217.154.11.234`) via `deploy.yml`.

## Required GitHub Actions secrets

Names only - values are never printed by any workflow.

### Build time (inlined into the client bundle by `next build`)

| Secret | Used by |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | `src/utils/supabase/client.ts`, `src/utils/supabase/server.ts`, `src/proxy.ts`, `src/app/api/keys/route.ts`, `src/app/api/webhooks/stripe/route.ts` |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | same as above |

Missing either of these is the root cause of
`Your project's URL and API key are required to create a Supabase client!` while prerendering `/login`
(`/login` is a client component that calls `createClient()` during render, and `createBrowserClient` throws when the
inlined values are `undefined`).

### IONOS Deploy Now (only if you keep that pipeline)

| Secret | Used by |
|---|---|
| `IONOS_API_KEY` | all three Deploy Now workflows |
| `IONOS_SSH_KEY` | `deploy-to-ionos.yaml` |
| `IONOS_DEPLOYMENT_<DEPLOYMENT_ID>_SSH_USERNAME` | `deploy-to-ionos.yaml` (generated per deployment by IONOS) |

### VPS pipeline (`deploy.yml`)

| Secret | Used by |
|---|---|
| `SERVER_USER` | `appleboy/ssh-action` |
| `SERVER_SSH_KEY` | `appleboy/ssh-action` |

### Runtime only (go in `.env.production` on the VPS, **not** GitHub secrets)

`NEXT_PUBLIC_SITE_URL`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `STRIPE_SECRET_KEY`,
`STRIPE_WEBHOOK_SECRET_KEY`, `BASIC_PRICE_ID`, `PRO_PRICE_ID`, `LANGDOCK_API_KEY`, `LANGDOCK_REV_AI_AGENT_ID`,
`USE_MOCK_TRANSCRIPTION` (optional).

Note: some routes read `SUPABASE_URL` and others read `NEXT_PUBLIC_SUPABASE_URL`; set both to the same value on the VPS.

## Known gaps in the VPS pipeline (not changed in this branch)

- `deploy.yml` clones with `${{ secrets.GITHUB_TOKEN }}`; that token is scoped to the workflow run and will not
  authenticate a clone **on the VPS** for a private repo. Use a deploy key or a fine-grained PAT stored as a secret.
- `Dockerfile` runs `npm start` (`next start`) from a full copy of `/app` instead of `node .next/standalone/server.js`.
  It works, but does not benefit from `output: 'standalone'`. Switching requires copying `.next/static` and `public`
  into the standalone folder.
- `deploy.yml` does not pass `NEXT_PUBLIC_SUPABASE_*` into the Docker build. The image build on the VPS relies on
  `.env.production` being present there; `docker-compose.yml` only passes it at runtime (`env_file`), so make sure
  `.env.production` also exists before `docker compose build` or add `args:` to the compose `build:` block.
