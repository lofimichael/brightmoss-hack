#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"

helper_pid=""
helper_log=""
preserve_helper_log=0
checkpoint_app_pid=""
resolved_helper_url=""
resolved_helper_token=""
normalized_helper_url=""

# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
  local exit_status=$?
  trap - EXIT

  if [[ -n "$helper_pid" ]]; then
    if kill -0 "$helper_pid" 2>/dev/null; then
      kill "$helper_pid" 2>/dev/null || true
    fi
    wait "$helper_pid" 2>/dev/null || true
  fi

  if [[ -n "$helper_log" && "$preserve_helper_log" -ne 1 ]]; then
    rm -f "$helper_log"
  fi

  exit "$exit_status"
}

# shellcheck disable=SC2329 # Invoked by the signal traps.
forward_signal() {
  local signal_name="$1"
  local exit_status="$2"
  trap - INT TERM HUP
  if [[ -n "$checkpoint_app_pid" ]] && kill -0 "$checkpoint_app_pid" 2>/dev/null; then
    kill -s "$signal_name" "$checkpoint_app_pid" 2>/dev/null || true
  fi
  exit "$exit_status"
}

trap cleanup EXIT
trap 'forward_signal INT 130' INT
trap 'forward_signal TERM 143' TERM
trap 'forward_signal HUP 129' HUP

set -a
for operator_file in \
  "$project_root/.env" \
  "$project_root/scripts/.env.local" \
  "$project_root/.env.local"; do
  if [[ -f "$operator_file" ]]; then
    # shellcheck disable=SC1090
    source "$operator_file"
  fi
done
if [[ -z "${BRIGHT_DATA_API_KEY:-}" && -n "${BRIGHTDATA_API_KEY:-}" ]]; then
  BRIGHT_DATA_API_KEY="$BRIGHTDATA_API_KEY"
fi
set +a

