#!/usr/bin/env bash
# deepseek-balance.sh — DeepSeek remaining credit balance ($USD) for the limits rows.
# DeepSeek is pay-as-you-go (no 5h/wk reset window like GLM/Codex) — the meaningful
# "limit" signal is how much credit is left.
#   GET https://api.deepseek.com/user/balance   Auth: Bearer <deepseek-api-key>
#   -> .balance_infos[0].total_balance  (string USD)
#
# Key file: $DEEPSEEK_KEY_FILE (default ~/.config/secrets/deepseek-api-key) — file
# containing the API key, nothing else. chmod 600 it.
#
# Modes:  (none)=colored segment   --plain=no ANSI   --json=raw computed   --refresh=bg render
# Cached 300s. Fail-open: prints 'ds:?' if key missing / API down.
set -euo pipefail

KEY_FILE="${DEEPSEEK_KEY_FILE:-$HOME/.config/secrets/deepseek-api-key}"
STATE_DIR="${MMS_STATE_DIR:-$HOME/.local/state/tmux-llm-dashboard}"
CACHE="$STATE_DIR/.deepseek-balance.cache"
RENDER="$STATE_DIR/.deepseek-balance.render"
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
  curl -s --max-time 12 "https://api.deepseek.com/user/balance" \
    -H "Authorization: Bearer $key" 2>/dev/null || echo '{}'
}

if _fresh; then
  raw=$(cat "$CACHE")
else
  raw=$(_fetch)
  # only cache a body that actually parsed a balance so transient failures don't stick
  echo "$raw" | grep -q '"total_balance"' && printf '%s' "$raw" > "$CACHE" 2>/dev/null || true
fi

# compute {balance, currency, available} from raw
blob=$(printf '%s' "$raw" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
out = {"balance": None, "currency": "USD", "available": (d or {}).get("is_available")}
infos = (d or {}).get("balance_infos") or []
if infos:
    b = infos[0]
    try:
        out["balance"] = float(b.get("total_balance"))
    except (TypeError, ValueError):
        out["balance"] = None
    out["currency"] = b.get("currency", "USD")
print(json.dumps(out))
')

if [ "$mode" = "json" ]; then printf '%s\n' "$blob"; exit 0; fi

_render_py='
import sys, os, json
d = json.load(sys.stdin)
plain = os.environ.get("mode") == "plain"
def c(x): return "" if plain else x
GREY=c("\033[38;2;102;92;84m"); RS=c("\033[0m")
GRN=c("\033[38;2;104;157;106m"); YEL=c("\033[38;2;215;153;33m"); RED=c("\033[38;2;204;36;29m")
BLU=c("\033[38;2;69;133;136m")   # deepseek brand blue (matches 7d ds: color)
bal = d.get("balance")
if bal is None:
    print(f"{GREY}ds:?{RS}"); sys.exit(0)
# low-credit warning: <$5 red, <$15 yellow, else blue
col = RED if bal < 5 else (YEL if bal < 15 else BLU)
cur = "$" if d.get("currency","USD")=="USD" else ""
print(f"{BLU}ds:{RS}{col}{cur}{bal:.2f}{RS}")
'

# --refresh: background — write pre-rendered line atomically. Only overwrite on a real balance.
if [ "$mode" = "refresh" ]; then
  LOCKDIR="${CACHE%.cache}.lock.d"
  mkdir "$LOCKDIR" 2>/dev/null || true
  trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT
  has=$(printf '%s' "$blob" | python3 -c 'import sys,json
try: d=json.load(sys.stdin); print("1" if d.get("balance") is not None else "0")
except Exception: print("0")' 2>/dev/null || echo 0)
  if [ "$has" = "1" ]; then
    printf '%s' "$blob" | mode="color" python3 -c "$_render_py" > "$RENDER.tmp" 2>/dev/null \
      && mv -f "$RENDER.tmp" "$RENDER"
  fi
  exit 0
fi

printf '%s' "$blob" | mode="$mode" python3 -c "$_render_py"
