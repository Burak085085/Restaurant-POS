#!/usr/bin/env bash
# Usage: report.sh <title> <logfile>
# Surfaces tool output as annotations and a job summary so that failures are
# readable on the run page without signing in. Never fails the step itself.
title="$1"
log="$2"
if [ ! -f "$log" ]; then
  echo "No log file: $log"
  exit 0
fi
{
  echo "### $title"
  echo '```'
  tail -n 120 "$log"
  echo '```'
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
grep -E '^[[:space:]]*(error|warning|info) • ' "$log" | head -n 40 | while IFS= read -r line; do
  sev=$(printf '%s' "$line" | awk -F ' • ' '{gsub(/^[ \t]+/,"",$1); print $1}')
  msg=$(printf '%s' "$line" | awk -F ' • ' '{print $2}')
  loc=$(printf '%s' "$line" | awk -F ' • ' '{print $3}')
  file=${loc%%:*}
  rest=${loc#*:}
  ln=${rest%%:*}
  col=${rest#*:}
  case "$sev" in
    error) lvl=error ;;
    warning) lvl=warning ;;
    *) lvl=notice ;;
  esac
  echo "::${lvl} file=${file},line=${ln},col=${col}::${msg}"
done
exit 0
