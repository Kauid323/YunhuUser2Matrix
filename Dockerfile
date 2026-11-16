# syntax=docker/dockerfile:1

# Build on the native architecture and cross-compile for the target platform.
# This keeps multi-arch builds fast (no Go compiler emulation under QEMU).
FROM --platform=$BUILDPLATFORM golang:1.23-alpine AS build
ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT
ARG VERSION=dev
# 可选：国内构建可加 --build-arg GOPROXY=https://goproxy.cn,direct
ARG GOPROXY
WORKDIR /src
COPY go.mod go.sum ./
RUN if [ -n "${GOPROXY:-}" ]; then export GOPROXY="$GOPROXY"; fi; \
    go mod download
COPY . .
RUN set -eu; \
    if [ -n "${GOPROXY:-}" ]; then export GOPROXY="$GOPROXY"; fi; \
    goarm=""; \
    if [ "${TARGETARCH:-}" = "arm" ] && [ -n "${TARGETVARIANT:-}" ]; then \
      goarm="${TARGETVARIANT#v}"; \
    fi; \
    CGO_ENABLED=0 GOOS="${TARGETOS:-linux}" GOARCH="${TARGETARCH:-amd64}" GOARM="$goarm" \
      go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/yhmatrix ./cmd/yhmatrix; \
    CGO_ENABLED=0 GOOS="${TARGETOS:-linux}" GOARCH="${TARGETARCH:-amd64}" GOARM="$goarm" \
      go build -trimpath -ldflags "-s -w" -o /out/yhprobe ./cmd/yhprobe

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata \
 && addgroup -g 10001 -S yhmatrix \
 && adduser -u 10001 -S -G yhmatrix yhmatrix
WORKDIR /app
# The binaries MUST live in /app: relative paths (./data, ./element-web, ...)
# are resolved against the executable's directory, not the working directory.
COPY --from=build /out/yhmatrix /out/yhprobe /app/
COPY config.example.yaml /app/config.example.yaml
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
# VOLUME below would create /app/data owned by root, so create and chown it here.
RUN chmod +x /app/yhmatrix /app/yhprobe /usr/local/bin/docker-entrypoint.sh \
 && mkdir -p /app/data \
 && chown -R yhmatrix:yhmatrix /app
USER yhmatrix
VOLUME ["/app/data"]
EXPOSE 8008
# Every config key can be overridden with YHMATRIX_* env vars, so the image is
# usable without mounting a config.yaml at all.
ENV YHMATRIX_SERVER_NAME=localhost \
    YHMATRIX_SERVER_BIND=:8008 \
    YHMATRIX_DATA_DIR=/app/data \
    YHMATRIX_LOG_LEVEL=info
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8008/_matrix/client/versions || exit 1
ENTRYPOINT ["/bin/sh", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["yhmatrix"]
