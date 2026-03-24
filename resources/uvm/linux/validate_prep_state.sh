#!/bin/sh
# Minimal POSIX-compatible validator: reads OVERALL_STATE from a prep_state file and prints colored status.
# Usage: ./validate_prep_state.sh /path/to/prep_state
# Exit codes: 0=Success, 1=arg/file error, 2=state not success

DEFAULT_PATH="/opt/Nutanix/prep_state"
if [ "$#" -lt 1 ]; then
  FILE="$DEFAULT_PATH"
else
  FILE="$1"
fi

if [ ! -f "$FILE" ] && [ "$FILE" = "$DEFAULT_PATH" ]; then
  printf "prep_state file not found at default location: %s\n" "$FILE" >&2
  printf "Usage: %s /path/to/prep_state\n" "$0" >&2
  exit 1
fi

if [ ! -f "$FILE" ]; then
  printf "prep_state file not found: %s\n" "$FILE" >&2
  exit 1
fi

state_line=$(grep -E '^OVERALL_STATE=' "$FILE" 2>/dev/null | tail -n 1 2>/dev/null || true)
if [ -z "$state_line" ]; then
  printf "OVERALL_STATE not found in file: %s\n" "$FILE" >&2
  exit 2
fi

# Remove the prefix
STATE=${state_line#OVERALL_STATE=}

# Print colored output using printf; colors use actual escape bytes
case "$STATE" in
  Success)
    printf 'OVERALL_STATE: \033[32m%s\033[0m\n' "$STATE" ; exit 0 ;;
  Failed|Failure)
    printf 'OVERALL_STATE: \033[31m%s\033[0m\n' "$STATE" ; exit 2 ;;
  Interrupted|InProgress)
    printf 'OVERALL_STATE: \033[33m%s\033[0m\n' "$STATE" ; exit 2 ;;
  *)
    printf 'OVERALL_STATE: %s\n' "$STATE" ; exit 2 ;;
esac
