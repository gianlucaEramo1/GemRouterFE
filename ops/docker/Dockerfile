# GemRouter container image. See docs/docker.md for deployment.
#
# Build context is the repository root (see docker-compose.yml); paths below
# are relative to it. Dockerfile.dockerignore next to this file keeps .env,
# data/ and other secrets out of the context (BuildKit, Docker 23+ default).
#
# Debian (glibc), not Alpine: the bundled Codex runtime in vendor/codex is a
# linux-x64 executable extracted at startup with `tar`.

ARG NODE_IMAGE=node:24.18.0-bookworm-slim

# ---- shared base with the pinned pnpm -------------------------------------
FROM ${NODE_IMAGE} AS base
RUN npm install -g pnpm@10.26.1
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./

# ---- production dependencies only -----------------------------------------
FROM base AS prod-deps
RUN pnpm install --frozen-lockfile --prod

# ---- TypeScript build ------------------------------------------------------
FROM base AS build
RUN pnpm install --frozen-lockfile
COPY tsconfig.json ./
COPY src ./src
RUN pnpm run build:app

# ---- runtime ---------------------------------------------------------------
FROM ${NODE_IMAGE} AS runtime

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*

ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=4024 \
    GEMROUTER_ROOT_DIR=/app \
    GEMROUTER_DATA_DIR=data \
    GEMROUTER_CODEX_PRIVATE_DIR=/home/node/.local/share/gemrouter-personal-control

WORKDIR /app

COPY --chown=node:node package.json ./
COPY --from=prod-deps --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist
COPY --chown=node:node vendor ./vendor
# Dashboard logo and wordmark, read from ../docs/assets relative to dist/.
COPY --chown=node:node docs/assets ./docs/assets

# Writable state lives in volumes (see docker-compose.yml). Creating the mount
# points here with the right owner and mode lets Docker initialise empty named
# volumes with them: the Codex profile code requires owner-only directories.
RUN mkdir -p /app/data /app/.runtime /app/backups "$GEMROUTER_CODEX_PRIVATE_DIR" \
  && chown node:node /app \
  && chown -R node:node /app/data /app/.runtime /app/backups /home/node/.local \
  && chmod 700 /app/data /app/backups "$GEMROUTER_CODEX_PRIVATE_DIR"

USER node

EXPOSE 4024

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:' + (process.env.PORT || 4024) + '/health').then((r) => process.exit(r.ok ? 0 : 1), () => process.exit(1))"]

CMD ["node", "dist/index.js"]
