#!/usr/bin/env bash
# panel/build.sh - build the Go panel binary (via Docker or local Go)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PANEL="$ROOT/panel"
mkdir -p "$PANEL/bin"

if command -v go >/dev/null 2>&1 && [[ "${USE_DOCKER:-0}" != "1" ]]; then
  echo "==> Build dengan Go lokal"
  ( cd "$PANEL" && go mod tidy && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o bin/scriptvps-panel . )
elif command -v docker >/dev/null 2>&1; then
  echo "==> Build dengan Docker (golang:1.22)"
  docker run --rm -v "$ROOT":/src -w /src/panel golang:1.22 bash -lc \
    'go mod tidy && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o bin/scriptvps-panel .'
else
  echo "go/docker tidak tersedia; tidak bisa build panel." >&2
  exit 1
fi

ls -l "$PANEL/bin/scriptvps-panel"
