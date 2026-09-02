# Deploying this fork of AFFiNE on Coolify

Everything here builds AFFiNE from **this repository's source**. Nothing pulls
`ghcr.io/toeverything/affine`.

## Files

| File | What it is |
| --- | --- |
| [`../../docker-compose.yaml`](../../docker-compose.yaml) | Default stack. Compiles the source on the deploy host. |
| [`Dockerfile`](./Dockerfile) | Self-contained build: Rust native addon → frontends → server. |
| [`entrypoint.sh`](./entrypoint.sh) | Runs the key generation and DB migrations, then starts the server. |
| [`compose.registry.yaml`](./compose.registry.yaml) | Same stack, but pulls an image CI built from this repo. |
| [`env.example`](./env.example) | Every knob, annotated. |
| [`../../.github/workflows/selfhost-image.yml`](../../.github/workflows/selfhost-image.yml) | Builds and pushes `ghcr.io/<owner>/affine`. |

## Pick a path

**Build on the server** — one moving part, but the deploy host does the work.
A cold build wants roughly **8 GB of RAM** and takes **30-60 minutes**; warm
BuildKit caches make redeploys much faster. Rust and rspack are the expensive
parts.

**Build in CI, pull on the server** — run the `Self-host Image` workflow, then
deploy `compose.registry.yaml`. Deploys become a docker pull. Use this if your
Coolify box has less than 8 GB of RAM, which most do.

## Build on the server

1. Coolify → **New Resource** → **Private Repository (with GitHub App)** or
   **Public Repository**, pointed at this repo.
2. Build Pack: **Docker Compose**.
   - Base Directory: `/`
   - Docker Compose Location: `/docker-compose.yaml`
3. Branch: whichever you deploy from.
4. Set a domain on the `affine` service (or let Coolify generate one).
5. Add any optional environment variables (SMTP especially — see below).
6. **Deploy**. Watch the build logs; the Rust stage looks stalled but is not.

Coolify fills in the rest: `SERVICE_FQDN_AFFINE_3010` provisions the domain and
routes it to port 3010, and `SERVICE_PASSWORD_POSTGRES` / `SERVICE_PASSWORD_REDIS`
generate the datastore credentials.

## Build in CI, pull on the server

1. Run the **Self-host Image** workflow (Actions → Self-host Image → Run
   workflow), or push a `selfhost-v*` tag.
2. It publishes `ghcr.io/<owner>/affine:latest` plus `sha-<commit>` tags.
3. Make the GHCR package public, or add a registry credential under
   Coolify → Server → Docker Registries.
4. Deploy with Docker Compose Location `/.docker/coolify/compose.registry.yaml`.
5. Pin a specific tag with `AFFINE_IMAGE=ghcr.io/<owner>/affine:sha-<commit>`
   when you want reproducible rollbacks.

## First boot

The entrypoint generates the server private key, applies the Prisma migrations
and runs the data migrations before the server starts — all idempotent, so it
re-runs safely on every restart. The container is unhealthy until that
finishes, which is why the healthcheck allows a 120s grace period.

Then open the domain and complete the setup page to create the first admin
account. The admin panel lives at `/admin`.

## Configuration worth knowing

**SMTP is not optional in practice.** Without `MAILER_*`, invitations, password
resets and email sign-in fail silently. Set it before inviting anyone.

**`AFFINE_SERVER_HTTPS`** must match how users reach the server. It defaults to
`true`, which is right behind Coolify's proxy. Set it to `false` only for a
plain-HTTP local run.

**Coolify's domain changes.** If you change the service domain in the Coolify
UI after the first deploy, check that `AFFINE_SERVER_EXTERNAL_URL` and
`AFFINE_SERVER_HOST` picked up the new value in the Environment Variables tab —
Coolify has [a known bug](https://github.com/coollabsio/coolify/issues/8912)
where the non-port-suffixed magic variables can go stale. Set them by hand if
they did not update; a wrong value breaks invite links and OAuth redirects.

**Build memory.** `NODE_HEAP_MB` (default 6144) sizes the bundler's heap.
Below about 4096 the web build tends to be OOM-killed. `AFFINE_HEAP_MB`
(default 2048) sizes the running server instead.

The full list is in [`env.example`](./env.example).

## Data and backups

Four named volumes carry all state:

- `affine-storage` → `/root/.affine/storage` — uploaded blobs. Losing it loses
  every image and attachment; object storage lives here, not in Postgres.
- `affine-config` → `/root/.affine/config` — the generated `private.key`. It
  signs sessions, so a fresh key logs everyone out.
- `affine-postgres` → documents, users, workspaces.
- `affine-redis` → queues and ephemeral state; the only one that is disposable.

Back up `affine-storage`, `affine-config` and `affine-postgres` together — a
Postgres dump on its own restores documents that point at blobs you no longer
have.

## Staying current with upstream

This deployment tracks whatever commit Coolify checks out, so upstream releases
arrive by merging `toeverything/AFFiNE` into this fork and redeploying. Read
[upstream's release notes](https://github.com/toeverything/AFFiNE/releases)
before merging — the migrations run automatically on boot and are not designed
to be reversible.

## Troubleshooting

**Build killed around the web bundle.** Out of memory. Lower `NODE_HEAP_MB`
only if the host has room to spare; otherwise switch to the CI-built image.

**Rust stage fails on a missing header or linker error.** The build needs
`clang`, `cmake`, `nasm` and `libclang-dev`; the Dockerfile installs them, so a
failure here usually means the base image changed. Pin `NODE_IMAGE` to a known
digest.

**Server starts, page loads blank.** Almost always `AFFINE_SERVER_EXTERNAL_URL`
disagreeing with the domain you opened. Compare them in the container's env.

**`prisma migrate deploy` fails on boot.** Check the `affine` container logs.
The predeploy script rolls back one known-bad historical migration before
applying the rest; anything else needs the upstream release notes.
