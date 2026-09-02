#!/bin/sh
# Container entrypoint for the Coolify deployment.
#
# Everything here is idempotent, so it is safe to run on every boot and on every
# replica restart. Set AFFINE_SKIP_MIGRATION=true if you prefer to run
# `node ./scripts/self-host-predeploy.js` as a separate one-shot job instead.
set -eu

# AFFINE_SERVER_HOST is what the server puts into invite links, OAuth redirects
# and mail. Fall back to the URL Coolify generated for the service, then to the
# container's own hostname, so a misconfigured deploy still boots.
if [ -z "${AFFINE_SERVER_HOST:-}" ]; then
  if [ -n "${COOLIFY_FQDN:-}" ]; then
    AFFINE_SERVER_HOST="${COOLIFY_FQDN}"
  else
    AFFINE_SERVER_HOST="localhost"
  fi
  export AFFINE_SERVER_HOST
fi

if [ "${AFFINE_SKIP_MIGRATION:-false}" != "true" ]; then
  # Generates ~/.affine/config/private.key on first boot, then applies the
  # Prisma schema and the data migrations.
  echo "[affine] running self-host predeploy"
  node ./scripts/self-host-predeploy.js
else
  echo "[affine] AFFINE_SKIP_MIGRATION=true, skipping predeploy"
fi

echo "[affine] starting server on ${AFFINE_SERVER_HOST}:${AFFINE_SERVER_PORT:-3010}"
exec "$@"
