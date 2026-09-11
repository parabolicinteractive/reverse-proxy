#!/bin/sh
# Runs the certificate tests in the tls image, where mkcert and openssl are.
# Fixtures only, so it is safe against a running stack.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

exec docker compose run --rm --no-deps --entrypoint /usr/local/bin/test.sh tls
