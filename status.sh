#!/bin/zsh

# tmux-llm-dashboard — nine-row, provider-neutral LLM usage dashboard for a tmux pane.
# Renders cwd / git / host probes / 7-day usage / Claude / Codex / GLM / DeepSeek quota
# rows from small render caches; refreshes stale caches in the background.
#
# Modes:
#   --all [cwd]            one-shot render of all rows
#   --row N [cwd]          render a single row (1-9)
#   --refresh              refresh caches only
#   --watch <pane> [cwd]   live dashboard: repaint every 30s, track <pane>'s cwd,
#                          exit when <pane> closes
#
# Environment:
#   MMS_STATE_DIR   cache/state dir      (default: ~/.local/state/tmux-llm-dashboard)
#   MMS_HOSTS       hosts to TCP-probe   (space-separated "label:host:port" entries)
#   TMUX_BIN        tmux binary          (default: first tmux on PATH)

emulate -LR zsh
setopt pipe_fail

readonly SCRIPT_DIR="${0:A:h}"
readonly HELPER_DIR="$SCRIPT_DIR/helpers"
export MMS_STATE_DIR="${MMS_STATE_DIR:-$HOME/.local/state/tmux-llm-dashboard}"
readonly STATE_DIR="$MMS_STATE_DIR"
readonly TMUX_BIN="${TMUX_BIN:-$(command -v tmux)}"
readonly REFRESH_AFTER=300
readonly STALE_AFTER=900
readonly LOCK_STALE_AFTER=120

/bin/mkdir -p "$STATE_DIR" 2>/dev/null

readonly GREY=$'\e[38;2;102;92;84m'
readonly ORANGE=$'\e[38;2;215;153;33m'
readonly YELLOW=$'\e[38;2;250;189;47m'
readonly GREEN=$'\e[38;2;104;157;106m'
readonly WHITE=$'\e[38;2;235;219;178m'
readonly AQUA=$'\e[38;2;104;157;106m'
readonly RED=$'\e[38;2;204;36;29m'
readonly RESET=$'\e[0m'

file_mtime() {
  local file="$1"
  stat -f '%m' "$file" 2>/dev/null \
    || stat -c '%Y' "$file" 2>/dev/null \
    || print -r -- 0
}

spawn_refresh_if_stale() {
  local cache="$1"
  local helper="$2"
  local now mtime lock lock_mtime attempt attempt_mtime

  [[ -f "$helper" ]] || return 0
  now=$(date +%s)
  mtime=0
  [[ -f "$cache" ]] && mtime=$(file_mtime "$cache")
  (( now - mtime >= REFRESH_AFTER )) || return 0

  # Failed helpers leave the successful cache stale. Back off attempts globally so
  # multiple dashboard panes cannot retry a slow/network helper on every repaint.
  attempt="${cache%.cache}.refresh-attempt"
  attempt_mtime=0
  [[ -f "$attempt" ]] && attempt_mtime=$(file_mtime "$attempt")
  (( now - attempt_mtime >= REFRESH_AFTER )) || return 0

  lock="${cache%.cache}.lock.d"
  if [[ -d "$lock" ]]; then
    lock_mtime=$(file_mtime "$lock")
    (( now - lock_mtime > LOCK_STALE_AFTER )) && rmdir "$lock" 2>/dev/null
  fi

  if [[ ! -d "$lock" ]] && mkdir "$lock" 2>/dev/null; then
    touch "$attempt" 2>/dev/null
    nohup /bin/bash "$helper" --refresh >/dev/null 2>&1 &!
  fi
}

refresh_caches() {
  spawn_refresh_if_stale "$STATE_DIR/.usage-line.cache" "$HELPER_DIR/usage-line.sh"
  spawn_refresh_if_stale "$STATE_DIR/.glm-quota.cache" "$HELPER_DIR/glm-quota.sh"
  spawn_refresh_if_stale "$STATE_DIR/.codex-quota.cache" "$HELPER_DIR/codex-quota.sh"
  spawn_refresh_if_stale "$STATE_DIR/.deepseek-balance.cache" "$HELPER_DIR/deepseek-balance.sh"
}

cached_row() {
  local file="$1"
  local line="$2"
  local fallback="$3"
  local value now mtime age

  if [[ -s "$file" ]]; then
    value=$(sed -n "${line}p" "$file" 2>/dev/null | tr -d '\r')
  fi
  [[ -n "${value:-}" ]] || value="${GREY}${fallback}:?${RESET}"

  if [[ -f "$file" ]]; then
    now=$(date +%s)
    mtime=$(file_mtime "$file")
    age=$(( now - mtime ))
    if (( age >= STALE_AFTER )); then
      value+=" ${YELLOW}(stale $(( age / 60 ))m)${RESET}"
    fi
  fi

  print -rn -- "$value"
}

