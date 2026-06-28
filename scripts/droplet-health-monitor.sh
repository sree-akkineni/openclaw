#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="${LOG_DIR:-/var/log/openclaw-health}"
LOOKBACK_MINUTES="${LOOKBACK_MINUTES:-15}"
WARN_AVAILABLE_MEM_MB="${WARN_AVAILABLE_MEM_MB:-1024}"
WARN_SWAP_USED_MB="${WARN_SWAP_USED_MB:-256}"
WARN_ROOT_DISK_PCT="${WARN_ROOT_DISK_PCT:-90}"
WARN_CONTAINER_MEM_PCT="${WARN_CONTAINER_MEM_PCT:-75}"
CONTAINERS=(
  "openclaw-docker-openclaw-gateway-1"
  "clawops-gateway"
  "gumnut-bot-gateway"
  "remy-bot-gateway"
)

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

for cmd in jq docker free df journalctl logger awk sed grep mktemp; do
  require_cmd "$cmd"
done

mkdir -p "$LOG_DIR"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
history_file="$LOG_DIR/history.jsonl"
latest_file="$LOG_DIR/latest.json"
issues_file="$tmpdir/issues.txt"
warnings_file="$tmpdir/warnings.txt"
containers_file="$tmpdir/containers.jsonl"
touch "$issues_file" "$warnings_file" "$containers_file"

add_issue() {
  printf '%s\n' "$1" >>"$issues_file"
}

add_warning() {
  printf '%s\n' "$1" >>"$warnings_file"
}

mem_line="$(free -m | awk '/^Mem:/ {print $2" "$3" "$7}')"
swap_line="$(free -m | awk '/^Swap:/ {print $2" "$3}')"
read -r mem_total_mb mem_used_mb mem_available_mb <<<"$mem_line"
read -r swap_total_mb swap_used_mb <<<"$swap_line"

disk_line="$(df -Pm / | awk 'NR==2 {gsub(/%/, "", $5); print $2" "$3" "$4" "$5}')"
read -r root_size_mb root_used_mb root_avail_mb root_used_pct <<<"$disk_line"

if (( mem_available_mb < WARN_AVAILABLE_MEM_MB )); then
  add_issue "available memory low: ${mem_available_mb}MB < ${WARN_AVAILABLE_MEM_MB}MB"
fi

if (( swap_used_mb > WARN_SWAP_USED_MB )); then
  add_warning "swap usage high: ${swap_used_mb}MB > ${WARN_SWAP_USED_MB}MB"
fi

if (( root_used_pct >= WARN_ROOT_DISK_PCT )); then
  add_warning "root disk usage high: ${root_used_pct}% >= ${WARN_ROOT_DISK_PCT}%"
fi

recent_oom_count="$(
  journalctl -k --since "-${LOOKBACK_MINUTES} min" --no-pager 2>/dev/null \
    | grep -E -c 'Memory cgroup out of memory|Killed process .*MainThread|Killed process .*chromium|Killed process .*chrome_crashpad|oom-killer' || true
)"

if (( recent_oom_count > 0 )); then
  add_issue "recent kernel OOM events: ${recent_oom_count} in last ${LOOKBACK_MINUTES}m"
fi

last_boot_oom_count="$(
  journalctl -k -b -1 --since "-12 hours" --no-pager 2>/dev/null \
    | grep -E -c 'Memory cgroup out of memory|Killed process .*MainThread|Killed process .*chromium|Killed process .*chrome_crashpad|oom-killer' || true
)"

container_lines="$(
  docker ps --format '{{.Names}}\t{{.Status}}' \
    | grep -E '^(openclaw-docker-openclaw-gateway-1|clawops-gateway|gumnut-bot-gateway|remy-bot-gateway)\b' || true
)"

for container in "${CONTAINERS[@]}"; do
  status_line="$(printf '%s\n' "$container_lines" | awk -F '\t' -v name="$container" '$1 == name {print $0}')"
  if [ -z "$status_line" ]; then
    add_issue "container missing: ${container}"
  fi
done

stats_lines="$(
  docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemPerc}}\t{{.MemUsage}}' \
    | grep -E '^(openclaw-docker-openclaw-gateway-1|clawops-gateway|gumnut-bot-gateway|remy-bot-gateway)\b' || true
)"

while IFS=$'\t' read -r container cpu_pct mem_pct mem_usage; do
  [ -n "${container:-}" ] || continue
  clean_mem_pct="${mem_pct%%%}"
  if awk "BEGIN { exit !($clean_mem_pct >= $WARN_CONTAINER_MEM_PCT) }"; then
    add_warning "container memory high: ${container} ${mem_pct} (${mem_usage})"
  fi
done <<<"$stats_lines"

auth_error_count=0
auth_patterns='Couldn.t sign in to openai-http|Incorrect API key provided|No API key found for provider "openai-http"|401 Incorrect API key|saved login looks expired'
rate_limit_count=0
rate_limit_patterns='429|rate limit'

