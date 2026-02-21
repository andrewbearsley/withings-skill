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
# Environment: WITHINGS_CLIENT_ID, WITHINGS_CLIENT_SECRET, WITHINGS_TOKEN_FILE

set -euo pipefail

API_BASE="https://wbsapi.withings.net"
AUTH_URL="https://account.withings.com/oauth2_user/authorize2"

WITHINGS_CLIENT_ID="${WITHINGS_CLIENT_ID:?Error: WITHINGS_CLIENT_ID environment variable is not set}"
WITHINGS_CLIENT_SECRET="${WITHINGS_CLIENT_SECRET:?Error: WITHINGS_CLIENT_SECRET environment variable is not set}"
WITHINGS_TOKEN_FILE="${WITHINGS_TOKEN_FILE:-$HOME/.withings-tokens}"
WITHINGS_REDIRECT_URI="${WITHINGS_REDIRECT_URI:-http://localhost:9876/callback}"

# --- Helper functions ---

save_tokens() {
  local access_token="$1" refresh_token="$2" expires_in="$3" user_id="$4"
  local expires_at=$(($(date +%s) + expires_in))

  jq -n \
    --arg at "$access_token" \
    --arg rt "$refresh_token" \
    --arg ea "$expires_at" \
    --arg uid "$user_id" \
    '{access_token: $at, refresh_token: $rt, expires_at: ($ea | tonumber), user_id: $uid}' \
    > "$WITHINGS_TOKEN_FILE"
  chmod 600 "$WITHINGS_TOKEN_FILE"
}

load_tokens() {
  if [ ! -f "$WITHINGS_TOKEN_FILE" ]; then
    echo "Error: Token file not found at $WITHINGS_TOKEN_FILE" >&2
    echo "Run '$0 setup' to authorize with Withings first." >&2
    return 1
  fi
  cat "$WITHINGS_TOKEN_FILE"
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
  local status
  status=$(echo "$response" | jq -r '.status')
  if [ "$status" != "0" ]; then
    echo "Error: Withings API returned status $status during $context" >&2
    echo "$response" | jq . >&2
    return 1
  fi
}

# --- Commands ---

do_setup() {
  echo "Withings OAuth2 Setup"
  echo "====================="
  echo ""
  echo "1. Open the following URL in your browser:"
  echo ""
  echo "   ${AUTH_URL}?response_type=code&client_id=${WITHINGS_CLIENT_ID}&redirect_uri=${WITHINGS_REDIRECT_URI}&scope=user.metrics&state=openclaw"
  echo ""
  echo "2. Log in and authorize the application."
  echo "3. You'll be redirected to a URL like:"
  echo "   ${WITHINGS_REDIRECT_URI}?code=XXXXX&state=openclaw"
  echo ""
  echo "   (The page won't load — that's expected. Copy the URL from your browser's address bar.)"
  echo ""
  read -rp "Paste the full redirect URL here: " redirect_url

  # Extract the authorization code from the URL
  local code
  code=$(echo "$redirect_url" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')

  if [ -z "$code" ]; then
    echo "Error: Could not extract authorization code from URL." >&2
    echo "Make sure you pasted the full URL including the ?code= parameter." >&2
    return 1
  fi

  echo ""
  echo "Exchanging authorization code for tokens..."

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

  save_tokens "$access_token" "$refresh_token" "$expires_in" "$user_id"

  echo "Success! Tokens saved to $WITHINGS_TOKEN_FILE"
  echo "  User ID:    $user_id"
  echo "  Expires in: ${expires_in}s (~$((expires_in / 3600))h)"
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

  save_tokens "$access_token" "$new_refresh_token" "$expires_in" "$user_id"

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
    ;;
  *)
    echo "Usage: $0 {setup|refresh|token}" >&2
    echo "Run '$0 --help' for details." >&2
    exit 1
    ;;
esac
