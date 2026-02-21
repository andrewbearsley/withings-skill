#!/usr/bin/env bash
#
# withings-status.sh - Query body measurements from the Withings API
#
# Usage: ./withings-status.sh [--raw] [--json] [--days N]
#   --raw     Output raw JSON from the API
#   --json    Output parsed JSON with readable values
#   --days N  Measurements from the last N days (default: 7)
#
# Requires: curl, jq
# Environment: WITHINGS_CLIENT_ID, WITHINGS_CLIENT_SECRET

set -euo pipefail

# --- Dependency checks ---

for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: Required command '$cmd' not found. Install it and try again." >&2
    exit 1
  fi
done

# --- Configuration ---

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
API_BASE="https://wbsapi.withings.net"

# Measurement type map (single source of truth)
MEAS_TYPES='{
  "1":  {"name": "Weight",        "unit": "kg"},
  "5":  {"name": "Fat-Free Mass", "unit": "kg"},
  "6":  {"name": "Fat Ratio",     "unit": "%"},
  "8":  {"name": "Fat Mass",      "unit": "kg"},
  "76": {"name": "Muscle Mass",   "unit": "kg"},
  "77": {"name": "Hydration",     "unit": "kg"},
  "88": {"name": "Bone Mass",     "unit": "kg"}
}'

# --- Argument parsing ---

OUTPUT_MODE="formatted"
DAYS=7

while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw)    OUTPUT_MODE="raw"; shift ;;
    --json)   OUTPUT_MODE="json"; shift ;;
    --days)
      shift
      if [[ $# -eq 0 ]] || [[ "$1" == --* ]]; then
        echo "Error: --days requires a numeric value." >&2
        exit 1
      fi
      DAYS="$1"; shift ;;
    --days=*)
      DAYS="${1#--days=}"; shift ;;
    --help|-h)
      echo "Usage: $0 [--raw] [--json] [--days N]"
      echo "  --raw     Output raw JSON from the API"
      echo "  --json    Output parsed JSON with readable values"
      echo "  --days N  Measurements from last N days (default: 7)"
      echo ""
      echo "Environment: WITHINGS_CLIENT_ID, WITHINGS_CLIENT_SECRET"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Validate --days is a positive integer
if ! [[ "$DAYS" =~ ^[0-9]+$ ]] || [ "$DAYS" -eq 0 ]; then
  echo "Error: --days must be a positive integer, got '$DAYS'." >&2
  exit 1
fi

# --- Helper functions ---

meas_type_name() {
  echo "$MEAS_TYPES" | jq -r --arg t "$1" '.[$t].name // "Unknown (\($t))"'
}

meas_type_unit() {
  echo "$MEAS_TYPES" | jq -r --arg t "$1" '.[$t].unit // ""'
}

# Convert raw value + unit exponent to actual value
# actual = value * 10^unit
convert_value() {
  local value="$1" unit="$2"
  echo "$value $unit" | awk '{printf "%.1f", $1 * (10 ^ $2)}'
}

# Portable date helpers
date_seconds_ago() {
  local days="$1"
  if [[ "$OSTYPE" == "darwin"* ]]; then
    date "-v-${days}d" +%s
  else
    date -d "-${days} days" +%s
  fi
}

date_format_ts() {
  local ts="$1" fmt="$2"
  if [[ "$OSTYPE" == "darwin"* ]]; then
    date -r "$ts" "+$fmt"
  else
    date -d "@$ts" "+$fmt"
  fi
}

# --- Get access token ---

ACCESS_TOKEN=$("$SCRIPT_DIR/withings-auth.sh" token) || exit 1

# --- Calculate date range ---

START_DATE=$(date_seconds_ago "$DAYS")
END_DATE=$(date +%s)

# --- Fetch measurements (with pagination) ---

ALL_GRPS="[]"
OFFSET=0
TIMEZONE=""
UPDATETIME=""

while true; do
  RESPONSE=$(curl -s -X POST "${API_BASE}/measure" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -d "action=getmeas" \
    -d "meastypes=1,5,6,8,76,77,88" \
    -d "category=1" \
    -d "startdate=${START_DATE}" \
    -d "enddate=${END_DATE}" \
    -d "offset=${OFFSET}" \
    --max-time 30)

  # Validate response is JSON
  if ! echo "$RESPONSE" | jq empty 2>/dev/null; then
    echo "Error: Invalid response from Withings API (network error?)." >&2
    exit 1
  fi

  # Check for API errors
  STATUS=$(echo "$RESPONSE" | jq -r '.status')
  if [ "$STATUS" != "0" ]; then
    local_error=$(echo "$RESPONSE" | jq -r '.error // empty')
    echo "Error: Withings API returned status $STATUS${local_error:+: $local_error}" >&2
    exit 1
  fi

  # Capture metadata from first page
  if [ "$OFFSET" -eq 0 ]; then
    TIMEZONE=$(echo "$RESPONSE" | jq -r '.body.timezone // empty')
    UPDATETIME=$(echo "$RESPONSE" | jq -r '.body.updatetime // empty')
  fi

  # Accumulate measurement groups
  PAGE_GRPS=$(echo "$RESPONSE" | jq '(.body.measuregrps // [])')
  ALL_GRPS=$(echo "$ALL_GRPS" "$PAGE_GRPS" | jq -s '.[0] + .[1]')

  # Check for more pages
  MORE=$(echo "$RESPONSE" | jq -r '.body.more // 0')
  if [ "$MORE" != "1" ]; then
    break
  fi
  OFFSET=$(echo "$RESPONSE" | jq -r '.body.offset')