checkpoint_data_dir="${CHECKPOINT_DATA_DIR:-$HOME/Library/Application Support/Checkpoint}"
if [[ "$checkpoint_data_dir" == \~/* ]]; then
  checkpoint_data_dir="$HOME/${checkpoint_data_dir#\~/}"
elif [[ "$checkpoint_data_dir" != /* ]]; then
  checkpoint_data_dir="$project_root/$checkpoint_data_dir"
fi
connection_file="$checkpoint_data_dir/agent-connection.json"

normalize_loopback_url() {
  local candidate="${1%/}"
  local loopback_pattern='^http://(127\.0\.0\.1|localhost):([0-9]{1,5})$'
  [[ "$candidate" =~ $loopback_pattern ]] || return 1
  local port="${BASH_REMATCH[2]}"
  ((port >= 1 && port <= 65535)) || return 1
  normalized_helper_url="$candidate"
}

valid_token() {
  local token="$1"
  [[ -n "$token" && ${#token} -le 4096 ]] || return 1
  [[ "$token" != *$'\r'* && "$token" != *$'\n'* ]] || return 1
}

helper_is_healthy() {
  local candidate_url="$1"
  local candidate_token="$2"
  local health_response

  normalize_loopback_url "$candidate_url" || return 1
  valid_token "$candidate_token" || return 1
  health_response="$(
    printf 'Authorization: Bearer %s\n' "$candidate_token" |
      /usr/bin/curl \
        --silent \
        --fail \
        --connect-timeout 1 \
        --max-time 2 \
        --header @- \
        "$normalized_helper_url/health" 2>/dev/null
  )" || return 1

  # A process can outlive a rebuild during development. Reuse only a helper
  # that implements the current persistent-memory and enrichment-ledger API.
  [[ "$(printf '%s\n' "$health_response" | jq -r '.status // empty')" == "ok" ]] || return 1
  [[ "$(printf '%s\n' "$health_response" | jq -r '.api_version // 0')" -ge 2 ]]
}

load_secure_descriptor() {
  local descriptor_owner
  local descriptor_mode
  local descriptor_size
  local candidate_url
  local candidate_port
  local candidate_token
  local secure_mode_pattern='^[0-7]*00$'

  [[ -f "$connection_file" && ! -L "$connection_file" ]] || return 1
  descriptor_owner="$(stat -f '%u' "$connection_file" 2>/dev/null)" || return 1
  descriptor_mode="$(stat -f '%Lp' "$connection_file" 2>/dev/null)" || return 1
  descriptor_size="$(stat -f '%z' "$connection_file" 2>/dev/null)" || return 1
  [[ "$descriptor_owner" == "$(id -u)" ]] || return 1
  [[ "$descriptor_mode" =~ $secure_mode_pattern ]] || return 1
  ((descriptor_size > 0 && descriptor_size <= 65536)) || return 1

  if ! candidate_url="$(/usr/bin/plutil -extract base_url raw -o - "$connection_file" 2>/dev/null)"; then
    candidate_port="$(/usr/bin/plutil -extract port raw -o - "$connection_file" 2>/dev/null)" || return 1
    [[ "$candidate_port" =~ ^[0-9]{1,5}$ ]] || return 1
    candidate_url="http://127.0.0.1:$candidate_port"
  fi
  candidate_token="$(/usr/bin/plutil -extract token raw -o - "$connection_file" 2>/dev/null)" || return 1

  normalize_loopback_url "$candidate_url" || return 1
  valid_token "$candidate_token" || return 1
  resolved_helper_url="$normalized_helper_url"
  resolved_helper_token="$candidate_token"
}

descriptor_helper_is_ready() {
  load_secure_descriptor || return 1
  helper_is_healthy "$resolved_helper_url" "$resolved_helper_token"
}

wait_for_started_helper() {
  local attempt
  for ((attempt = 0; attempt < 50; attempt += 1)); do
    if descriptor_helper_is_ready; then
      return 0
    fi
    if ! kill -0 "$helper_pid" 2>/dev/null; then
      return 2
    fi
    sleep 0.5
  done
  return 1
}

# Explicit development connections still work, but an unreachable override
# must not prevent the launcher from falling back to its private local helper.
if [[ -n "${CHECKPOINT_AGENT_URL:-}" && -n "${CHECKPOINT_AGENT_TOKEN:-}" ]] &&
  helper_is_healthy "$CHECKPOINT_AGENT_URL" "$CHECKPOINT_AGENT_TOKEN"; then
  resolved_helper_url="$normalized_helper_url"
  resolved_helper_token="$CHECKPOINT_AGENT_TOKEN"
  echo "Private memory ready."
else
  unset CHECKPOINT_AGENT_URL CHECKPOINT_AGENT_TOKEN
  if descriptor_helper_is_ready; then
    echo "Private memory ready."
  else
    echo "Starting private memory…"
    helper_log="$(mktemp "${TMPDIR:-/tmp}/checkpoint-helper.XXXXXX")"
    chmod 600 "$helper_log"
    "$script_dir/run-helper.sh" >"$helper_log" 2>&1 &
    helper_pid=$!

    set +e
    wait_for_started_helper
    helper_wait_status=$?
    set -e
    if [[ "$helper_wait_status" -ne 0 ]]; then
      preserve_helper_log=1
      if [[ "$helper_wait_status" -eq 2 ]]; then
        echo "Private memory stopped before it was ready." >&2
      else
        echo "Private memory did not become ready within 25 seconds." >&2
      fi
      echo "Private helper log: $helper_log" >&2
      exit 1
    fi
    echo "Private memory ready."
  fi
fi

# The Swift client normally reads the same descriptor, but exporting the
# authenticated loopback connection also keeps custom CHECKPOINT_DATA_DIR
# launches aligned without exposing either value in process arguments.
export CHECKPOINT_AGENT_URL="$resolved_helper_url"
export CHECKPOINT_AGENT_TOKEN="$resolved_helper_token"

if [[ "${CHECKPOINT_DEMO_SEED:-0}" == "1" ]]; then
  echo "Preparing the voice + Moss + Bright Data demo…"
  CHECKPOINT_CONNECTION_FILE="$connection_file" "$script_dir/seed-demo.sh"
fi

echo "Opening CHECKPOINT…"
app_bundle="$("$script_dir/build-mac-app.sh")"
# Launch Services establishes the .app identity that macOS privacy controls
# require. Executing Contents/MacOS/Checkpoint directly makes Speech TCC treat
# it as a bare tool and terminate it even though the bundle plist is present.
# Launch Services rejects /dev/stdout and /dev/stderr as app redirection
# targets with error -10810 on current macOS. The helper already writes its
# diagnostics to a private log, so let the app inherit normal GUI logging.
open -n -W "$app_bundle" &
checkpoint_app_pid=$!
set +e
wait "$checkpoint_app_pid"
app_exit_status=$?
set -e
checkpoint_app_pid=""
exit "$app_exit_status"
