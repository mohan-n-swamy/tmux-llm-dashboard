#!/usr/bin/env bash
# usage-line.sh — unified multi-backend 7-day usage segment (dashboard row 4).
#
# Uses ccusage (github.com/ccusage/ccusage) — reads Claude Code JSONL logs and breaks
# usage down PER MODEL. Because GLM-via-CC and Codex-via-CC route THROUGH Claude Code,
# ccusage's per-model breakdown already contains glm-*, gpt-* (codex), and all claude-*
# models. One tool → Claude + GLM + DeepSeek + Codex-via-CC, by model.
#
# Buckets model names -> backend:
#   claude-*        -> claude
#   glm-*           -> glm
#   deepseek-*      -> deepseek
#   gpt-* / o[0-9]* -> codex     (codex-via-CC)
#   gemini-*        -> gemini    (if ever routed through CC)
# Usage from headless pipelines outside Claude Code can be added via an optional JSONL
# ledger (GEMINI_LOG env): one {"backend","ts","tokens_out"} object per line.
#
# Window: trailing 7 days. Output = OUTPUT tokens per backend (the comparable "spend"
# signal), plus a top-models line.
#
# Modes:
#   (no arg)  -> two colored lines (backends \n models)
#   --plain   -> two plain lines
#   --json    -> raw computed blob
#   --backends-only / --models-only -> single line
#   --refresh -> background cache + pre-rendered lines
#
# Cached 300s (5 min) — ccusage spawns node + parses logs; too heavy per repaint.
set -euo pipefail

STATE_DIR="${MMS_STATE_DIR:-$HOME/.local/state/tmux-llm-dashboard}"
CACHE="$STATE_DIR/.usage-line.cache"
RENDER="$STATE_DIR/.usage-line.render"
LOCK="$STATE_DIR/.usage-line.lock"
TTL=300
GEMINI_LOG="${GEMINI_LOG:-}"   # optional headless-usage JSONL ledger
mkdir -p "$STATE_DIR" 2>/dev/null || true

mode="color"
for a in "$@"; do
  case "$a" in
    --plain) mode="plain" ;;
    --json)  mode="json" ;;
    --backends-only) mode="backends" ;;
    --models-only)   mode="models" ;;
    --refresh) mode="refresh" ;;
  esac
done

# pass ccusage output into python via env (avoids arg-length limits)
_compute_wrapped() {
  local since cc_main
  since=$(date -v-7d +%Y%m%d 2>/dev/null || date -d '7 days ago' +%Y%m%d)
  # ONE ccusage call — `daily` already includes codex-via-CC as gpt-* models.
  cc_main=$(timeout 90 npx -y ccusage@latest daily --breakdown --json --since "$since" 2>/dev/null || echo '{}')
  CC_MAIN="$cc_main" CC_CODEX="{}" GEMINI_LOG="$GEMINI_LOG" python3 - "$since" <<'PY'
import sys, os, json, re
from datetime import datetime, timezone, timedelta
since = sys.argv[1]
main = json.loads(os.environ.get("CC_MAIN", "{}") or "{}")
codex = json.loads(os.environ.get("CC_CODEX", "{}") or "{}")
backends = {"claude": 0, "glm": 0, "deepseek": 0, "codex": 0, "gemini": 0}
models = {}
total_cost = 0.0
def bucket(name):
    n = (name or "").lower()
    if any(n.startswith(x) for x in ("claude","opus","sonnet","haiku","fable")): return "claude"
    if n.startswith("glm"): return "glm"
    if n.startswith("deepseek"): return "deepseek"
    if n.startswith("gpt") or re.match(r"^o[0-9]", n) or "codex" in n: return "codex"
    if n.startswith("gemini"): return "gemini"
    return None
# `ccusage daily` (Claude Code logs) ALREADY includes codex-via-CC sessions as gpt-*
# models — adding a separate `ccusage codex` call on top DOUBLE-COUNTS both tokens
# AND cost. So codex comes SOLELY from the main breakdown here.
for day in main.get("daily", []):
    total_cost += day.get("totalCost", 0) or 0
    for mb in day.get("modelBreakdowns", []) or []:
        out = mb.get("outputTokens", 0) or 0
        b = bucket(mb.get("modelName", ""))
        if b: backends[b] += out
        models[mb.get("modelName","")] = models.get(mb.get("modelName",""), 0) + out
# Optional headless ledger: pipelines that never write to the CC logs ccusage reads
# (e.g. gemini/deepseek batch jobs) can log {"backend","ts","tokens_out"} lines here.
glog = os.environ.get("GEMINI_LOG","")
if glog and os.path.exists(glog):
    cut = datetime.now(timezone.utc) - timedelta(days=7)
    for line in open(glog):
        line=line.strip()
        if not line: continue
        try: r=json.loads(line)
        except: continue
        be = r.get("backend")
        if be not in ("gemini","deepseek"): continue
        try:
            dt=datetime.fromisoformat(r.get("ts"))
            if dt.tzinfo is None: dt=dt.replace(tzinfo=timezone.utc)
        except: continue
        if dt>=cut:
            n=int(r.get("tokens_out") or 0)
            backends[be]+=n
            models[be+"-distill"]=models.get(be+"-distill",0)+n
top=sorted(models.items(), key=lambda kv:-kv[1])[:5]
print(json.dumps({"backends":backends,"top_models":top,"cost":round(total_cost,2)}))
PY
}

