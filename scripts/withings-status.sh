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
# Environment: WITHINGS_CLIENT_ID, WITHINGS_CLIENT_SECRET, WITHINGS_TOKEN_FILE

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
API_BASE="https://wbsapi.withings.net"

OUTPUT_MODE="formatted"
DAYS=7

for arg in "$@"; do
  case "$arg" in
    --raw)    OUTPUT_MODE="raw" ;;
    --json)   OUTPUT_MODE="json" ;;
    --days)   shift_next=true ;;
    --help|-h)
      echo "Usage: $0 [--raw] [--json] [--days N]"
      echo "  --raw     Output raw JSON from the API"
      echo "  --json    Output parsed JSON with readable values"
      echo "  --days N  Measurements from last N days (default: 7)"
      echo ""
      echo "Environment: WITHINGS_CLIENT_ID, WITHINGS_CLIENT_SECRET, WITHINGS_TOKEN_FILE"
      exit 0
      ;;
    *)
      if [ "${shift_next:-}" = "true" ]; then
        DAYS="$arg"
        shift_next=false
      else
        echo "Unknown option: $arg" >&2
        exit 1
      fi
      ;;
  esac
done

# --- Helper functions ---

meas_type_name() {
  case "$1" in
    1)  echo "Weight" ;;
    5)  echo "Fat-Free Mass" ;;
    6)  echo "Fat Ratio" ;;
    8)  echo "Fat Mass" ;;
    76) echo "Muscle Mass" ;;
    77) echo "Hydration" ;;
    88) echo "Bone Mass" ;;
    *)  echo "Unknown ($1)" ;;
  esac
}

meas_type_unit() {
  case "$1" in
    1)  echo "kg" ;;
    5)  echo "kg" ;;
    6)  echo "%" ;;
    8)  echo "kg" ;;
    76) echo "kg" ;;
    77) echo "kg" ;;
    88) echo "kg" ;;
    *)  echo "" ;;
  esac
}

# Convert raw value + unit exponent to actual value
# actual = value * 10^unit
convert_value() {
  local value="$1" unit="$2"
  echo "$value $unit" | awk '{printf "%.1f", $1 * (10 ^ $2)}'
}

# --- Get access token ---

ACCESS_TOKEN=$("$SCRIPT_DIR/withings-auth.sh" token) || {
  echo "Error: Failed to get access token. Run 'withings-auth.sh setup' to authorize." >&2
  exit 1
}

# --- Calculate date range ---

if [[ "$OSTYPE" == "darwin"* ]]; then
  START_DATE=$(date -v-${DAYS}d +%s)
else
  START_DATE=$(date -d "-${DAYS} days" +%s)
fi
END_DATE=$(date +%s)

# --- Fetch measurements ---

RESPONSE=$(curl -s -X POST "${API_BASE}/measure" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -d "action=getmeas" \
  -d "meastypes=1,5,6,8,76,77,88" \
  -d "category=1" \
  -d "startdate=${START_DATE}" \
  -d "enddate=${END_DATE}" \
  --max-time 30)

# Check for API errors
STATUS=$(echo "$RESPONSE" | jq -r '.status')
if [ "$STATUS" != "0" ]; then
  echo "Error: Withings API returned status $STATUS" >&2
  echo "$RESPONSE" | jq . >&2
  exit 1
fi

# --- Output ---

if [ "$OUTPUT_MODE" = "raw" ]; then
  echo "$RESPONSE" | jq .
  exit 0
fi

# Parse measurements into readable format
PARSED=$(echo "$RESPONSE" | jq -r '
  .body.measuregrps
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
  # Output parsed JSON with type names
  echo "$PARSED" | jq --argjson types '{
    "1": {"name": "Weight", "unit": "kg"},
    "5": {"name": "Fat-Free Mass", "unit": "kg"},
    "6": {"name": "Fat Ratio", "unit": "%"},
    "8": {"name": "Fat Mass", "unit": "kg"},
    "76": {"name": "Muscle Mass", "unit": "kg"},
    "77": {"name": "Hydration", "unit": "kg"},
    "88": {"name": "Bone Mass", "unit": "kg"}
  }' '
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

GRP_COUNT=$(echo "$RESPONSE" | jq '.body.measuregrps | length')

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
  GRP=$(echo "$RESPONSE" | jq ".body.measuregrps | sort_by(-.date) | .[$i]")
  DATE_TS=$(echo "$GRP" | jq -r '.date')

  if [[ "$OSTYPE" == "darwin"* ]]; then
    DATE_FMT=$(date -r "$DATE_TS" '+%Y-%m-%d %H:%M')
  else
    DATE_FMT=$(date -d "@$DATE_TS" '+%Y-%m-%d %H:%M')
  fi

  echo ""
  echo "  $DATE_FMT"
  echo "  ────────────────────────────────────"

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
  [.body.measuregrps[].measures[] | select(.type == 1) | .value * pow(10; .unit)]
  | if length > 0 then . else empty end
' 2>/dev/null)

if [ -n "$WEIGHT_VALUES" ]; then
  WEIGHT_STATS=$(echo "$WEIGHT_VALUES" | jq '{
    count: length,
    avg: (add / length),
    min: min,
    max: max,
    latest: .[0]
  }')

  COUNT=$(echo "$WEIGHT_STATS" | jq -r '.count')
  if [ "$COUNT" -gt 1 ]; then
    AVG=$(echo "$WEIGHT_STATS" | jq -r '.avg | . * 10 | round / 10')
    MIN=$(echo "$WEIGHT_STATS" | jq -r '.min | . * 10 | round / 10')
    MAX=$(echo "$WEIGHT_STATS" | jq -r '.max | . * 10 | round / 10')
    echo ""
    echo "  ${DAYS}-Day Weight Summary"
    echo "  ────────────────────────────────────"
    printf "    %-16s %8s kg\n" "Average" "$AVG"
    printf "    %-16s %8s kg\n" "Range" "${MIN} - ${MAX}"
    printf "    %-16s %8s\n" "Measurements" "$COUNT"
  fi
fi

echo ""
echo "============================================"
echo "  Fetched at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"
