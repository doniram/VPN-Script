#!/usr/bin/env bash
# lib/ui.sh - terminal UI helpers (banner, boxes, colored tables)

[[ -n "${__SVPS_UI_LOADED:-}" ]] && return 0
__SVPS_UI_LOADED=1

if [[ -z "${C_RESET+x}" ]]; then
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'
    C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'; C_CYAN=$'\033[1;36m'
    C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  else
    C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_BOLD=""; C_DIM=""
  fi
fi

ui_vislen() {
  local s
  s="$(printf '%s' "$1" | sed -E $'s/\x1b\\[[0-9;]*m//g')"
  printf '%s' "${#s}"
}

ui_banner() {
  clear 2>/dev/null || true
  printf '\n%s' "$C_CYAN"
  cat <<'B'
   ███████╗ ██████╗██████╗ ██╗██████╗ ████████╗██╗   ██╗██████╗ ███████╗
   ██╔════╝██╔════╝██╔══██╗██║██╔══██╗╚══██╔══╝██║   ██║██╔══██╗██╔════╝
   ███████╗██║     ██████╔╝██║██████╔╝   ██║   ██║   ██║██████╔╝█████╗
   ╚════██║██║     ██╔══██╗██║██╔═══╝    ██║   ╚██╗ ██╔╝██╔══██╗██╔══╝
   ███████║╚██████╗██║  ██║██║██║        ██║    ╚████╔╝ ██║  ██║███████╗
   ╚══════╝ ╚═════╝╚═╝  ╚═╝╚═╝╚═╝        ╚═╝     ╚═══╝  ╚═╝  ╚═╝╚══════╝
B
  printf '%s' "$C_RESET"
}

ui_rule() {
  local w="${1:-68}" ch="${2:-─}" s="" i
  for ((i=0;i<w;i++)); do s+="$ch"; done
  printf '%s%s%s\n' "$C_BLUE" "$s" "$C_RESET"
}

ui_title() { printf '%s%s%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"; }

ui_kv() {
  local label="$1" value="$2" w="${3:-14}"
  printf '   %s%-*s%s %s\n' "$C_DIM" "$w" "$label" "$C_RESET" "$value"
}

ui_box() {
  local title="$1"; shift
  local width=0 line vis i
  for line in "$@"; do vis="$(ui_vislen "$line")"; (( vis > width )) && width=$vis; done
  local tvis; tvis="$(ui_vislen "$title")"
  (( width < tvis + 2 )) && width=$((tvis + 2))
  local top="${C_BLUE}╭─ ${C_BOLD}${C_CYAN}${title}${C_RESET}${C_BLUE} "
  local used=$((tvis + 4))
  for ((i=used;i<width+2;i++)); do top+="─"; done
  printf '%s╮%s\n' "$top" "$C_RESET"
  for line in "$@"; do
    local pad=$((width - $(ui_vislen "$line")))
    printf '%s│%s %s%*s %s│%s\n' "$C_BLUE" "$C_RESET" "$line" "$pad" "" "$C_BLUE" "$C_RESET"
  done
  local bot="${C_BLUE}╰"
  for ((i=0;i<width+2;i++)); do bot+="─"; done
  printf '%s╯%s\n' "$bot" "$C_RESET"
}

ui_status_color() {
  case "$1" in
    online)  printf '%s● online%s' "$C_GREEN" "$C_RESET" ;;
    active)  printf '%s○ aktif%s' "$C_CYAN" "$C_RESET" ;;
    soon)    printf '%s⚠ segera%s' "$C_YELLOW" "$C_RESET" ;;
    expired) printf '%s✖ expired%s' "$C_RED" "$C_RESET" ;;
    *)       printf '%s%s%s' "$C_DIM" "$1" "$C_RESET" ;;
  esac
}

# ui_table <header (tab-separated)> [row (tab-separated)...]
ui_table() {
  local header="$1"; shift
  local -a H; IFS=$'\t' read -r -a H <<<"$header"
  local cols=${#H[@]}
  local -a W
  local c r k
  for ((c=0;c<cols;c++)); do W[c]=$(ui_vislen "${H[c]}"); done
  local -a allrows=("$@")
  for r in "${allrows[@]}"; do
    local -a cells; IFS=$'\t' read -r -a cells <<<"$r"
    for ((c=0;c<cols;c++)); do
      local l; l=$(ui_vislen "${cells[c]:-}")
      (( l > W[c] )) && W[c]=$l
    done
  done

  local top="${C_BLUE}┌" sep="${C_BLUE}├" bot="${C_BLUE}└"
  for ((c=0;c<cols;c++)); do
    local seg=""
    for ((k=0;k<W[c]+2;k++)); do seg+="─"; done
    top+="$seg"; sep+="$seg"; bot+="$seg"
    if (( c < cols-1 )); then top+="┬"; sep+="┼"; bot+="┴"; else top+="┐"; sep+="┤"; bot+="┘"; fi
  done
  printf '%s%s\n' "$top" "$C_RESET"

  printf '%s│%s' "$C_BLUE" "$C_RESET"
  for ((c=0;c<cols;c++)); do
    printf ' %s%s%s' "$C_BOLD" "${H[c]}" "$C_RESET"
    local hl; hl=$(ui_vislen "${H[c]}")
    printf '%*s' "$((W[c]-hl+1))" ""
    printf '%s│%s' "$C_BLUE" "$C_RESET"
  done
  printf '\n%s%s\n' "$sep" "$C_RESET"

  for r in "${allrows[@]}"; do
    local -a cells; IFS=$'\t' read -r -a cells <<<"$r"
    printf '%s│%s' "$C_BLUE" "$C_RESET"
    for ((c=0;c<cols;c++)); do
      local content="${cells[c]:-}" cl
      cl=$(ui_vislen "$content")
      printf ' %s' "$content"
      printf '%*s' "$((W[c]-cl+1))" ""
      printf '%s│%s' "$C_BLUE" "$C_RESET"
    done
    printf '\n'
  done
  printf '%s%s\n' "$bot" "$C_RESET"
}

ui_ok()   { printf '%s✔ %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
ui_warn() { printf '%s▲ %s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
ui_err()  { printf '%s✖ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; }

ui_spin() {
  local msg="$1"; shift; [[ "${1:-}" == "--" ]] && shift
  if [[ ! -t 1 ]]; then "$@"; return $?; fi
  local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0 rc
  ( "$@" ) & local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r%s%s%s %s' "$C_CYAN" "${frames:$((i % 10)):1}" "$C_RESET" "$msg"
    i=$((i+1)); sleep 0.1
  done
  wait "$pid"; rc=$?
  printf '\r\033[K'
  return $rc
}
