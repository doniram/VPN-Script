#!/usr/bin/env bash
# tests/docker-smoke.sh - syntax + lint + CLI smoke test inside Ubuntu 22.04/24.04
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${1:-ubuntu:22.04}"

echo "==> Menjalankan smoke test di $IMAGE"
docker run --rm -v "$ROOT":/src -w /src "$IMAGE" bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq shellcheck openssl coreutils curl >/dev/null

  echo "-- bash -n (syntax)"
  while IFS= read -r f; do bash -n "$f" || { echo "SYNTAX FAIL: $f"; exit 1; }; done < <(printf "%s\n" install.sh uninstall.sh scriptvps; find lib modules parts tools -type f \( -name "*.sh" -o -name "scriptvps" \) 2>/dev/null)
  echo "syntax OK"

  echo "-- shellcheck"
  shellcheck -x -e SC1091 install.sh uninstall.sh scriptvps lib/*.sh modules/*.sh parts/*.sh tools/*.sh

  echo "-- CLI smoke"
  export SVPS_ETC=/tmp/svps SVPS_NO_LOGFILE=1 SVPS_DB=/tmp/svps/db SVPS_CACHE=/tmp/svps/.cache SVPS_CLIENTS=/tmp/svps/clients
  ./scriptvps version
  ./scriptvps license mode off
  ./scriptvps license status
  ./scriptvps list ssh --json

  echo "-- license flow"
  KEY=$(./tools/license-add.sh --name "Test" --ips "203.0.113.10" --file /tmp/licenses.tsv | head -n1)
  ./tools/license-check.sh --key "$KEY" --file /tmp/licenses.tsv --ip 203.0.113.10
  ./scriptvps license mode repo
  ./scriptvps license url "file:///tmp/licenses.tsv" || true

  echo "SMOKE OK"
'
