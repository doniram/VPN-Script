#!/usr/bin/env bash
# lib/quota.sh - per-account traffic accounting & enforcement
#
# Accounting uses iptables chains with comment tags "svps:<svc>:<name>:<dir>".
# Counters are read from `iptables-save -c` and accumulated in
# /etc/scriptvps/usage/<svc>.<name> across restarts.

[[ -n "${__SVPS_QUOTA_LOADED:-}" ]] && return 0
__SVPS_QUOTA_LOADED=1

# shellcheck source=/dev/null
. "$SVPS_DIR/lib/ppp.sh"

QUOTA_DIR="$SVPS_ETC/usage"
Q_OUT="SVPS_Q_OUT"
Q_IN="SVPS_Q_IN"

quota_available() { has_cmd iptables; }

quota_ensure() {
  quota_available || return 1
  iptables -w -N "$Q_OUT" 2>/dev/null || true
  iptables -w -N "$Q_IN" 2>/dev/null || true
  iptables -w -C OUTPUT -j "$Q_OUT" 2>/dev/null || iptables -w -I OUTPUT -j "$Q_OUT" 2>/dev/null || true
  iptables -w -C INPUT -j "$Q_IN" 2>/dev/null || iptables -w -I INPUT -j "$Q_IN" 2>/dev/null || true
}

# quota_register <service> <name> <key>   (key = uid for ssh, port for ss)
quota_register() {
  local svc="$1" name="$2" key="$3"
  quota_available || return 0
  quota_ensure || return 0
  quota_unregister "$svc" "$name"
  case "$svc" in
    ssh)
      iptables -w -A "$Q_OUT" -m owner --uid-owner "$key" \
        -m comment --comment "svps:${svc}:${name}:out" -j RETURN 2>/dev/null || true ;;
    ss)
      local proto
      for proto in tcp udp; do
        iptables -w -A "$Q_OUT" -p "$proto" --sport "$key" \
          -m comment --comment "svps:${svc}:${name}:tx" -j RETURN 2>/dev/null || true
        iptables -w -A "$Q_IN" -p "$proto" --dport "$key" \
          -m comment --comment "svps:${svc}:${name}:rx" -j RETURN 2>/dev/null || true
      done ;;
  esac
}

# quota_unregister <service> <name>
quota_unregister() {
  local svc="$1" name="$2"
  local tag="svps:${svc}:${name}:" chain nums n
  quota_available || return 0
  for chain in "$Q_OUT" "$Q_IN"; do
    nums="$(iptables -w -L "$chain" --line-numbers -n 2>/dev/null | awk -v t="$tag" 'index($0,t){print $1}' | sort -rn)"
    for n in $nums; do
      iptables -w -D "$chain" "$n" 2>/dev/null || true
    done
  done
}

# quota_usage <service> <name> -> bytes
quota_usage() {
  local svc="$1" name="$2"
  local tag="svps:${svc}:${name}:"
  quota_available || { echo 0; return 0; }
  iptables-save -c 2>/dev/null | awk -v tag="$tag" '
    index($0, tag) {
      # lines start with "[pkts:bytes]"
      if (match($0, /^\[[0-9]+:[0-9]+\]/)) {
        s = substr($0, RSTART+1, RLENGTH-2)
        split(s, p, ":")
        bytes += p[2]
      }
    }
    END { print bytes+0 }'
}

# quota_sample - update cumulative usage for accounts that have a quota
quota_sample() {
  quota_available || return 0
  init_dirs; mkdir -p "$QUOTA_DIR"
  local svc name quota cur last cum f delta
  for svc in $SPVS_ALL_SERVICES; do
    [[ -f "$(db_file "$svc")" ]] || continue
    while IFS=$'\t' read -r name _ _ _ quota _ _; do
      [[ "${quota:-0}" =~ ^[0-9]+$ ]] || continue
      (( quota > 0 )) || continue
      cur="$(quota_usage "$svc" "$name")"
      f="$QUOTA_DIR/${svc}.${name}"
      last=0; cum=0
      if [[ -f "$f" ]]; then
        last="$(awk -F= '$1=="last"{print $2}' "$f")"
        cum="$(awk -F= '$1=="cum"{print $2}' "$f")"
      fi
      [[ -n "$last" ]] || last=0
      [[ -n "$cum" ]] || cum=0
      delta=$(( cur - last )); (( delta < 0 )) && delta=$cur
      cum=$(( cum + delta ))
      printf 'last=%s\ncum=%s\n' "$cur" "$cum" >"$f"
    done < <(db_list "$svc")
  done
}

# quota_enforce - disable accounts that exceeded their quota
quota_enforce() {
  quota_available || return 0
  local svc name quota f cum
  for svc in $SPVS_ALL_SERVICES; do
    [[ -f "$(db_file "$svc")" ]] || continue
    while IFS=$'\t' read -r name _ _ _ quota _ _; do
      [[ "${quota:-0}" =~ ^[0-9]+$ ]] || continue
      (( quota > 0 )) || continue
      f="$QUOTA_DIR/${svc}.${name}"
      [[ -f "$f" ]] || continue
      cum="$(awk -F= '$1=="cum"{print $2}' "$f")"
      [[ -n "$cum" ]] || cum=0
      if (( cum >= quota * 1024 * 1024 * 1024 )); then
        warn "Kuota $svc '$name' terlampaui (${cum} byte >= ${quota}GB) - dinonaktifkan."
        _quota_disable "$svc" "$name"
      fi
    done < <(db_list "$svc")
  done
}

_quota_disable() {
  local svc="$1" name="$2"
  case "$svc" in
    ssh) usermod -L "$name" 2>/dev/null || true ;;
    ss)
      local port tmp
      port="$(printf '%s' "$(db_field ss "$name" 7)" | tr ';' '\n' | awk -F= '$1=="port"{print $2}')"
      if [[ -n "$port" && -f /etc/shadowsocks-libev/server.json ]]; then
        tmp="$(mktemp)"
        jq --arg p "$port" 'del(.port_password[$p])' /etc/shadowsocks-libev/server.json >"$tmp" && \
          mv "$tmp" /etc/shadowsocks-libev/server.json
        systemctl restart shadowsocks-libev-server@server 2>/dev/null || true
      fi ;;
    sstp|l2tp|pptp) ppp_user_del "$name" || true ;;
  esac
  quota_unregister "$svc" "$name"
}

quota_report() {
  local svc name quota f cum
  printf '%-8s %-18s %12s %10s\n' SERVICE NAME USED_GB QUOTA_GB
  for svc in $SPVS_ALL_SERVICES; do
    [[ -f "$(db_file "$svc")" ]] || continue
    while IFS=$'\t' read -r name _ _ _ quota _ _; do
      (( quota > 0 )) 2>/dev/null || continue
      f="$QUOTA_DIR/${svc}.${name}"
      cum=0; [[ -f "$f" ]] && cum="$(awk -F= '$1=="cum"{print $2}' "$f")"
      awk -v s="$svc" -v n="$name" -v c="${cum:-0}" -v q="$quota" \
        'BEGIN{printf "%-8s %-18s %12.3f %10s\n", s, n, c/1073741824, q}'
    done < <(db_list "$svc")
  done
}
