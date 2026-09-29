#!/bin/zsh
# Station's perf budget. Builds Release, runs STATION_SELFTEST=perf against your real
# transcripts and repos (read-only; config and Claude settings go to a scratch copy), and fails
# if anything is over budget. release.sh runs this first: we never ship slower.
#   scripts/perf.sh            build + measure
#   scripts/perf.sh --no-build measure the last build
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/rel/Build/Products/Release/Station.app
if [[ "${1:-}" != "--no-build" ]]; then
  if ! OUT=$(xcodebuild -scheme Station -configuration Release -derivedDataPath build/rel build -quiet \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" 2>&1); then
    print -r -- "$OUT" | grep -E " error:" ; echo "perf: build failed"; exit 1
  fi
  scripts/sign-adhoc.sh "$APP" >/dev/null 2>&1
fi
# Warm-up: the first launch after a build pays for reading the binary off disk, which users only
# pay once per update. Measure what they feel every day.
"$APP/Contents/MacOS/Station" help >/dev/null 2>&1 || true
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/config"
[[ -f ~/.config/station/settings.json ]] && cp ~/.config/station/settings.json "$SCRATCH/config/"
cp ~/.claude/settings.json "$SCRATCH/claude-settings.json" 2>/dev/null || echo '{}' > "$SCRATCH/claude-settings.json"

# Budgets, in ms unless named otherwise. Set at "feels instant" with room for a busy machine
# (your other agents are running while this measures): a gate that flakes gets skipped.
# perf/history.tsv catches slow drift under budget. Never loosen one to make a release pass.
# launch_to_window, launch_to_review and main_stall_max are new (1.2.0) and sit at today's
# numbers: a ratchet. The review now loads off the main thread (1.3.0); the longest stall left is
# building the window (~300ms) and laying out the diff's files (~250ms). Tighten as those shrink.
typeset -A BUDGET=(
  launch_to_start_ms     400
  launch_to_window_ms    800
  launch_to_review_ms   1500
  main_stall_max_ms      700
  first_window_ms        200
  tab_agents_first_ms    300
  tab_prs_first_ms       150
  tab_review_first_ms     60
  tab_agents_ms           80
  tab_prs_ms              80
  tab_review_ms           80
  session_scan_ms       1500
  session_rescan_ms       50
  token_count_warm_ms     25
  idle_cpu_pct           1.0
  memory_mb              400   # swings 140-320 run to run (GitHub refresh timing): 300 flaked
)

# Two runs, each metric's best: noise (a hot machine, your other agents, a cold disk cache) only
# ever adds time, so the minimum is the real cost.
run_once() {
  STATION_SELFTEST=perf STATION_PERF_IDLE=${STATION_PERF_IDLE:-30} STATION_SELFTEST_REPO="$PWD" STATION_DETACHED=1 \
    STATION_CONFIG_DIR="$SCRATCH/config" STATION_CACHE_DIR="$SCRATCH/cache$1" STATION_CLAUDE_SETTINGS="$SCRATCH/claude-settings.json" \
    timeout 300 "$APP/Contents/MacOS/Station" 2>&1 | grep -m1 '^\[perf\]' | sed 's/^\[perf\] //'
}
A=$(run_once 1); B=$(run_once 2)
LINE=$(A="$A" B="$B" /usr/bin/python3 -c "
import json, os
runs = [json.loads(os.environ[k]) for k in 'AB' if os.environ[k].strip()]
keys = set().union(*runs) if runs else set()
print(json.dumps({k: min(r[k] for r in runs if k in r) for k in keys}) if runs else '')
")
[[ -n "$LINE" ]] || { echo "perf: the test didn't report (crashed or timed out)"; exit 1; }

FAIL=0
for key in ${(ok)BUDGET}; do
  value=$(print -r -- "$LINE" | /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin).get('$key', 'missing'))")
  limit=${BUDGET[$key]}
  if [[ "$value" == missing ]]; then printf '  ?  %-22s missing\n' $key; FAIL=1; continue; fi
  if (( value > limit )); then mark='✗'; FAIL=1; else mark='✓'; fi
  printf '  %s  %-22s %8s   (budget %s)\n' $mark $key $value $limit
done
print -r -- "$LINE" | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"     sessions {int(d['session_files'])}, cold token count {d['token_count_cold_ms']/1000:.1f}s (background, once)\")"
print -r -- "$LINE" | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin); m=sorted(k for k in d if k.startswith('mark')); print('     launch: ' + ' → '.join(f\"{k.split('_',1)[1].rsplit('_ms',1)[0]} {d[k]:.0f}\" for k in m))"
# Every run lands in perf/history.tsv, so drift shows up long before it breaks a budget.
mkdir -p perf
if [[ ! -f perf/history.tsv ]]; then head="date	commit"; for key in ${(ok)BUDGET}; do head+="	$key"; done; print -r -- "$head" > perf/history.tsv; fi
row="$(date +%Y-%m-%dT%H:%M)	$(git rev-parse --short HEAD)$(git diff --quiet || echo +)"
for key in ${(ok)BUDGET}; do row+="	$(print -r -- "$LINE" | /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin).get('$key',''))")"; done
print -r -- "$row" >> perf/history.tsv
(( FAIL == 0 )) && echo "perf: within budget" || { echo "perf: OVER BUDGET"; exit 1; }
