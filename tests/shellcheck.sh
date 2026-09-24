#!/usr/bin/env bash
# tests/shellcheck.sh - lint all bash sources (uses local shellcheck or docker)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

mapfile -t FILES < <(
  printf '%s\n' install.sh uninstall.sh scriptvps
  find lib modules parts tools -type f \( -name '*.sh' -o -name 'scriptvps' \) 2>/dev/null
)
# de-duplicate
mapfile -t FILES < <(printf '%s\n' "${FILES[@]}" | sort -u)

run_sc() {
  # shellcheck disable=SC2068
  shellcheck -x -e SC1091 ${@:-}
}

if command -v shellcheck >/dev/null 2>&1; then
  run_sc "${FILES[@]}"
elif command -v docker >/dev/null 2>&1; then
  echo "shellcheck lokal tidak ada; memakai docker..."
  docker run --rm -v "$ROOT":/mnt -w /mnt koalaman/shellcheck:stable -x -e SC1091 "${FILES[@]}"
else
  echo "shellcheck/docker tidak tersedia; menjalankan 'bash -n' saja." >&2
  for f in "${FILES[@]}"; do bash -n "$f" || exit 1; done
  echo "syntax OK"
fi
