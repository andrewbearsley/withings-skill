#!/usr/bin/env bash
#
# withings-auth.sh - OAuth2 setup and token management for the Withings API
#
# Usage:
#   ./withings-auth.sh setup    One-time OAuth2 authorization flow
#   ./withings-auth.sh refresh  Refresh the access token
#   ./withings-auth.sh token    Output a valid access token (auto-refreshes if expired)
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

API_BASE="https://wbsapi.withings.net"
AUTH_URL="https://account.withings.com/oauth2_user/authorize2"

WITHINGS_CLIENT_ID="${WITHINGS_CLIENT_ID:?Error: WITHINGS_CLIENT_ID environment variable is not set}"
WITHINGS_CLIENT_SECRET="${WITHINGS_CLIENT_SECRET:?Error: WITHINGS_CLIENT_SECRET environment variable is not set}"
WITHINGS_TOKEN_FILE="${WITHINGS_TOKEN_FILE:-$HOME/.withings-tokens}"
WITHINGS_REDIRECT_URI="${WITHINGS_REDIRECT_URI:-http://localhost:9876/callback}"

# --- Helper functions ---

save_tokens() {
  local access_token="$1" refresh_token="$2" expires_in="$3" user_id="$4"

  # Validate fields before saving
  if [ "$access_token" = "null" ] || [ -z "$access_token" ]; then
    echo "Error: API response missing access_token" >&2
    return 1
  fi
  if [ "$refresh_token" = "null" ] || [ -z "$refresh_token" ]; then
    echo "Error: API response missing refresh_token" >&2
    return 1
  fi

  local expires_at=$(($(date +%s) + expires_in))

  # Use umask to create file with 600 permissions from the start
  (
    umask 077
    jq -n \
      --arg at "$access_token" \
      --arg rt "$refresh_token" \
      --arg ea "$expires_at" \
      --arg uid "$user_id" \
      '{access_token: $at, refresh_token: $rt, expires_at: ($ea | tonumber), user_id: $uid}' \
      > "$WITHINGS_TOKEN_FILE"
  )
}

load_tokens() {
  if [ ! -f "$WITHINGS_TOKEN_FILE" ]; then
    echo "Error: Token file not found at $WITHINGS_TOKEN_FILE" >&2
    echo "Run '$0 setup' to authorize with Withings first." >&2
    return 1
  fi

  # Check file permissions
  local perms
  if [[ "$OSTYPE" == "darwin"* ]]; then
    perms=$(stat -f '%Lp' "$WITHINGS_TOKEN_FILE")
  else
    perms=$(stat -c '%a' "$WITHINGS_TOKEN_FILE")
  fi
  if [ "$perms" != "600" ]; then
    echo "Warning: Token file has insecure permissions ($perms), fixing to 600." >&2
    chmod 600 "$WITHINGS_TOKEN_FILE"
  fi

  # Validate structure
  local tokens
  tokens=$(cat "$WITHINGS_TOKEN_FILE")
  if ! echo "$tokens" | jq -e '.access_token and .refresh_token and .expires_at' >/dev/null 2>&1; then
    echo "Error: Token file is corrupted or incomplete. Re-run '$0 setup'." >&2
    return 1
  fi

  echo "$tokens"
}

is_token_expired() {
  local tokens="$1"
  local expires_at now
  expires_at=$(echo "$tokens" | jq -r '.expires_at')
  now=$(date +%s)
  # Refresh 5 minutes early to avoid edge cases
  [ "$now" -ge "$((expires_at - 300))" ]
}

check_api_status() {
  local response="$1" context="$2"

  # Check response is valid JSON
  if ! echo "$response" | jq empty 2>/dev/null; then
    echo "Error: Invalid response from Withings API during $context (network error?)" >&2
    return 1
  fi

  local status
  status=$(echo "$response" | jq -r '.status')
  if [ "$status" != "0" ]; then
    local error
    error=$(echo "$response" | jq -r '.error // empty')
    echo "Error: Withings API returned status $status during $context${error:+: $error}" >&2
    return 1
  fi
}

# --- Commands ---

