# syntax=docker/dockerfile:1

# ---------- 1. dependencies ----------
FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

# ---------- 2. build ----------
FROM node:22-alpine AS builder
WORKDIR /app

# Browser-visible configuration is inlined by `next build`, so it MUST be
# supplied at build time. These are PUBLIC values (they ship to the browser).
# Never pass secrets as build args - build args are stored in image metadata.
ARG NEXT_PUBLIC_SUPABASE_URL
ARG NEXT_PUBLIC_SUPABASE_ANON_KEY
ARG NEXT_PUBLIC_SITE_URL=https://rev-pro.dev
ENV NEXT_PUBLIC_SUPABASE_URL=$NEXT_PUBLIC_SUPABASE_URL \
    NEXT_PUBLIC_SUPABASE_ANON_KEY=$NEXT_PUBLIC_SUPABASE_ANON_KEY \
    NEXT_PUBLIC_SITE_URL=$NEXT_PUBLIC_SITE_URL \
    NEXT_TELEMETRY_DISABLED=1

# Fail fast (without printing values) instead of failing deep inside prerender
# with "Your project's URL and API key are required to create a Supabase client!"
RUN if [ -z "$NEXT_PUBLIC_SUPABASE_URL" ] || [ -z "$NEXT_PUBLIC_SUPABASE_ANON_KEY" ]; then \
      echo "ERROR: build args NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY are required" >&2; exit 1; \
    fi

COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npm run build

# ---------- 3. runtime (Next.js standalone server) ----------
FROM node:22-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0

# Media tooling for the planned yt-dlp based /api/transcribe flow (see TODO.md).
# NOTE: as of this revision /api/transcribe is a 503 stub and nothing in src/
# invokes yt-dlp or ffmpeg; kept to avoid a behavioural change in the image.
RUN apk add --no-cache python3 py3-pip ffmpeg \
 && python3 -m pip install --no-cache-dir --break-system-packages yt-dlp

# Only the traced standalone output + static assets + public files are shipped.
# No source, no node_modules tree, no .env files end up in the final image.
COPY --from=builder --chown=node:node /app/public ./public
COPY --from=builder --chown=node:node /app/.next/standalone ./
COPY --from=builder --chown=node:node /app/.next/static ./.next/static

USER node
EXPOSE 3000

# robots.txt is a static app route: cheap, no DB access.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD wget -qO /dev/null http://127.0.0.1:3000/robots.txt || exit 1

CMD ["node", "server.js"]