for container in "${CONTAINERS[@]}"; do
  auth_hits="$(
    docker logs --since "${LOOKBACK_MINUTES}m" "$container" 2>&1 \
      | grep -E -c "$auth_patterns" || true
  )"
  rate_hits="$(
    docker logs --since "${LOOKBACK_MINUTES}m" "$container" 2>&1 \
      | grep -E -c "$rate_limit_patterns" || true
  )"

  auth_error_count=$((auth_error_count + auth_hits))
  rate_limit_count=$((rate_limit_count + rate_hits))

  status_text="$(printf '%s\n' "$container_lines" | awk -F '\t' -v name="$container" '$1 == name {print $2}')"
  stats_text="$(printf '%s\n' "$stats_lines" | awk -F '\t' -v name="$container" '$1 == name {print $2"\t"$3"\t"$4}')"
  cpu_pct="$(printf '%s\n' "$stats_text" | awk -F '\t' '{print $1}')"
  mem_pct="$(printf '%s\n' "$stats_text" | awk -F '\t' '{print $2}')"
  mem_usage="$(printf '%s\n' "$stats_text" | awk -F '\t' '{print $3}')"

  jq -nc \
    --arg name "$container" \
    --arg status "${status_text:-missing}" \
    --arg cpu "${cpu_pct:-}" \
    --arg mem_pct "${mem_pct:-}" \
    --arg mem_usage "${mem_usage:-}" \
    --argjson auth_hits "$auth_hits" \
    --argjson rate_hits "$rate_hits" \
    '{name: $name, status: $status, cpu: $cpu, mem_pct: $mem_pct, mem_usage: $mem_usage, auth_error_hits: $auth_hits, rate_limit_hits: $rate_hits}' \
    >>"$containers_file"
done

if (( auth_error_count > 0 )); then
  add_issue "recent auth failures detected: ${auth_error_count} in last ${LOOKBACK_MINUTES}m"
fi

if (( rate_limit_count > 0 )); then
  add_warning "recent rate limit signals detected: ${rate_limit_count} in last ${LOOKBACK_MINUTES}m"
fi

issue_count="$(wc -l <"$issues_file" | tr -d ' ')"
warning_count="$(wc -l <"$warnings_file" | tr -d ' ')"

status="ok"
if (( issue_count > 0 )); then
  status="fail"
elif (( warning_count > 0 )); then
  status="warn"
fi

jq -n \
  --arg timestamp "$timestamp" \
  --arg status "$status" \
  --arg hostname "$(hostname)" \
  --argjson lookback_minutes "$LOOKBACK_MINUTES" \
  --argjson mem_total_mb "$mem_total_mb" \
  --argjson mem_used_mb "$mem_used_mb" \
  --argjson mem_available_mb "$mem_available_mb" \
  --argjson swap_total_mb "$swap_total_mb" \
  --argjson swap_used_mb "$swap_used_mb" \
  --argjson root_size_mb "$root_size_mb" \
  --argjson root_used_mb "$root_used_mb" \
  --argjson root_avail_mb "$root_avail_mb" \
  --argjson root_used_pct "$root_used_pct" \
  --argjson recent_oom_count "$recent_oom_count" \
  --argjson last_boot_oom_count "$last_boot_oom_count" \
  --argjson auth_error_count "$auth_error_count" \
  --argjson rate_limit_count "$rate_limit_count" \
  --slurpfile containers "$containers_file" \
  --rawfile issues "$issues_file" \
  --rawfile warnings "$warnings_file" \
  '{
    timestamp: $timestamp,
    status: $status,
    hostname: $hostname,
    lookback_minutes: $lookback_minutes,
    memory: {
      total_mb: $mem_total_mb,
      used_mb: $mem_used_mb,
      available_mb: $mem_available_mb
    },
    swap: {
      total_mb: $swap_total_mb,
      used_mb: $swap_used_mb
    },
    root_disk: {
      size_mb: $root_size_mb,
      used_mb: $root_used_mb,
      avail_mb: $root_avail_mb,
      used_pct: $root_used_pct
    },
    recent_oom_count: $recent_oom_count,
    last_boot_oom_count: $last_boot_oom_count,
    auth_error_count: $auth_error_count,
    rate_limit_count: $rate_limit_count,
    containers: $containers,
    issues: ($issues | split("\n") | map(select(length > 0))),
    warnings: ($warnings | split("\n") | map(select(length > 0)))
  }' >"$latest_file"

cat "$latest_file" >>"$history_file"

summary="openclaw droplet health status=${status} mem_available_mb=${mem_available_mb} recent_oom_count=${recent_oom_count} auth_error_count=${auth_error_count} latest_json=${latest_file}"
case "$status" in
  fail)
    logger -p daemon.warning "$summary"
    ;;
  warn)
    logger -p daemon.notice "$summary"
    ;;
  *)
    logger -p daemon.info "$summary"
    ;;
esac

echo "$summary"

if [ "$status" = "fail" ]; then
  exit 1
fi

exit 0
