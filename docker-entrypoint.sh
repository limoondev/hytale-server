#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[hytale] $*"
}

DATA_DIR=${HYTALE_DATA_DIR:-/data}
SERVER_DIR=${HYTALE_SERVER_DIR:-$DATA_DIR/Server}
JAR_PATH=${HYTALE_SERVER_JAR:-$SERVER_DIR/HytaleServer.jar}
AOT_PATH=${HYTALE_AOT_PATH:-$SERVER_DIR/HytaleServer.aot}
ASSETS_PATH=${HYTALE_ASSETS_PATH:-$DATA_DIR/Assets.zip}
JAVA_OPTS_VALUE=${JAVA_OPTS:-}
SESSION_FILE=${HYTALE_SESSION_FILE:-$DATA_DIR/hytale-session.json}
HTTP_MAX_RETRIES=${HYTALE_HTTP_MAX_RETRIES:-5}
HTTP_RETRY_DELAY=${HYTALE_HTTP_RETRY_DELAY:-2}

mkdir -p "$DATA_DIR"
cd "$DATA_DIR"

ACCESS_TOKEN=""
REFRESH_TOKEN=""
PROFILE_UUID="${HYTALE_OWNER_UUID:-}"
SESSION_TOKEN=""
IDENTITY_TOKEN=""

if [[ -z "$JAVA_OPTS_VALUE" && -f "$AOT_PATH" ]]; then
  JAVA_OPTS_VALUE="-XX:AOTCache=${AOT_PATH}"
fi

curl_with_retry() {
  local attempt=1
  local output
  while true; do
    if output=$(curl -sS "$@"); then
      printf '%s' "$output"
      return 0
    fi
    local status=$?
    if (( attempt >= HTTP_MAX_RETRIES )); then
      log "HTTP request failed after ${HTTP_MAX_RETRIES} attempts (curl exit ${status})"
      return $status
    fi
    log "HTTP request failed (curl exit ${status}). Retrying in ${HTTP_RETRY_DELAY}s (${attempt}/${HTTP_MAX_RETRIES})..."
    sleep "$HTTP_RETRY_DELAY"
    attempt=$((attempt + 1))
  done
}

ensure_game_files() {
  local missing=0
  if [[ ! -f "$JAR_PATH" ]]; then
    log "Missing server jar at ${JAR_PATH}."
    missing=1
  fi
  if [[ ! -f "$ASSETS_PATH" ]]; then
    log "Missing assets archive at ${ASSETS_PATH}."
    missing=1
  fi
  if (( missing )); then
    cat <<EOF
[hytale] Download the official game files (Server/ and Assets.zip) via the Hytale launcher or hytale-downloader, place them inside ${DATA_DIR}, and restart the container.
EOF
    exit 1
  fi
}

request_device_code() {
  curl_with_retry "https://oauth.accounts.hytale.com/oauth2/device/auth" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "client_id=hytale-server" \
    -d "scope=openid offline auth:server"
}

format_user_code() {
  local code="$(echo "$1" | tr '[:lower:]' '[:upper:]')"
  if [[ ${#code} -eq 8 ]]; then
    echo "${code:0:4}-${code:4:4}"
  else
    echo "$code"
  fi
}

poll_for_token() {
  local device_code=$1
  local interval=$2
  while true; do
    local resp
    resp=$(curl_with_retry "https://oauth.accounts.hytale.com/oauth2/token" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "client_id=hytale-server" \
      -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
      -d "device_code=${device_code}")

    local error
    error=$(echo "$resp" | jq -r '.error // empty')
    if [[ -n "$error" ]]; then
      case "$error" in
        authorization_pending)
          sleep "$interval"
          continue
          ;;
        slow_down)
          sleep $((interval + 5))
          continue
          ;;
        *)
          log "OAuth error: $error"
          return 1
          ;;
      esac
    fi

    ACCESS_TOKEN=$(echo "$resp" | jq -r '.access_token // empty')
    REFRESH_TOKEN=$(echo "$resp" | jq -r '.refresh_token // empty')
    if [[ -z "$ACCESS_TOKEN" ]]; then
      log "Failed to obtain access token"
      return 1
    fi
    return 0
  done
}