# Claude subscription quota. Reads $STATE_DIR/.anthropic-rate-limits.cache — a single
# line of "epoch_seconds<TAB>five_hour_used_pct<TAB>week_used_pct". Anthropic exposes
# no public quota API; write this file from whatever source you have (e.g. a Claude
# Code statusline hook). Row fails open to "claude(pro): quota:?" when absent.
anthropic_quota_row() {
  local file="$STATE_DIR/.anthropic-rate-limits.cache"
  local line rest captured five_used week_used now age five_left week_left stale=""

  [[ -s "$file" ]] || { print -rn -- "${GREY}claude(pro): quota:?${RESET}"; return 0; }
  line=$(sed -n '1p' "$file" 2>/dev/null)
  captured="${line%%$'\t'*}"
  rest="${line#*$'\t'}"
  five_used="${rest%%$'\t'*}"
  week_used="${rest#*$'\t'}"
  [[ "$captured" == <-> ]] || { print -rn -- "${GREY}claude(pro): quota:?${RESET}"; return 0; }

  now=$(date +%s)
  age=$(( now - captured ))
  if (( age < 0 )); then
    stale=" ${YELLOW}(clock?)${RESET}"
  elif (( age >= STALE_AFTER )); then
    stale=" ${YELLOW}(stale $(( age / 60 ))m)${RESET}"
  fi

  # Provider-consistent: show % USED (matches glm/codex rows). Reset window isn't in
  # the cache (used% only) — the weekly reset is estimated as Monday 00:00 UTC.
  print -rn -- "${GREY}claude(pro):${RESET} "
  if [[ "$five_used" == <-> || "$five_used" == <->.<-> ]]; then
    five_fmt=$(awk -v u="$five_used" 'BEGIN { printf "%.0f",u }')
    print -rn -- "${GREY}5h:${RESET}${ORANGE}${five_fmt}%${RESET}${GREY}(upd $(( age / 60 ))m ago)${RESET}"
  else
    print -rn -- "${GREY}5h:?${RESET}"
  fi
  print -rn -- " ${GREY}·${RESET}"
  if [[ "$week_used" == <-> || "$week_used" == <->.<-> ]]; then
    week_fmt=$(awk -v u="$week_used" 'BEGIN { printf "%.0f",u }')
    print -rn -- " ${GREY}wk:${RESET}${ORANGE}${week_fmt}%${RESET}"
  else
    print -rn -- " ${GREY}wk:?${RESET}"
  fi
  print -rn -- "${stale} ${GREY}(rst ${RESET}${ORANGE}$(weekly_reset_str)${RESET}${GREY})${RESET}"
}

# Days/hours until Monday 00:00 UTC — the weekly-quota reset estimate.
weekly_reset_str() {
  local dow days
  dow=$(date -u +%u)  # 1=Mon .. 7=Sun
  days=$(( (8 - dow) % 7 ))
  if (( days == 0 )); then
    print -rn -- "$(date -u +%H:%M)UTC today"
  elif (( days == 1 )); then
    print -rn -- "tmrw"
  else
    print -rn -- "${days}d"
  fi
}

# Current time, local + UTC, last dashboard row.
time_row() {
  local loc utc
  loc=$(date +'%a %d-%b %H:%M %Z')
  utc=$(date -u +'%a %d-%b %H:%M UTC')
  print -rn -- "${GREY}now:${RESET} ${WHITE}${loc}${RESET} ${GREY}·${RESET} ${WHITE}${utc}${RESET}"
}

cwd_row() {
  local cwd="${1:-$PWD}"
  local shown="${cwd/#$HOME/~}"
  print -rn -- "${GREY}cwd:${RESET} ${ORANGE}${shown}${RESET}"
}

