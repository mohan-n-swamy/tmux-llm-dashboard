# tmux-llm-dashboard

A nine-row, provider-neutral LLM usage dashboard that lives in a small tmux pane. One glance answers: *where am I, what's my git state, are my hosts up, how many tokens have I burned this week, and how close am I to each provider's rate limit?*

```
cwd: ~/projects/my-app
git: main *3
nas:UP · vps:UP
7d> claude:7.9M · glm:162.9k · ds:173.8k · codex:8.6M · gemini:41 · $5167
claude(pro): 5h:4%(upd 0m ago) · wk:18% (rst 6d)
codex(pro): 5h:2%(rst 6d23h) · wk:?
glm(pro): 5h:0% · wk:25%(rst 40h26m)
ds:$20.48
now: Wed 15-Jul 03:05 IST · Tue 14-Jul 21:35 UTC
```

Works in **any terminal that runs tmux** — no specific terminal app required.

## What each row shows

| Row | Content | Source |
|---|---|---|
| 1 | Working directory of the tracked pane | tmux `pane_current_path` |
| 2 | Git branch + dirty-file count | `git` in that directory |
| 3 | TCP reachability lights for hosts you name | `nc` probe, 10s cache |
| 4 | 7-day output tokens per backend + cost | [ccusage](https://github.com/ccusage/ccusage) over Claude Code logs |
| 5 | Claude subscription quota (5h + weekly %) | a cache file you write (see below) |
| 6 | Codex/ChatGPT plan quota (5h + weekly %) | local `~/.codex/sessions` JSONL — no API call |
| 7 | GLM (z.ai) Coding Plan quota (5h + weekly %) | z.ai quota endpoint |
| 8 | DeepSeek remaining credit balance | DeepSeek balance endpoint |
| 9 | Clock, local + UTC | `date` |

Every row **fails open**: missing key, missing cache, or a provider you don't use just renders as `name:?` in grey. Install it, configure only the providers you have.

## Design

- The dashboard is a **real tmux pane running its own repaint loop** (30s), not a tmux `status-right` — so it can be multi-line, colored, and independent of your status bar config.
- Expensive work (API calls, ccusage log parsing) runs in **background helpers cached for 5 minutes**, written atomically (`tmp` + `mv`). The repaint only reads small pre-rendered files, so it's effectively free.
- Concurrent panes coordinate through lock directories and a global retry backoff — twenty dashboard panes still make one API call per provider per 5 minutes.

## Requirements

- `zsh` (the dashboard), `bash` + `python3` (helpers) — all stock on macOS; standard on Linux
- `tmux`
- `curl`, `nc` (netcat) — for quota fetches and host probes
- `node`/`npx` — only for row 4 (ccusage); skip if you don't want usage totals

## Install

```sh
git clone https://github.com/mohan-n-swamy/tmux-llm-dashboard.git
cd tmux-llm-dashboard
./install.sh          # checks dependencies, makes scripts executable
```

The repo is self-contained — run it from wherever you cloned it. State/caches go to `~/.local/state/tmux-llm-dashboard/` (override with `MMS_STATE_DIR`).

### 1. Configure provider keys (only the ones you use)

```sh
mkdir -p ~/.config/secrets && chmod 700 ~/.config/secrets

# GLM (z.ai coding plan) — row 7
echo 'YOUR_ZAI_API_KEY' > ~/.config/secrets/glm-api-key

# DeepSeek — row 8
echo 'YOUR_DEEPSEEK_API_KEY' > ~/.config/secrets/deepseek-api-key

chmod 600 ~/.config/secrets/*
```

Different paths? Set `GLM_KEY_FILE` / `DEEPSEEK_KEY_FILE`.

Codex (row 6) and usage (row 4) need **no keys** — they read local Codex/Claude Code session logs.

### 2. Configure host probes (optional) — row 3

```sh
# space-separated label:host:port entries
export MMS_HOSTS="nas:192.168.1.10:22 vps:example.com:443"
```

Put it in your shell profile or in the tmux launch command below.

### 3. Claude quota (optional) — row 5

Anthropic has no public quota API. If you have a source for your 5h/weekly usage % (e.g. a Claude Code statusline hook), write it to:

```
~/.local/state/tmux-llm-dashboard/.anthropic-rate-limits.cache
```

One line, tab-separated: `epoch_seconds<TAB>five_hour_used_pct<TAB>weekly_used_pct`

```sh
printf '%s\t%s\t%s\n' "$(date +%s)" 4 18 > ~/.local/state/tmux-llm-dashboard/.anthropic-rate-limits.cache
```

Without it the row shows `claude(pro): quota:?`.

## Run it

One-shot render (sanity check):

```sh
./status.sh --all
```

Live dashboard pane under your current pane — add a binding to `~/.tmux.conf`:

```tmux
# prefix + D: open a 9-line dashboard below, tracking this pane's cwd.
# It closes itself when the tracked pane exits.
bind-key D split-window -v -l 9 "/path/to/tmux-llm-dashboard/status.sh --watch '#{pane_id}' '#{pane_current_path}'"
```

Or start every new session with a dashboard automatically:

```tmux
# in ~/.tmux.conf
set-hook -g after-new-session 'split-window -v -l 9 "/path/to/tmux-llm-dashboard/status.sh --watch \"#{pane_id}\" \"#{pane_current_path}\""; select-pane -t 0'
```

With `MMS_HOSTS`:

```tmux
bind-key D split-window -v -l 9 "MMS_HOSTS='vps:example.com:443' /path/to/tmux-llm-dashboard/status.sh --watch '#{pane_id}'"
```

### All modes

```
status.sh --all [cwd]           render all 9 rows once
status.sh --row N [cwd]         render one row (1-9) — usable in scripts/status bars
status.sh --refresh             kick background cache refreshes only
status.sh --watch <pane> [cwd]  live loop: repaint 30s, track <pane>, exit when it closes
```

### Environment variables

| Var | Default | Purpose |
|---|---|---|
| `MMS_STATE_DIR` | `~/.local/state/tmux-llm-dashboard` | cache/state directory |
| `MMS_HOSTS` | *(empty)* | `label:host:port` entries for row 3 |
| `MMS_TZ` | system local time | IANA timezone for the row-9 clock, e.g. `Asia/Kolkata`, `America/New_York` (UTC is always shown alongside) |
| `TMUX_BIN` | first `tmux` on PATH | tmux binary |
| `GLM_KEY_FILE` | `~/.config/secrets/glm-api-key` | GLM API key file |
| `DEEPSEEK_KEY_FILE` | `~/.config/secrets/deepseek-api-key` | DeepSeek API key file |
| `GEMINI_LOG` | *(empty)* | optional JSONL ledger for usage outside Claude Code logs |

## Troubleshooting

- **A row shows `name:?`** — that provider isn't configured (missing key file / no local logs). Expected fail-open state, not an error.
- **`(stale 20m)` tag on a row** — the helper hasn't refreshed in >15 min. Run the helper directly to see why, e.g. `bash helpers/glm-quota.sh --json`.
- **Row 4 empty forever** — needs `npx` and Claude Code JSONL logs (`~/.config/claude` / `~/.claude`); first ccusage run downloads the package, give it a minute.
- **Dashboard pane wrong height** — the watch loop re-asserts 9 lines each repaint; if you want a different height, edit `resize-pane -y 9` in `status.sh`.
- **zsh users writing orchestration around this**: don't name a variable `status` — it's a read-only zsh parameter and assignments to it silently no-op.

## Cache layout

Everything lives in `$MMS_STATE_DIR`:

```
.usage-line.cache/.render        row 4 (json blob / pre-rendered ANSI lines)
.anthropic-rate-limits.cache     row 5 (you write this)
.codex-quota.cache/.render       row 6
.glm-quota.cache/.render         row 7
.deepseek-balance.cache/.render  row 8
.hosts-probe.cache               row 3
*.lock.d / *.refresh-attempt     concurrency guards
```

Delete the directory any time — it rebuilds.

## License

MIT
