#!/bin/bash
# attribut-webcontent.sh — G1 rerun attribution tool (v2, etime-correlation)
#
# Periodically samples all WebContent processes on the system and attributes each
# to its owning app. v2 attribution algorithm:
#
#   * Baseline delta: WebContent PIDs that exist AFTER the spike runs but did NOT
#     exist BEFORE are the spike's. The attributor can take a pre-run baseline
#     snapshot via --baseline flag and uses set difference.
#   * lsof container heuristic: a fallback. WebContent processes serving Safari
#     / Mail / Messages / Notes will have open handles to ~/Library/Containers/
#     com.apple.{Safari,mail,MobileSMS,Notes}/. The spike's WebContent does NOT
#     (its only file handles are framework/cryptex paths — verified on this
#     machine). So the container heuristic handles safari/mail/messages/notes,
#     and the baseline-delta handles the spike.
#   * Idle: WebContent with no user-data paths AND present before spike.
#   * Unknown: WebContent with user-data paths but no recognisable app pattern.
#
# Output: writes a CSV row per sample to $OUT_CSV with header:
#   timestamp, total_count, spike_count, spike_rss_bytes, safari_count,
#   mail_count, messages_count, notes_count, idle_count, unknown_count,
#   pids_spike, pids_other
#
# Usage: ./attribut-webcontent.sh <interval_sec> <duration_sec> <out_csv> [--baseline <pids_csv>]

set -u

INTERVAL="${1:-60}"
DURATION="${2:-1800}"
OUT_CSV="${3:-/tmp/webcontent-attribution.csv}"
shift 3
BASELINE_PIDS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --baseline) BASELINE_PIDS="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Header
echo "timestamp,total_count,spike_count,spike_rss_bytes,safari_count,mail_count,messages_count,notes_count,idle_count,unknown_count,pids_spike,pids_other" > "$OUT_CSV"

START=$(date +%s)
END=$(( START + DURATION ))

# Compute elapsed seconds from a process's etime string ("MM:SS" or "HH:MM:SS").
etime_to_seconds() {
  local et="$1"
  local IFS=':'
  local parts=( $et )
  if [ "${#parts[@]}" = 2 ]; then
    echo $(( ${parts[0]} * 60 + ${parts[1]} ))
  else
    echo $(( ${parts[0]} * 3600 + ${parts[1]} * 60 + ${parts[2]} ))
  fi
}

# Categorise a WebContent PID's open file handles.
categorise() {
  local pid="$1"
  local handles; handles=$(lsof -p "$pid" 2>/dev/null \
    | awk '$5 ~ /^(REG|DIR)$/ {print $NF}' \
    | grep -E "/Users/[^/]+/" \
    | grep -v "/System/\|/usr/\|/private/var/folders\|/System/Library/PrivateFrameworks\|/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices\|/System/Volumes/Preboot" \
    | sort -u)
  local category
  if echo "$handles" | grep -q "Containers/com.apple.Safari/" 2>/dev/null; then
    category="safari"
  elif echo "$handles" | grep -q "Containers/com.apple.mail/\|/Library/Mail/" 2>/dev/null; then
    category="mail"
  elif echo "$handles" | grep -q "Containers/com.apple.MobileSMS/\|Containers/com.apple.MessagesApp/\|/Library/Messages/" 2>/dev/null; then
    category="messages"
  elif echo "$handles" | grep -q "Containers/com.apple.Notes/" 2>/dev/null; then
    category="notes"
  elif [ -z "$handles" ]; then
    category="idle"
  else
    category="unknown"
  fi
  echo "$category"
}

# Check if PID is in the baseline set.
is_baseline() {
  local pid="$1"
  local IFS=','
  for b in $BASELINE_PIDS; do
    [ "$b" = "$pid" ] && return 0
  done
  return 1
}

sample_once() {
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # All WebContent PIDs (one PID per line)
  local pids; pids=$(/bin/ps -ax -o pid=,comm= 2>/dev/null | awk '{ if (tolower($0) ~ /webcontent/) { print $1 } }' | sort -n)
  local total; total=$(echo -n "$pids" | grep -c .)

  local spike_count=0 spike_rss=0 safari_count=0 mail_count=0 messages_count=0 notes_count=0 idle_count=0 unknown_count=0
  local spike_pids="" other_pids=""

  for pid in $pids; do
    local rss_kb; rss_kb=$(/bin/ps -p "$pid" -o rss= 2>/dev/null | tr -d ' ' || echo 0)
    local category; category=$(categorise "$pid")

    # Override to "spike" if not in baseline (i.e. appeared during the soak).
    if [ -n "$BASELINE_PIDS" ] && ! is_baseline "$pid"; then
      category="spike"
    fi

    case "$category" in
      spike)
        spike_count=$(( spike_count + 1 ))
        spike_rss=$(( spike_rss + (rss_kb * 1024) ))
        spike_pids="${spike_pids}${pid} "
        ;;
      safari) safari_count=$(( safari_count + 1 )); other_pids="${other_pids}${pid} "; ;;
      mail) mail_count=$(( mail_count + 1 )); other_pids="${other_pids}${pid} "; ;;
      messages) messages_count=$(( messages_count + 1 )); other_pids="${other_pids}${pid} "; ;;
      notes) notes_count=$(( notes_count + 1 )); other_pids="${other_pids}${pid} "; ;;
      idle) idle_count=$(( idle_count + 1 )); other_pids="${other_pids}${pid} "; ;;
      unknown) unknown_count=$(( unknown_count + 1 )); other_pids="${other_pids}${pid} "; ;;
    esac
  done

  spike_pids_csv=$(echo "$spike_pids" | tr ' ' ';')
  other_pids_csv=$(echo "$other_pids" | tr ' ' ';')

  printf "%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%s,%s\n" \
    "$now" "$total" "$spike_count" "$spike_rss" \
    "$safari_count" "$mail_count" "$messages_count" "$notes_count" \
    "$idle_count" "$unknown_count" \
    "$spike_pids_csv" "$other_pids_csv" >> "$OUT_CSV"
}

while [ "$(date +%s)" -lt "$END" ]; do
  sample_once
  sleep "$INTERVAL"
done

echo "attribut-webcontent: done. Wrote $(wc -l < "$OUT_CSV") lines to $OUT_CSV" >&2