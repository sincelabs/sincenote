# syntax=docker/dockerfile:1.7
#
# Self-contained AFFiNE build for Coolify.
#
# Unlike .github/deployment/node/Dockerfile — which only repackages artifacts a
# CI job built beforehand — this file compiles everything from the source in
# this repository: the Rust native addon, the web/admin/mobile frontends and the
# NestJS server. The resulting image is a drop-in replacement for
# ghcr.io/toeverything/affine.
#
# Build (single arch, matching the host):
#   docker build -f .docker/coolify/Dockerfile --build-arg GIT_SHA=$(git rev-parse HEAD) -t affine:local .
#
# Expect ~8 GB of RAM and 30-60 minutes for a cold build. Warm BuildKit caches
# bring that down a lot, so keep the builder around between deploys.

ARG NODE_IMAGE=node:22-bookworm-slim

# ---------------------------------------------------------------------------
# base — toolchain shared by every build stage
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS base

ENV CI=1 \
    HUSKY=0 \
    ELECTRON_SKIP_BINARY_DOWNLOAD=1 \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    YARN_ENABLE_GLOBAL_CACHE=1 \
    YARN_GLOBAL_FOLDER=/yarn-cache

WORKDIR /app

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       ca-certificates \
       curl \
       g++ \
       git \
       make \
       openssl \
       python3 \
  && rm -rf /var/lib/apt/lists/* \
  && corepack enable

# ---------------------------------------------------------------------------
# native — Rust napi addon (@affine/server-native)
#
# Runs in parallel with the JS stages under BuildKit; it is by far the slowest
# part of the build.
# ---------------------------------------------------------------------------
FROM base AS native

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       clang \
       cmake \
       libclang-dev \
       libssl-dev \
       llvm-dev \
       nasm \
       perl \
       pkg-config \
  && rm -rf /var/lib/apt/lists/*

ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH

# The toolchain file pins the exact channel; `rustup show` materialises it.
COPY rust-toolchain.toml ./
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal --default-toolchain none \
  && rustup show

# tree-sitter needs _BSD_SOURCE; see .github/actions/build-rust/action.yml.
ENV CC="clang -D_BSD_SOURCE" \
    TARGET_CC="clang -D_BSD_SOURCE"

COPY . .

RUN --mount=type=cache,target=/yarn-cache,sharing=locked \
    yarn workspaces focus @affine/server-native

RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/app/target,sharing=locked \
    yarn workspace @affine/server-native build

# packages/backend/native/index.js probes `server-native.node` first and then
# falls back to arch-suffixed names. The bundler resolves every one of those
# requires statically, so all four have to exist at build time; docker-clean
# drops the ones that do not match TARGETARCH later on.
RUN cd packages/backend/native \
  && ln -f server-native.node server-native.x64.node \
  && ln -f server-native.node server-native.arm64.node \
  && ln -f server-native.node server-native.armv7.node

# ---------------------------------------------------------------------------
# builder — frontends + server bundle
# ---------------------------------------------------------------------------
FROM base AS builder

# `stable` | `beta` | `internal` | `canary`
ARG BUILD_TYPE=stable
# Without a .git directory the html plugin cannot resolve a commit; Coolify
# exposes SOURCE_COMMIT, GitHub Actions exposes GITHUB_SHA. It can also arrive
# empty — Coolify has a toggle for it — which the build step substitutes for.
ARG GIT_SHA=
ARG NODE_HEAP_MB=6144

ENV BUILD_TYPE=${BUILD_TYPE} \
    GITHUB_SHA=${GIT_SHA} \
    NODE_OPTIONS=--max-old-space-size=${NODE_HEAP_MB}

COPY . .

RUN --mount=type=cache,target=/yarn-cache,sharing=locked \
    yarn install --immutable --inline-builds

# An empty GITHUB_SHA sends the html plugin looking for a git repository that
# the build context does not carry, so give it a placeholder instead.
RUN export GITHUB_SHA="${GITHUB_SHA:-0000000000000000000000000000000000000000}" \
  && yarn affine @affine/web build \
  && yarn affine @affine/admin build \
  && yarn affine @affine/mobile build

COPY --from=native /app/packages/backend/native/server-native*.node ./packages/backend/native/

RUN yarn workspace @affine/server build

# ---------------------------------------------------------------------------
# prod-deps — runtime node_modules only
# ---------------------------------------------------------------------------
FROM base AS prod-deps

COPY . .

RUN --mount=type=cache,target=/yarn-cache,sharing=locked \
    yarn workspaces focus @affine/server --production

RUN yarn workspace @affine/server prisma generate

# ---------------------------------------------------------------------------
# assets — assemble the runtime tree and strip it down
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS assets

ARG TARGETARCH
ARG TARGETVARIANT

WORKDIR /app

# Prisma resolves its engines against the system OpenSSL.
RUN apt-get update \
  && apt-get install -y --no-install-recommends openssl ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/packages/backend/server/package.json   ./package.json
COPY --from=builder /app/packages/backend/server/schema.prisma  ./schema.prisma
COPY --from=builder /app/packages/backend/server/migrations     ./migrations
COPY --from=builder /app/packages/backend/server/scripts        ./scripts
COPY --from=builder /app/packages/backend/server/dist           ./dist
COPY --from=prod-deps /app/node_modules                         ./node_modules

COPY --from=builder /app/packages/frontend/apps/web/dist        ./static
COPY --from=builder /app/packages/frontend/admin/dist           ./static/admin
COPY --from=builder /app/packages/frontend/apps/mobile/dist     ./static/mobile

RUN AFFINE_DOCKER_CLEAN=1 \
    TARGETARCH="${TARGETARCH}" \
    TARGETVARIANT="${TARGETVARIANT}" \
    node ./scripts/docker-clean.mjs

# docker-clean keeps only `server-native.<arch>.node` and deletes the unsuffixed
# `server-native.node` along with the other architectures. The loader in
# packages/backend/native/index.js probes the unsuffixed name first and falls
# back to the arch-suffixed one inside a try/catch, so that would still work —
# but only if the try/catch survives bundling and minification intact. Restore
# the name the loader reaches for first so the fallback never has to fire, and
# fail the build loudly if no addon survived at all.
RUN set -eu; \
    if [ ! -f dist/server-native.node ]; then \
      for candidate in dist/server-native.*.node; do \
        [ -f "$candidate" ] || continue; \
        ln "$candidate" dist/server-native.node; \
        break; \
      done; \
    fi; \
    test -f dist/server-native.node \
      || { echo "no server-native addon survived docker-clean" >&2; exit 1; }; \
    ls -l dist/server-native*.node

# ---------------------------------------------------------------------------
# runtime
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS runtime

WORKDIR /app

RUN apt-get update \
  && apt-get install -y --no-install-recommends openssl libjemalloc2 ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# jemalloc keeps RSS in check for the long-lived doc workers.
ENV LD_PRELOAD=libjemalloc.so.2 \
    NODE_ENV=production \
    AFFINE_SERVER_PORT=3010

COPY --from=assets /app /app
COPY --chmod=0755 .docker/coolify/entrypoint.sh /usr/local/bin/affine-entrypoint.sh

EXPOSE 3010

ENTRYPOINT ["/usr/local/bin/affine-entrypoint.sh"]
CMD ["node", "./dist/main.js"]
