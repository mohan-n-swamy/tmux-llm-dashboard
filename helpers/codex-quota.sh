#!/usr/bin/env bash
# codex-quota.sh — Codex (ChatGPT plan) LIMIT usage: 5-hour + weekly quota % + reset.
# Source: LOCAL ~/.codex/sessions/**/*.jsonl — the codex CLI writes a `rate_limits`
# snapshot into every token_count event:
#   payload.rate_limits.primary   {used_percent, window_minutes:300,   resets_at (epoch s)}  -> 5h window
#   payload.rate_limits.secondary {used_percent, window_minutes:10080, resets_at (epoch s)}  -> weekly
#   payload.rate_limits.plan_type ("plus", ...)
# No API call, no key. Snapshot is only as fresh as the last codex run — if a window's
# resets_at has passed with no codex use since, current usage is 0% (rendered so).
# A grey age tag (snap 2d) appears when the snapshot is >24h old.
#
# Modes:  (none)=colored segment   --plain=no ANSI   --json=raw computed   --refresh=bg cache
# Cached 300s. Fail-open: prints 'codex:?' if no snapshot found.
set -euo pipefail

STATE_DIR="${MMS_STATE_DIR:-$HOME/.local/state/tmux-llm-dashboard}"
CACHE="$STATE_DIR/.codex-quota.cache"
RENDER="$STATE_DIR/.codex-quota.render"
TTL=300
mkdir -p "$STATE_DIR" 2>/dev/null || true

mode="color"
for a in "$@"; do case "$a" in --plain) mode=plain;; --json) mode=json;; --refresh) mode=refresh;; esac; done

_fresh() {
  [ -f "$CACHE" ] || return 1
  local m; m=$(stat -f "%m" "$CACHE" 2>/dev/null || stat -c "%Y" "$CACHE" 2>/dev/null || echo 0)
  [ $(( $(date +%s) - m )) -lt "$TTL" ]
}

_compute() {
  python3 - <<'PYEOF'
import json, os, glob, time

root = os.path.expanduser("~/.codex/sessions")
out = {"h5_pct": None, "h5_reset": None, "wk_pct": None, "wk_reset": None,
       "plan": "", "snap_ts": None}

files = glob.glob(os.path.join(root, "*", "*", "*", "*.jsonl"))
files.sort(key=lambda p: os.path.getmtime(p), reverse=True)

for f in files[:15]:  # newest sessions first; stop at first snapshot
    last = None
    try:
        with open(f, errors="replace") as fh:
            for line in fh:
                if '"rate_limits"' in line:
                    last = line
    except OSError:
        continue
    if not last:
        continue
    try:
        ev = json.loads(last)
        rl = (ev.get("payload") or {}).get("rate_limits") or {}
        pri, sec = rl.get("primary") or {}, rl.get("secondary") or {}
        out["h5_pct"], out["h5_reset"] = pri.get("used_percent"), pri.get("resets_at")
        out["wk_pct"], out["wk_reset"] = sec.get("used_percent"), sec.get("resets_at")
        out["plan"] = rl.get("plan_type") or ""
        ts = ev.get("timestamp")
        if ts:
            try:
                out["snap_ts"] = time.mktime(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S")) - time.timezone
            except Exception:
                pass
        break
    except Exception:
        continue

# window rolled since snapshot + no codex use since -> current usage is 0%
now = time.time()
for pk, rk in (("h5_pct", "h5_reset"), ("wk_pct", "wk_reset")):
    if out[rk] and out[rk] <= now:
        out[pk], out[rk] = 0, None

print(json.dumps(out))
PYEOF
}

if _fresh; then
  blob=$(cat "$CACHE")
else
  blob=$(_compute)
  # only cache a body that actually found a snapshot
  echo "$blob" | grep -q '"h5_pct": *[0-9]' && printf '%s' "$blob" > "$CACHE" 2>/dev/null || true
fi

if [ "$mode" = "json" ]; then printf '%s\n' "$blob"; exit 0; fi

_render_py='
import sys, os, json, time
d = json.load(sys.stdin)
plain = os.environ.get("mode") == "plain"
def c(x): return "" if plain else x
GREY=c("\033[38;2;102;92;84m"); RS=c("\033[0m")
GRN=c("\033[38;2;104;157;106m"); YEL=c("\033[38;2;215;153;33m"); RED=c("\033[38;2;204;36;29m")
PURPLE=c("\033[38;2;177;98;134m")
def col(p):
    if p is None: return GREY
    return RED if p>=90 else (YEL if p>=70 else GRN)
def fmt(secs):
    if secs <= 0: return "now"
    dY=int(secs//86400); h=int((secs%86400)//3600); m=int((secs%3600)//60)
    if dY: return f"{dY}d{h}h"
    return f"{h}h{m:02d}m" if h else f"{m}m"
def seg(label, pct, rst):
    if pct is None: return f"{GREY}{label}:?{RS}"
    p=round(pct)
    r=fmt(rst - time.time()) if rst else ""
    rtxt=f"{GREY}(rst {r}){RS}" if r else ""
    return f"{GREY}{label}:{RS}{col(p)}{p}%{RS}{rtxt}"
h5=seg("5h", d.get("h5_pct"), d.get("h5_reset"))
wk=seg("wk", d.get("wk_pct"), d.get("wk_reset"))
plan=d.get("plan") or "?"
age=""
st=d.get("snap_ts")
if st and time.time()-st > 86400:
    age=f" {GREY}(snap {int((time.time()-st)//86400)}d){RS}"
SEP=f"{GREY} · {RS}"
print(f"{PURPLE}codex({plan}):{RS} {h5}{SEP}{wk}{age}")
'

# --refresh: background job — write the pre-rendered line atomically for the dashboard
# to read without executing anything. Lockdir path MUST match the dashboard spawn-guard.
if [ "$mode" = "refresh" ]; then
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
