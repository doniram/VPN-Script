#!/usr/bin/env bash
# lib/accounts.sh - account listing, status and online detection

[[ -n "${__SVPS_ACCT_LOADED:-}" ]] && return 0
__SVPS_ACCT_LOADED=1

# shellcheck source=/dev/null
. "$SVPS_DIR/lib/ui.sh"

acct_days_left() { # <YYYY-MM-DD>
  local exp="$1"
  [[ -z "$exp" || "$exp" == "-" ]] && { echo "-"; return; }
  local t now
  t="$(date -d "$exp" +%s 2>/dev/null || echo 0)"
  now="$(date +%s)"
  local d=$(( (t - now) / 86400 ))
  if (( d < 0 )); then echo "expired"; else echo "$d hr"; fi
}

acct_used_gb() { # <svc> <name>
  local f="$SVPS_ETC/usage/$1.$2"
  local cum=0
  [[ -f "$f" ]] && cum="$(awk -F= '$1=="cum"{print $2}' "$f")"
  [[ -n "$cum" ]] || cum=0
  awk -v c="$cum" 'BEGIN{printf "%.2f", c/1073741824}'
}

# acct_online_ip <svc> <name> -> prints an IP (or empty)
acct_online_ip() {
  local svc="$1" name="$2"
  case "$svc" in
    ssh)
      { who 2>/dev/null | awk -v u="$name" '$1==u' | sed -n 's/.*(\([^)]*\)).*/\1/p' | head -n1; } || true ;;
    wg)
      local meta ip iface; meta="$(db_field wg "$name" 7)"; ip="${meta%/*}"
      iface="${WG_IFACE:-wg0}"
      [[ -n "$ip" ]] || return 0
      command -v wg >/dev/null 2>&1 || return 0
      { wg show "$iface" dump 2>/dev/null | awk -v ip="$ip" '
        NR>1 && $4 ~ ("^" ip "/") { if ($5>0) print $3; exit }' | sed 's/:[0-9]*$//'; } || true ;;
    ovpn)
      local log="/etc/openvpn/server/openvpn-status.log"
      [[ -r "$log" ]] || return 0
      { awk -F',' -v n="$name" '$1=="CLIENT_LIST" && $2==n {print $3; exit}' "$log" 2>/dev/null; } || true ;;
    ss)
      local port; port="$(printf '%s' "$(db_field ss "$name" 7)" | tr ';' '\n' | awk -F= '$1=="port"{print $2}')"
      [[ -n "$port" ]] || return 0
      { ss -Htn state established 2>/dev/null | awk -v p="$port" '
        { split($3,a,":"); sp=a[length(a)]; split($4,b,":"); dp=b[length(b)];
          if (sp==p) { print $4 } else if (dp==p) { print $3 } }' \
        | sed 's/:[0-9]*$//' | grep -vE '^(127\.|10\.|192\.168\.|::)' | head -n1; } || true ;;
  esac
  return 0
}

# acct_status <svc> <name> -> online|active|soon|expired
acct_status() {
  local svc="$1" name="$2"
  local exp; exp="$(db_field "$svc" "$name" 3)"
  if [[ -n "$exp" ]]; then
    local t; t="$(date -d "$exp" +%s 2>/dev/null || echo 0)"
    if (( t < $(date +%s) )); then echo expired; return; fi
    local d=$(( (t - $(date +%s)) / 86400 ))
    if (( d <= 3 )); then echo soon; return; fi
  fi
  if [[ -n "$(acct_online_ip "$svc" "$name")" ]]; then echo online; return; fi
  echo active
}

# acct_row <svc> <name> [include_service]
acct_row() {
  local svc="$1" name="$2" withsvc="${3:-0}"
  local line expires iplimit quota meta
  line="$(db_get "$svc" "$name")"
  [[ -z "$line" ]] && return 0
  IFS=$'\t' read -r name _ expires iplimit quota _ meta <<<"$line"
  local qinfo="0/0"
  if [[ "${quota:-0}" != "0" && -n "${quota:-}" ]]; then qinfo="$(acct_used_gb "$svc" "$name")/${quota}"; fi
  local status ip scol
  status="$(acct_status "$svc" "$name")"
  ip="$(acct_online_ip "$svc" "$name")"
  scol="$(ui_status_color "$status")"
  if (( withsvc )); then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$svc" "$name" "$expires" "$(acct_days_left "$expires")" "${iplimit:-0}" "$qinfo" "$scol" "${ip:--}"
  else
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$name" "$expires" "$(acct_days_left "$expires")" "${iplimit:-0}" "$qinfo" "$scol" "${ip:--}"
  fi
}

# acct_print <svc|all>
acct_print() {
  local target="$1"
  local hdr rows=() svc
  if [[ "$target" == "all" ]]; then
    hdr=$'LAYANAN\tNAMA\tEXPIRES\tSISA\tLIMIT\tKUOTA(GB)\tSTATUS\tIP'
    for svc in $SPVS_ALL_SERVICES; do
      [[ -f "$(db_file "$svc")" ]] || continue
      while IFS=$'\t' read -r name _ _ _ _ _ _; do
        [[ -z "$name" ]] && continue
        rows+=("$(acct_row "$svc" "$name" 1)")
      done < <(db_list "$svc")
    done
  else
    hdr=$'NAMA\tEXPIRES\tSISA\tLIMIT\tKUOTA(GB)\tSTATUS\tIP'
    while IFS=$'\t' read -r name _ _ _ _ _ _; do
      [[ -z "$name" ]] && continue
      rows+=("$(acct_row "$target" "$name" 0)")
    done < <(db_list "$target")
  fi
  if [[ ${#rows[@]} -eq 0 ]]; then
    ui_warn "Tidak ada akun."
    return 0
  fi
  ui_table "$hdr" "${rows[@]}"
}

acct_print_online() {
  local hdr rows=() svc name ip
  hdr=$'LAYANAN\tNAMA\tSTATUS\tIP\tEXPIRES'
  for svc in $SPVS_ALL_SERVICES; do
    [[ -f "$(db_file "$svc")" ]] || continue
    while IFS=$'\t' read -r name _ expires _ _ _ _; do
      [[ -z "$name" ]] && continue
      ip="$(acct_online_ip "$svc" "$name")"
      [[ -n "$ip" ]] || continue
      rows+=("$(printf '%s\t%s\t%s\t%s\t%s' "$svc" "$name" "$(ui_status_color online)" "$ip" "$expires")")
    done < <(db_list "$svc")
  done
  if [[ ${#rows[@]} -eq 0 ]]; then
    ui_warn "Tidak ada user yang online."
    return 0
  fi
  ui_table "$hdr" "${rows[@]}"
}

acct_total() {
  local n=0 svc
  for svc in $SPVS_ALL_SERVICES; do
    [[ -f "$(db_file "$svc")" ]] || continue
    n=$(( n + $(db_count "$svc") ))
  done
  echo "$n"
}
