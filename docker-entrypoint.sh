#!/bin/sh
# Container entrypoint for yhmatrix.
#
# Usage:
#   docker run <image>                      # run the server with defaults
#   docker run <image> -mock               # pass flags straight to yhmatrix
#   docker run <image> yhprobe info        # run the bundled probe tool instead
#
# Config resolution (see README "配置文件从哪读"):
#   1. -config <path>            (explicit flag)
#   2. $YHMATRIX_CONFIG          (explicit env var)
#   3. /app/config.yaml          (next to the executable; may be bind-mounted)
#   4. built-in defaults + YHMATRIX_* env overrides
#
# On first start we materialise a writable config.yaml from the shipped example
# so the server does not silently run on built-in defaults. It is only a
# starting point: env vars still win, and mounting your own file skips the copy.

set -eu

case "${1:-}" in
  yhmatrix|yhprobe)
    bin="$1"
    shift
    ;;
  *)
    bin="yhmatrix"
    ;;
esac

if [ "$bin" = "yhmatrix" ] \
   && [ -z "${YHMATRIX_CONFIG:-}" ] \
   && [ -f /app/config.example.yaml ]; then
  cp /app/config.example.yaml /app/config.yaml
fi

exec "/app/$bin" "$@"