refresh_with_token() {
  local refresh=$1
  local resp
  resp=$(curl_with_retry "https://oauth.accounts.hytale.com/oauth2/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "client_id=hytale-server" \
    -d "grant_type=refresh_token" \
    -d "refresh_token=${refresh}")
  local error
  error=$(echo "$resp" | jq -r '.error // empty')
  if [[ -n "$error" ]]; then
    log "Refresh token invalid (${error}), falling back to device login"
    return 1
  fi
  ACCESS_TOKEN=$(echo "$resp" | jq -r '.access_token // empty')
  REFRESH_TOKEN=$(echo "$resp" | jq -r '.refresh_token // empty')
  if [[ -z "$ACCESS_TOKEN" ]]; then
    log "Refresh failed to return access token"
    return 1
  fi
  return 0
}

select_profile() {
  local profiles_json=$1
  if [[ -n "$PROFILE_UUID" ]]; then
    return 0
  fi
  PROFILE_UUID=$(echo "$profiles_json" | jq -r '.profiles[0].uuid // empty')
  local username=$(echo "$profiles_json" | jq -r '.profiles[0].username // ""')
  if [[ -z "$PROFILE_UUID" ]]; then
    log "No profiles available on this account"
    return 1
  fi
  log "Selected profile ${username} (${PROFILE_UUID}). Set HYTALE_OWNER_UUID to override."
  return 0
}

create_session_tokens() {
  if [[ -z "$ACCESS_TOKEN" ]]; then
    log "Access token missing before session creation"
    return 1
  fi

  if [[ -z "$PROFILE_UUID" ]]; then
    local profiles_resp
    profiles_resp=$(curl_with_retry "https://account-data.hytale.com/my-account/get-profiles" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}")
    select_profile "$profiles_resp"
  fi

  local payload
  payload=$(jq -n --arg uuid "$PROFILE_UUID" '{uuid: $uuid}')
  local session_resp
  session_resp=$(curl_with_retry "https://sessions.hytale.com/game-session/new" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$payload")

  SESSION_TOKEN=$(echo "$session_resp" | jq -r '.sessionToken // empty')
  IDENTITY_TOKEN=$(echo "$session_resp" | jq -r '.identityToken // empty')
  if [[ -z "$SESSION_TOKEN" || -z "$IDENTITY_TOKEN" ]]; then
    log "Failed to create session tokens"
    return 1
  fi
  export HYTALE_OWNER_UUID=${PROFILE_UUID}

  if [[ -n "$REFRESH_TOKEN" ]]; then
    jq -n --arg refresh "$REFRESH_TOKEN" --arg profile "$PROFILE_UUID" '{refresh_token: $refresh, profile_uuid: $profile}' > "$SESSION_FILE"
  fi
  return 0
}

run_device_flow() {
  log "No session tokens provided. Starting device authorization..."
  local resp
  resp=$(request_device_code)
  local device_code=$(echo "$resp" | jq -r '.device_code // empty')
  local user_code=$(echo "$resp" | jq -r '.user_code // empty')
  local verify_uri=$(echo "$resp" | jq -r '.verification_uri_complete // empty')
  local interval=$(echo "$resp" | jq -r '.interval // 5')
  if [[ -z "$device_code" || -z "$user_code" ]]; then
    log "Failed to request device code"
    return 1
  fi
  local formatted_code
  formatted_code=$(format_user_code "$user_code")
  log "Visit: ${verify_uri}"
  log "Or enter code: ${formatted_code} at https://oauth.accounts.hytale.com/oauth2/device/verify"
  if ! poll_for_token "$device_code" "$interval"; then
    return 1
  fi
  log "Authorization complete"
  create_session_tokens
}

attempt_auto_refresh() {
  if [[ ! -f "$SESSION_FILE" ]]; then
    return 1
  fi
  local refresh=$(jq -r '.refresh_token // empty' "$SESSION_FILE")
  local stored_profile=$(jq -r '.profile_uuid // empty' "$SESSION_FILE")
  if [[ -z "$refresh" || -z "$stored_profile" ]]; then
    return 1
  fi
  PROFILE_UUID=${HYTALE_OWNER_UUID:-$stored_profile}
  if refresh_with_token "$refresh" && create_session_tokens; then
    log "Refreshed tokens using stored credentials"
    return 0
  fi
  return 1
}

ensure_tokens() {
  if attempt_auto_refresh; then
    return 0
  fi
  run_device_flow
}

ensure_game_files
ensure_tokens

args=("--assets" "$ASSETS_PATH")

if [[ -n "$SESSION_TOKEN" ]]; then
  args+=("--session-token" "$SESSION_TOKEN")
fi

if [[ -n "$IDENTITY_TOKEN" ]]; then
  args+=("--identity-token" "$IDENTITY_TOKEN")
fi

if [[ -n "${HYTALE_OWNER_UUID:-}" ]]; then
  args+=("--owner-uuid" "$HYTALE_OWNER_UUID")
fi

if [[ -n "${HYTALE_EXTRA_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  extra=( ${HYTALE_EXTRA_ARGS} )
  args+=("${extra[@]}")
fi

exec java ${JAVA_OPTS_VALUE} -jar "$JAR_PATH" "${args[@]}" "$@"