_cache_fresh() {
  [ -f "$CACHE" ] || return 1
  local m age
  m=$(stat -f "%m" "$CACHE" 2>/dev/null || stat -c "%Y" "$CACHE" 2>/dev/null || echo 0)
  age=$(( $(date +%s) - m ))
  [ "$age" -lt "$TTL" ]
}

EMPTY_BLOB='{"backends":{"claude":0,"glm":0,"deepseek":0,"codex":0,"gemini":0},"top_models":[],"cost":0}'

# refresh always recomputes (it IS the refresher); interactive modes prefer fresh cache
if [ "$mode" != "refresh" ] && _cache_fresh; then
  blob=$(cat "$CACHE")
else
  blob=$(_compute_wrapped 2>/dev/null || echo "$EMPTY_BLOB")
  # never persist an all-zero compute over a good cache
  nz=$(printf '%s' "$blob" | python3 -c 'import sys,json
try:
 d=json.load(sys.stdin); b=d.get("backends",{})
 print("1" if sum(int(v or 0) for v in b.values())>0 or d.get("cost") else "0")
except Exception: print("0")' 2>/dev/null || echo 0)
  [ "$nz" = "1" ] && printf '%s' "$blob" > "$CACHE" 2>/dev/null || true
fi

if [ "$mode" = "json" ]; then
  printf '%s\n' "$blob"; exit 0
fi

# ---- render ----
render() {
  local plain="$1"
  printf '%s' "$blob" | GEMINI_LOG="" python3 -c '
import sys, json
plain = "'"$plain"'" == "1"
d = json.load(sys.stdin)
b = d.get("backends", {})
tm = d.get("top_models", [])
cost = d.get("cost", 0)

def fmt(n):
    n = int(n or 0)
    if n >= 1_000_000: return f"{n/1_000_000:.1f}M"
    if n >= 1_000:     return f"{n/1_000:.1f}k"
    return str(n)

# ANSI (gruvbox-ish); blank if plain
def c(code): return "" if plain else code
GREY=c("\033[38;2;102;92;84m"); RS=c("\033[0m")
CLA=c("\033[38;2;215;153;33m")   # claude=gold
GLM=c("\033[38;2;104;157;106m")  # glm=green
DS =c("\033[38;2;69;133;136m")   # deepseek=blue
CDX=c("\033[38;2;177;98;134m")   # codex=purple
GEM=c("\033[38;2;214;93;14m")    # gemini=orange

SEP = f"{GREY} · {RS}"   # middot separator — clean, no Nerd Font needed
order = [("claude",CLA),("glm",GLM),("deepseek",DS),("codex",CDX),("gemini",GEM)]
segs=[]
for key,col in order:
    v=b.get(key,0)
    lbl={"deepseek":"ds"}.get(key,key)
    segs.append(f"{GREY}{lbl}:{RS}{col}{fmt(v)}{RS}")
costseg = f"{SEP}{CLA}${cost:.0f}{RS}" if cost else ""
line1=f"{GREY}7d>{RS} " + SEP.join(segs) + costseg

# models line (short names)
def short(m):
    return m.replace("claude-","").replace("-20251001","")
mseg=SEP.join(f"{GREY}{short(n)}:{RS}{fmt(v)}" for n,v in tm) if tm else f"{GREY}(no model data){RS}"
line2=f"{GREY}mdl>{RS} " + mseg
print(line1)
print(line2)
'
}

case "$mode" in
  refresh)
    # background job: blob already recomputed above. Persist cache + pre-rendered lines
    # ATOMICALLY via tmp+mv (mv on same fs is atomic → a racing reader never sees a
    # partial file; concurrent refreshers just last-wins, both valid). NOTE: no shell
    # `flock` — it does NOT exist on macOS (util-linux only). tmp+mv is the portable
    # atomicity primitive here.
    # Lockdir is normally created by the caller (dashboard) BEFORE spawning us, so the
    # expensive compute above never piles up. We just ensure it exists (for standalone
    # --refresh runs) and ALWAYS remove it on exit so the next refresh can proceed.
    # Stale-steal handled caller-side.
    LOCKDIR="$LOCK.d"
    mkdir "$LOCKDIR" 2>/dev/null || true
    trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT
    nz=$(printf '%s' "$blob" | python3 -c 'import sys,json
try:
 d=json.load(sys.stdin); b=d.get("backends",{})
 print("1" if sum(int(v or 0) for v in b.values())>0 or d.get("cost") else "0")
except Exception: print("0")' 2>/dev/null || echo 0)
    if [ "$nz" = "1" ]; then
      printf '%s' "$blob" > "$CACHE.tmp" && mv -f "$CACHE.tmp" "$CACHE"
      render 0 > "$RENDER.tmp" 2>/dev/null && mv -f "$RENDER.tmp" "$RENDER"
    fi
    ;;
  backends) render "$([ "$1" = "--plain" ] && echo 1 || echo 0)" 2>/dev/null | sed -n '1p' ;;
  models)   render 0 | sed -n '2p' ;;
  plain)    render 1 ;;
  *)        render 0 ;;
esac
