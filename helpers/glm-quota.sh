#!/usr/bin/env bash
# glm-quota.sh — GLM (z.ai) Coding Plan LIMIT usage: 5-hour + weekly quota % + reset.
# Uses the same source as the "Z.ai GLM Usage Tracker" VS Code extension and the
# opencode-glm-quota plugin: undocumented but stable endpoint
#   GET https://api.z.ai/api/monitor/usage/quota/limit
# Auth: Bearer <glm-api-key>. Applies to z.ai Coding Plans with 5h + weekly cycles.
#
# Response .data.limits[] entries we use:
#   TOKENS_LIMIT unit=3 (hour) number=5  -> the 5-HOUR token cycle  (.percentage, .nextResetTime ms)
#   TOKENS_LIMIT unit=6 (week) number=1  -> the WEEKLY token cycle
# (TIME_LIMIT unit=5 is the tool-call 5h window — ignored; not the token limit.)
#
# Key file: $GLM_KEY_FILE (default ~/.config/secrets/glm-api-key) — file containing
# the API key, nothing else. chmod 600 it.
#
# Modes:  (none)=colored segment   --plain=no ANSI   --json=raw computed   --refresh=bg render
# Cached 300s. Fail-open: prints 'glm:?' if key missing / API down.
set -euo pipefail

KEY_FILE="${GLM_KEY_FILE:-$HOME/.config/secrets/glm-api-key}"
STATE_DIR="${MMS_STATE_DIR:-$HOME/.local/state/tmux-llm-dashboard}"
CACHE="$STATE_DIR/.glm-quota.cache"
RENDER="$STATE_DIR/.glm-quota.render"
TTL=300
mkdir -p "$STATE_DIR" 2>/dev/null || true

mode="color"
for a in "$@"; do case "$a" in --plain) mode=plain;; --json) mode=json;; --refresh) mode=refresh;; esac; done

_fresh() {
  [ -f "$CACHE" ] || return 1
  local m; m=$(stat -f "%m" "$CACHE" 2>/dev/null || stat -c "%Y" "$CACHE" 2>/dev/null || echo 0)
  [ $(( $(date +%s) - m )) -lt "$TTL" ]
}

_fetch() {
  local key; key=$(cat "$KEY_FILE" 2>/dev/null || true)
  [ -z "$key" ] && { echo '{}'; return; }
  curl -s --max-time 12 "https://api.z.ai/api/monitor/usage/quota/limit" \
    -H "Authorization: Bearer $key" 2>/dev/null || echo '{}'
}

if _fresh; then
  raw=$(cat "$CACHE")
else
  raw=$(_fetch)
  # only cache a successful body (has "success":true) so transient failures don't stick
  echo "$raw" | grep -q '"success":true' && printf '%s' "$raw" > "$CACHE" 2>/dev/null || true
fi

# compute {h5_pct, h5_reset_ms, wk_pct, wk_reset_ms, level} from raw
blob=$(printf '%s' "$raw" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
data = (d or {}).get("data", {}) or {}
out = {"h5_pct": None, "h5_reset": None, "wk_pct": None, "wk_reset": None, "level": data.get("level","")}
for lim in data.get("limits", []) or []:
    if lim.get("type") != "TOKENS_LIMIT":
        continue
    unit = lim.get("unit")
    pct = lim.get("percentage")
    rst = lim.get("nextResetTime")
    # first match wins — guards against a future duplicate unit entry overwriting
    if unit == 3 and out["h5_pct"] is None:   # hour-based cycle == the 5h token window
        out["h5_pct"], out["h5_reset"] = pct, rst
    elif unit == 6 and out["wk_pct"] is None: # week
        out["wk_pct"], out["wk_reset"] = pct, rst
print(json.dumps(out))
')

if [ "$mode" = "json" ]; then printf '%s\n' "$blob"; exit 0; fi

_render_py='
import sys, os, json, time
d = json.load(sys.stdin)
plain = os.environ.get("mode") == "plain"
def c(x): return "" if plain else x
GREY=c("\033[38;2;102;92;84m"); RS=c("\033[0m")
GRN=c("\033[38;2;104;157;106m"); YEL=c("\033[38;2;215;153;33m"); RED=c("\033[38;2;204;36;29m")
AQUA=c("\033[38;2;104;157;106m")
def col(p):
    if p is None: return GREY
    return RED if p>=90 else (YEL if p>=70 else GRN)
def reset(ms):
    if not ms: return ""
    secs = ms/1000 - time.time()
    if secs <= 0: return "now"
    h=int(secs//3600); m=int((secs%3600)//60)
    return f"{h}h{m:02d}m" if h else f"{m}m"
def seg(label, pct, rst):
    if pct is None: return f"{GREY}{label}:?{RS}"
    r=reset(rst); rtxt=f"{GREY}(rst {r}){RS}" if r else ""
    return f"{GREY}{label}:{RS}{col(pct)}{pct}%{RS}{rtxt}"
h5=seg("5h", d.get("h5_pct"), d.get("h5_reset"))
wk=seg("wk", d.get("wk_pct"), d.get("wk_reset"))
lvl=d.get("level") or "?"
SEP=f"{GREY} · {RS}"
print(f"{AQUA}glm({lvl}):{RS} {h5}{SEP}{wk}")
'

# --refresh: background job — write the pre-rendered line atomically for the dashboard
# to read without executing anything. Only overwrite on a real fetch (blob has a pct).
if [ "$mode" = "refresh" ]; then
  # lockdir owned by caller (dashboard), named "${cache%.cache}.lock.d" — MUST match the
  # dashboard's spawn-guard path exactly, else the lock leaks. Always clean on exit.
  LOCKDIR="${CACHE%.cache}.lock.d"
  mkdir "$LOCKDIR" 2>/dev/null || true
  trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT
  has=$(printf '%s' "$blob" | python3 -c 'import sys,json
try: d=json.load(sys.stdin); print("1" if (d.get("h5_pct") is not None or d.get("wk_pct") is not None) else "0")
except Exception: print("0")' 2>/dev/null || echo 0)
  if [ "$has" = "1" ]; then
    printf '%s' "$blob" | mode="color" python3 -c "$_render_py" > "$RENDER.tmp" 2>/dev/null \
      && mv -f "$RENDER.tmp" "$RENDER"
  fi
  exit 0
fi

printf '%s' "$blob" | mode="$mode" python3 -c "$_render_py"
