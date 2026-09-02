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
| [`../../.github/workflows/selfhost-image.yml`](../../.github/workflows/selfhost-image.yml) | Builds and pushes `ghcr.io/<owner>/<repo>`. |

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
4. Set the domain on the `affine` service, including the port —
   `https://note.example.com:3010`. Coolify routes the domain to that container
   port; without the port it has nothing to bind to.
5. Environment Variables → add **`POSTGRES_PASSWORD`** and **`REDIS_PASSWORD`**.
   Generate them with `openssl rand -hex 24`. Both are declared `${VAR:?}`, so
   Coolify flags them in the UI and refuses to deploy while either is empty.
   Any characters are safe — see *Passwords and the connection URL* below.
6. Add the optional settings you want (SMTP especially — see below).
7. **Deploy**. Watch the build logs; the Rust stage looks stalled but is not.

The public URL resolves itself: the entrypoint reads the `COOLIFY_URL` and
`COOLIFY_FQDN` that Coolify injects. Set `AFFINE_SERVER_EXTERNAL_URL` explicitly
if you want to pin it.

### Why no `SERVICE_FQDN_*` magic variables

Coolify's `SERVICE_FQDN_*` / `SERVICE_PASSWORD_*` magic variables belong to the
**Service** resource type. Under the **Docker Compose build pack** they are not
generated, so they expand to empty strings — which would mean a Postgres with no
password and a blank public URL. Hence the explicit variables above.

One more Coolify-ism worth knowing: in `${VAR:?default}` Coolify reads the text
after `:?` as a value to **prefill**, not as an error message. That is why the
required variables here are written bare — `${POSTGRES_PASSWORD:?}`. Adding a
friendly message would hand the database that message as its password.

For the same reason, every `environment:` block here uses mapping syntax
(`KEY: value`) rather than the list form (`- KEY=value`). Coolify rewrites the
compose file before building and turns list entries into numeric keys, which
docker compose rejects with `non-string key in services.affine.environment: 0`
([coolify#5064](https://github.com/coollabsio/coolify/issues/5064),
[coolify#5235](https://github.com/coollabsio/coolify/issues/5235)). Keep the
mapping syntax.

## Build in CI, pull on the server

1. Run the **Self-host Image** workflow (Actions → Self-host Image → Run
   workflow), or push a `selfhost-v*` tag.
2. It publishes `ghcr.io/<owner>/<repo>:latest` plus `sha-<commit>` tags.
3. Make the GHCR package public, or add a registry credential under
   Coolify → Server → Docker Registries.
4. Deploy with Docker Compose Location `/.docker/coolify/compose.registry.yaml`.
   The same domain and required-variable rules apply.
5. Pin a specific tag with `AFFINE_IMAGE=ghcr.io/<owner>/<repo>:sha-<commit>`
   when you want reproducible rollbacks.

### Passwords and the connection URL

The Postgres password reaches the server as `POSTGRES_PASSWORD`, and the
entrypoint builds `DATABASE_URL` from the `POSTGRES_*` parts with each one
percent-encoded. That is not decoration: a password is arbitrary text, a URL is
not. `/`, `?` and `#` terminate a URL's authority and `@` and `:` move its
boundaries, so splicing a raw password into `postgresql://user:PASSWORD@host/db`
mis-parses. `/` is the memorable one — Prisma reads what follows as the port and
fails with `P1013: invalid port number in database URL`, which never mentions
the password.

Redis is handed its password through the environment and reads it inside the
container, so spaces and shell metacharacters are safe there too.

To use an external database, set `DATABASE_URL` directly. The entrypoint then
uses it verbatim and ignores the `POSTGRES_*` parts — percent-encode the
password yourself.

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

**Coolify's domain changes.** After changing the service domain, redeploy so
the container picks up the new `COOLIFY_URL`. If you pinned
`AFFINE_SERVER_EXTERNAL_URL`, update it too — a stale value breaks invite links
and OAuth redirects, and nothing else will tell you.

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

**Deploy stops at `non-string key in services.affine.environment: 0`.** Coolify
mangled a list-form `environment:` block. Convert it to mapping syntax; see
*Why no `SERVICE_FQDN_*` magic variables* above.

**Deploy stops at `required variable POSTGRES_PASSWORD is missing a value`.**
Working as intended — set `POSTGRES_PASSWORD` and `REDIS_PASSWORD` in the
Environment Variables tab.

**Server starts, page loads blank.** Almost always `AFFINE_SERVER_EXTERNAL_URL`
disagreeing with the domain you opened. The startup log prints what it resolved;
compare that with the URL in your address bar.

**`P1013: invalid port number in database URL`.** A password containing `/`
spliced into a connection URL. Fixed — the entrypoint percent-encodes it now.
If you set `DATABASE_URL` yourself, encode the password in it.

**`prisma migrate deploy` fails on boot.** Check the `affine` container logs.
The predeploy script rolls back one known-bad historical migration before
applying the rest; anything else needs the upstream release notes.