do_setup() {
  local state
  state=$(openssl rand -hex 16)

  echo "Withings OAuth2 Setup" >&2
  echo "=====================" >&2
  echo "" >&2
  echo "1. Open the following URL in your browser:" >&2
  echo "" >&2
  echo "   ${AUTH_URL}?response_type=code&client_id=${WITHINGS_CLIENT_ID}&redirect_uri=${WITHINGS_REDIRECT_URI}&scope=user.metrics&state=${state}" >&2
  echo "" >&2
  echo "2. Log in and authorize the application." >&2
  echo "3. You'll be redirected to a URL like:" >&2
  echo "   ${WITHINGS_REDIRECT_URI}?code=XXXXX&state=..." >&2
  echo "" >&2
  echo "   (The page won't load, that's expected. Copy the URL from your browser's address bar.)" >&2
  echo "" >&2
  read -rp "Paste the full redirect URL here: " redirect_url

  # Validate state parameter
  local returned_state
  returned_state=$(echo "$redirect_url" | sed -n 's/.*[?&]state=\([^&#]*\).*/\1/p')
  if [ "$returned_state" != "$state" ]; then
    echo "Error: State parameter mismatch. Expected '$state', got '$returned_state'." >&2
    echo "This could indicate a CSRF attack or a stale URL. Try again." >&2
    return 1
  fi

  # Extract the authorization code (strip fragments)
  local code
  code=$(echo "$redirect_url" | sed -n 's/.*[?&]code=\([^&#]*\).*/\1/p')

  if [ -z "$code" ]; then
    echo "Error: Could not extract authorization code from URL." >&2
    echo "Make sure you pasted the full URL including the ?code= parameter." >&2
    return 1
  fi

  echo "" >&2
  echo "Exchanging authorization code for tokens..." >&2

  local response
  response=$(curl -s -X POST "${API_BASE}/v2/oauth2" \
    -d "action=requesttoken" \
    -d "grant_type=authorization_code" \
    -d "client_id=${WITHINGS_CLIENT_ID}" \
    -d "client_secret=${WITHINGS_CLIENT_SECRET}" \
    -d "code=${code}" \
    -d "redirect_uri=${WITHINGS_REDIRECT_URI}" \
    --max-time 30)

  check_api_status "$response" "token exchange" || return 1

  local access_token refresh_token expires_in user_id
  access_token=$(echo "$response" | jq -r '.body.access_token')
  refresh_token=$(echo "$response" | jq -r '.body.refresh_token')
  expires_in=$(echo "$response" | jq -r '.body.expires_in')
  user_id=$(echo "$response" | jq -r '.body.userid')

  save_tokens "$access_token" "$refresh_token" "$expires_in" "$user_id" || return 1

  echo "Success! Tokens saved to $WITHINGS_TOKEN_FILE" >&2
  echo "  User ID:    $user_id" >&2
  echo "  Expires in: ${expires_in}s (~$((expires_in / 3600))h)" >&2
}

do_refresh() {
  local tokens
  tokens=$(load_tokens) || return 1

  local refresh_token
  refresh_token=$(echo "$tokens" | jq -r '.refresh_token')

  local response
  response=$(curl -s -X POST "${API_BASE}/v2/oauth2" \
    -d "action=requesttoken" \
    -d "grant_type=refresh_token" \
    -d "client_id=${WITHINGS_CLIENT_ID}" \
    -d "client_secret=${WITHINGS_CLIENT_SECRET}" \
    -d "refresh_token=${refresh_token}" \
    --max-time 30)

  check_api_status "$response" "token refresh" || return 1

  local access_token new_refresh_token expires_in user_id
  access_token=$(echo "$response" | jq -r '.body.access_token')
  new_refresh_token=$(echo "$response" | jq -r '.body.refresh_token')
  expires_in=$(echo "$response" | jq -r '.body.expires_in')
  user_id=$(echo "$response" | jq -r '.body.userid')

  save_tokens "$access_token" "$new_refresh_token" "$expires_in" "$user_id" || return 1

  echo "Token refreshed successfully." >&2
  echo "  Expires in: ${expires_in}s (~$((expires_in / 3600))h)" >&2
}

do_token() {
  local tokens
  tokens=$(load_tokens) || return 1

  if is_token_expired "$tokens"; then
    echo "Access token expired, refreshing..." >&2
    do_refresh || return 1
    tokens=$(load_tokens) || return 1
  fi

  echo "$tokens" | jq -r '.access_token'
}

# --- Main ---

case "${1:-}" in
  setup)   do_setup ;;
  refresh) do_refresh ;;
  token)   do_token ;;
  --help|-h)
    echo "Usage: $0 {setup|refresh|token}"
    echo ""
    echo "  setup    One-time OAuth2 authorization flow"
    echo "  refresh  Refresh the access token"
    echo "  token    Output a valid access token (auto-refreshes if expired)"
    echo ""
    echo "Environment:"
    echo "  WITHINGS_CLIENT_ID      Withings developer app client ID"
    echo "  WITHINGS_CLIENT_SECRET  Withings developer app client secret"
    echo "  WITHINGS_TOKEN_FILE     Path to token file (default: ~/.withings-tokens)"
    echo "  WITHINGS_REDIRECT_URI   OAuth redirect URI (default: http://localhost:9876/callback)"
    exit 0
    ;;
  *)
    echo "Usage: $0 {setup|refresh|token}" >&2
    echo "Run '$0 --help' for details." >&2
    exit 1
    ;;
esac