done

# Reconstruct a response-like structure for downstream processing
RESPONSE=$(echo "$ALL_GRPS" | jq --arg tz "$TIMEZONE" --arg ut "$UPDATETIME" '{
  status: 0,
  body: {
    timezone: $tz,
    updatetime: ($ut | tonumber? // 0),
    measuregrps: .
  }
}')

# --- Output ---

if [ "$OUTPUT_MODE" = "raw" ]; then
  echo "$RESPONSE" | jq .
  exit 0
fi

# Parse measurements into readable format (with null guard)
PARSED=$(echo "$RESPONSE" | jq -r '
  (.body.measuregrps // [])
  | sort_by(-.date)
  | map({
      date: (.date | todate),
      timestamp: .date,
      measures: [.measures[] | {
        type: .type,
        value: (.value * pow(10; .unit)),
        raw_value: .value,
        raw_unit: .unit
      }]
    })
')

if [ "$OUTPUT_MODE" = "json" ]; then
  echo "$PARSED" | jq --argjson types "$MEAS_TYPES" '
    map({
      date,
      timestamp,
      measures: [.measures[] | {
        name: ($types[(.type | tostring)].name // "Unknown"),
        unit: ($types[(.type | tostring)].unit // ""),
        value: .value,
        type: .type
      }]
    })
  '
  exit 0
fi

# --- Formatted output ---

GRP_COUNT=$(echo "$RESPONSE" | jq '(.body.measuregrps // []) | length')

if [ "$GRP_COUNT" -eq 0 ]; then
  echo "No measurements found in the last ${DAYS} days."
  exit 0
fi

echo ""
echo "============================================"
echo "  Body Measurements (last ${DAYS} days)"
echo "============================================"

# Process each measurement group (most recent first)
for i in $(seq 0 $((GRP_COUNT - 1))); do
  GRP=$(echo "$RESPONSE" | jq "(.body.measuregrps // []) | sort_by(-.date) | .[$i]")
  DATE_TS=$(echo "$GRP" | jq -r '.date')

  DATE_FMT=$(date_format_ts "$DATE_TS" '%Y-%m-%d %H:%M')

  echo ""
  echo "  $DATE_FMT"
  echo "  ------------------------------------"

  MEAS_COUNT=$(echo "$GRP" | jq '.measures | length')
  for j in $(seq 0 $((MEAS_COUNT - 1))); do
    TYPE=$(echo "$GRP" | jq -r ".measures[$j].type")
    RAW_VALUE=$(echo "$GRP" | jq -r ".measures[$j].value")
    RAW_UNIT=$(echo "$GRP" | jq -r ".measures[$j].unit")

    ACTUAL=$(convert_value "$RAW_VALUE" "$RAW_UNIT")
    NAME=$(meas_type_name "$TYPE")
    UNIT=$(meas_type_unit "$TYPE")

    printf "    %-16s %8s %s\n" "$NAME" "$ACTUAL" "$UNIT"
  done
done

# Calculate weight summary if multiple groups
WEIGHT_VALUES=$(echo "$RESPONSE" | jq -r '
  [(.body.measuregrps // [])[].measures[] | select(.type == 1) | .value * pow(10; .unit)]
  | if length > 0 then . else empty end
') || true

if [ -n "$WEIGHT_VALUES" ]; then
  WEIGHT_STATS=$(echo "$WEIGHT_VALUES" | jq '{
    count: length,
    avg: (add / length),
    min: min,
    max: max
  }')

  COUNT=$(echo "$WEIGHT_STATS" | jq -r '.count')
  if [ "$COUNT" -gt 1 ]; then
    AVG=$(echo "$WEIGHT_STATS" | jq -r '.avg | . * 10 | round / 10')
    MIN=$(echo "$WEIGHT_STATS" | jq -r '.min | . * 10 | round / 10')
    MAX=$(echo "$WEIGHT_STATS" | jq -r '.max | . * 10 | round / 10')
    echo ""
    echo "  ${DAYS}-Day Weight Summary"
    echo "  ------------------------------------"
    printf "    %-16s %8s kg\n" "Average" "$AVG"
    printf "    %-16s %8s kg\n" "Range" "${MIN} - ${MAX}"
    printf "    %-16s %8s\n" "Measurements" "$COUNT"
  fi
fi

echo ""
echo "============================================"
echo "  Fetched at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"
