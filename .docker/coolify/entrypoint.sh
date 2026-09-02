#!/bin/sh
# Container entrypoint for the Coolify deployment.
#
# Everything here is idempotent, so it is safe to run on every boot and on every
# replica restart. Set AFFINE_SKIP_MIGRATION=true if you prefer to run
# `node ./scripts/self-host-predeploy.js` as a separate one-shot job instead.
set -eu

# Coolify hands multiple domains as a comma-separated list; the first one is the
# canonical domain shown in the UI.
first_of_list() {
  echo "${1%%,*}"
}

# AFFINE_SERVER_EXTERNAL_URL is what the server puts into invite links, OAuth
# redirects and mail. Prefer explicit config, then the domain Coolify injects.
if [ -z "${AFFINE_SERVER_EXTERNAL_URL:-}" ] && [ -n "${COOLIFY_URL:-}" ]; then
  AFFINE_SERVER_EXTERNAL_URL="$(first_of_list "${COOLIFY_URL}")"
  export AFFINE_SERVER_EXTERNAL_URL
fi

if [ -z "${AFFINE_SERVER_HOST:-}" ]; then
  if [ -n "${AFFINE_SERVER_EXTERNAL_URL:-}" ]; then
    # Strip the scheme, then any path and any :port.
    host="${AFFINE_SERVER_EXTERNAL_URL#*://}"
    host="${host%%/*}"
    AFFINE_SERVER_HOST="${host%%:*}"
  elif [ -n "${COOLIFY_FQDN:-}" ]; then
    AFFINE_SERVER_HOST="$(first_of_list "${COOLIFY_FQDN}")"
  else
    AFFINE_SERVER_HOST="localhost"
  fi
  export AFFINE_SERVER_HOST
fi

if [ -z "${AFFINE_SERVER_EXTERNAL_URL:-}" ]; then
  echo "[affine] warning: no external URL configured. Invite links and OAuth" >&2
  echo "[affine] redirects will point at ${AFFINE_SERVER_HOST}. Set" >&2
  echo "[affine] AFFINE_SERVER_EXTERNAL_URL to your public URL." >&2
fi

# AFFiNE and Prisma both want a single connection URL, but a password is not
# URL-safe text: `/`, `?` and `#` end the authority, `@` and `:` move its
# boundaries. Splicing one into a URL by hand mis-parses — a `/` in the password
# makes Prisma read the rest as the port and report "invalid port number".
# So assemble the URL here and percent-encode every part that came from a human.
if [ -z "${DATABASE_URL:-}" ]; then
  DATABASE_URL="$(node -e '
    const enc = encodeURIComponent;
    const user = enc(process.env.POSTGRES_USER || "affine");
    const password = enc(process.env.POSTGRES_PASSWORD || "");
    const host = process.env.POSTGRES_HOST || "postgres";
    const port = process.env.POSTGRES_PORT || "5432";
    const database = enc(process.env.POSTGRES_DB || "affine");
    process.stdout.write("postgresql://" + user + ":" + password + "@" + host + ":" + port + "/" + database);
  ')"
  export DATABASE_URL
  echo "[affine] database: ${POSTGRES_USER:-affine}@${POSTGRES_HOST:-postgres}:${POSTGRES_PORT:-5432}/${POSTGRES_DB:-affine}"
else
  echo "[affine] database: using the DATABASE_URL supplied in the environment"
fi

if [ "${AFFINE_SKIP_MIGRATION:-false}" != "true" ]; then
  # Generates ~/.affine/config/private.key on first boot, then applies the
  # Prisma schema and the data migrations.
  echo "[affine] running self-host predeploy"
  node ./scripts/self-host-predeploy.js
else
  echo "[affine] AFFINE_SKIP_MIGRATION=true, skipping predeploy"
fi

echo "[affine] starting server for ${AFFINE_SERVER_EXTERNAL_URL:-${AFFINE_SERVER_HOST}} on port ${AFFINE_SERVER_PORT:-3010}"
exec "$@"
