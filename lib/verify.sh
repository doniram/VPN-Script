#!/usr/bin/env bash
# lib/verify.sh - safe download helpers with optional checksum verification

[[ -n "${__SVPS_VERIFY_LOADED:-}" ]] && return 0
__SVPS_VERIFY_LOADED=1

# download <url> <dest> [--insecure]
download() {
  local url="$1" dest="$2" insecure=0
  [[ "${3:-}" == "--insecure" ]] && insecure=1
  local tmp; tmp="$(mktemp)"
  local curl_args=(-fsSL --retry 3 --retry-delay 2 --max-time 180 -o "$tmp")
  (( insecure )) && curl_args+=(-k)
  if ! curl "${curl_args[@]}" "$url"; then
    rm -f "$tmp"
    err "Gagal mengunduh: $url"
    return 1
  fi
  mkdir -p "$(dirname "$dest")"
  mv "$tmp" "$dest"
}

# download_verified <url> <dest> [sha256] [--insecure]
# If sha256 is given, the file is verified; otherwise a warning is logged.
download_verified() {
  local url="$1" dest="$2" sha="${3:-}" insecure="${4:-}"
  download "$url" "$dest" "$insecure" || return 1
  if [[ -n "$sha" && "$sha" != "-" ]]; then
    local got; got="$(sha256sum "$dest" | awk '{print $1}')"
    if [[ "$got" != "$sha" ]]; then
      rm -f "$dest"
      err "Checksum TIDAK cocok untuk $(basename "$dest") (harap dijelaskan: $got != $sha)"
      return 1
    fi
    ok "Checksum OK: $(basename "$dest")"
  else
    warn "Tanpa checksum untuk $(basename "$dest") - tidak diverifikasi."
  fi
}

# fetch_cached <url> <cachefile> [ttl_hours]
# Returns body on stdout. Uses cache within TTL; falls back to stale cache when offline.
fetch_cached() {
  local url="$1" cache="$2" ttl="${3:-24}"
  mkdir -p "$(dirname "$cache")" 2>/dev/null || true
  if [[ -f "$cache" ]]; then
    local age=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
    if (( age >= 0 && age < ttl * 3600 )); then
      cat "$cache"; return 0
    fi
  fi
  if curl -fsSL --max-time 15 "$url" -o "$cache.tmp" 2>/dev/null; then
    mv "$cache.tmp" "$cache"
    cat "$cache"; return 0
  fi
  if [[ -f "$cache" ]]; then
    warn "Gagal memperbarui cache; memakai salinan lama ($cache)."
    cat "$cache"; return 0
  fi
  return 1
}
