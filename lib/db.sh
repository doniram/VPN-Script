#!/usr/bin/env bash
# lib/db.sh - simple, dependency-free account store (TSV, one file per service)
#
# Columns: name  created  expires  iplimit  quota_gb  plan  meta
# meta is free-form (e.g. protocol/transport) and never parsed by the core.

[[ -n "${__SVPS_DB_LOADED:-}" ]] && return 0
__SVPS_DB_LOADED=1

DB_HEADER='#name	created	expires	iplimit	quota_gb	plan	meta'

db_file() { printf '%s/%s.db' "$SVPS_DB" "$1"; }

db_init() {
  init_dirs
  local f; f="$(db_file "$1")"
  if [[ ! -f "$f" ]]; then
    printf '%s\n' "$DB_HEADER" >"$f"
    chmod 600 "$f"
  fi
}

db_exists() {
  local f; f="$(db_file "$1")"
  [[ -f "$f" ]] || return 1
  awk -F'\t' -v n="$2" '!/^#/ && $1==n {found=1} END {exit !found}' "$f"
}

# db_add <service> <name> <expires> [iplimit] [quota_gb] [plan] [meta]
db_add() {
  local svc="$1" name="$2" expires="$3" iplimit="${4:-0}" quota="${5:-0}" plan="${6:-default}" meta="${7:-}"
  db_init "$svc"
  if db_exists "$svc" "$name"; then
    return 2
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$name" "$(date +%F)" "$expires" "$iplimit" "$quota" "$plan" "$meta" >>"$(db_file "$svc")"
}

# db_get <service> <name> -> raw line (tab separated)
db_get() {
  local f; f="$(db_file "$1")"
  [[ -f "$f" ]] || return 1
  awk -F'\t' -v n="$2" '!/^#/ && $1==n {print; exit}' "$f"
}

# db_field <service> <name> <column-number(1-based)>
db_field() {
  db_get "$1" "$2" | awk -F'\t' -v c="$3" '{print $c}'
}

# db_del <service> <name>
db_del() {
  local svc="$1" name="$2" f tmp
  f="$(db_file "$svc")"
  [[ -f "$f" ]] || return 1
  tmp="$(mktemp)"
  awk -F'\t' -v n="$name" 'BEGIN{OFS="\t"} /^#/ {print; next} $1!=n {print}' "$f" >"$tmp"
  mv "$tmp" "$f"
}

# db_update <service> <name> <expires>
db_update_expiry() {
  local svc="$1" name="$2" expires="$3" f tmp
  f="$(db_file "$svc")"
  [[ -f "$f" ]] || return 1
  tmp="$(mktemp)"
  awk -F'\t' -v n="$name" -v e="$expires" 'BEGIN{OFS="\t"} /^#/ {print; next} $1==n {$3=e; print; next} {print}' "$f" >"$tmp"
  mv "$tmp" "$f"
}

db_list() {
  local f; f="$(db_file "$1")"
  [[ -f "$f" ]] || return 0
  awk -F'\t' '!/^#/ && NF {print}' "$f"
}

db_count() {
  db_list "$1" | wc -l | tr -d ' '
}

# db_expired <service> -> names whose expiry already passed
db_expired() {
  local svc="$1" f; f="$(db_file "$svc")"
  [[ -f "$f" ]] || return 0
  awk -F'\t' -v now="$(date +%s)" '
    !/^#/ && NF && $3!="" {
      cmd = "date -d \"" $3 "\" +%s 2>/dev/null"
      cmd | getline t; close(cmd)
      if (t != "" && t+0 < now) print $1
    }' "$f"
}