# Host reachability lights. MMS_HOSTS is a space-separated list of "label:host:port"
# entries, e.g.  MMS_HOSTS="nas:192.168.1.10:22 vps:example.com:443".
# Probed via TCP connect with a 10s result cache so a repaint doesn't re-dial every tick.
hosts_row() {
  [[ -n "${MMS_HOSTS:-}" ]] || { print -rn -- "${GREY}hosts: none (set MMS_HOSTS)${RESET}"; return 0; }

  local cache="$STATE_DIR/.hosts-probe.cache"
  local now mtime age results entry label host port state parts sep=""
  now=$(date +%s)
  mtime=0; [[ -f "$cache" ]] && mtime=$(file_mtime "$cache")
  age=$(( now - mtime ))
  if (( age >= 10 )) || [[ ! -s "$cache" ]]; then
    results=""
    for entry in ${(s: :)MMS_HOSTS}; do
      parts=(${(s.:.)entry})
      (( ${#parts} == 3 )) || continue
      label="${parts[1]}"; host="${parts[2]}"; port="${parts[3]}"
      if nc -z -w 1 "$host" "$port" >/dev/null 2>&1; then state=UP; else state=DOWN; fi
      results+="${label}"$'\t'"${state}"$'\n'
    done
    print -rn -- "$results" > "$cache" 2>/dev/null
  fi

  while IFS=$'\t' read -r label state; do
    [[ -n "$label" ]] || continue
    local col="$AQUA"; [[ "$state" == UP ]] || col="$RED"
    print -rn -- "${sep}${col}${label}:${state}${RESET}"
    sep=" ${GREY}·${RESET} "
  done < "$cache"
}

git_row() {
  local cwd="${1:-$PWD}"
  local branch="n/a"
  local dirty=0

  if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
    branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
    [[ -n "$branch" ]] || branch=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
    dirty=$(git -C "$cwd" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  fi

  print -rn -- "${GREY}git:${RESET} ${GREEN}${branch:-n/a}${RESET}"
  (( dirty > 0 )) && print -rn -- " ${YELLOW}*${dirty}${RESET}"
}

render_row() {
  local row="$1"
  local cwd="${2:-$PWD}"

  case "$row" in
    1) cwd_row "$cwd" ;;
    2) git_row "$cwd" ;;
    3) hosts_row ;;
    4) cached_row "$STATE_DIR/.usage-line.render" 1 '7d' ;;
    5) anthropic_quota_row ;;
    6) cached_row "$STATE_DIR/.codex-quota.render" 1 'codex' ;;
    7) cached_row "$STATE_DIR/.glm-quota.render" 1 'glm' ;;
    8) cached_row "$STATE_DIR/.deepseek-balance.render" 1 'ds' ;;
    9) time_row ;;
    *) print -u2 -r -- "invalid row: $row"; return 2 ;;
  esac
}

render_all() {
  local cwd="${1:-$PWD}"
  local row
  for row in {1..9}; do
    render_row "$row" "$cwd"
    (( row < 9 )) && print
  done
}

restore_terminal() {
  print -n -- $'\e[?25h\e[?7h\e[0m'
}

watch_pane() {
  local target_pane="$1"
  local fallback_cwd="${2:-$PWD}"
  local cwd live_pane

  trap restore_terminal EXIT HUP INT TERM
  print -n -- $'\e[?25l\e[?7l'

  while true; do
    # tmux may return success plus empty output for a missing `%pane` target.
    # Match the resolved ID, not only the process exit code, so the dashboard
    # pane closes when its target pane exits.
    live_pane=$("$TMUX_BIN" display-message -p -t "$target_pane" '#{pane_id}' 2>/dev/null)
    [[ "$live_pane" == "$target_pane" ]] || break

    # tmux proportionally resizes panes with the window; reclaim the dashboard's
    # nine content rows on every repaint.
    [[ -n "${TMUX_PANE:-}" ]] && "$TMUX_BIN" resize-pane -t "$TMUX_PANE" -y 9 >/dev/null 2>&1
    refresh_caches
    cwd=$("$TMUX_BIN" display-message -p -t "$target_pane" '#{pane_current_path}' 2>/dev/null)
    [[ -n "$cwd" ]] || cwd="$fallback_cwd"
    print -n -- $'\e[H\e[2J'
    render_all "$cwd"
    sleep 30
  done
}

case "${1:---all}" in
  --all)
    refresh_caches
    render_all "${2:-$PWD}"
    print
    ;;
  --row)
    render_row "${2:-}" "${3:-$PWD}"
    ;;
  --refresh)
    refresh_caches
    ;;
  --watch)
    [[ -n "${2:-}" ]] || { print -u2 -- 'usage: status.sh --watch <pane-id> [fallback-cwd]'; exit 2; }
    watch_pane "$2" "${3:-$PWD}"
    ;;
  *)
    print -u2 -- 'usage: status.sh [--all [cwd] | --row N [cwd] | --refresh | --watch pane [cwd]]'
    exit 2
    ;;
esac
