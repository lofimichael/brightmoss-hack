#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
env_file=""
require_full_demo=false

if [[ "${1:-}" == "--full-demo" ]]; then
  require_full_demo=true
  env_file="${2:-}"
elif [[ -n "${1:-}" ]]; then
  env_file="$1"
fi

set -a
if [[ -n "$env_file" && -f "$env_file" ]]; then
  # shellcheck disable=SC1090
  source "$env_file"
elif [[ -z "$env_file" ]]; then
  for operator_file in \
    "$project_root/.env" \
    "$project_root/scripts/.env.local" \
    "$project_root/.env.local"; do
    if [[ -f "$operator_file" ]]; then
      # shellcheck disable=SC1090
      source "$operator_file"
    fi
  done
fi
if [[ -z "${BRIGHT_DATA_API_KEY:-}" && -n "${BRIGHTDATA_API_KEY:-}" ]]; then
  BRIGHT_DATA_API_KEY="$BRIGHTDATA_API_KEY"
fi
set +a

configured() {
  local name="$1"
  local value="${!name:-}"
  [[ -n "$value" && "$value" != *your-* && "$value" != *YOUR_* ]]
}

capability() {
  local ready="$1"
  local label="$2"
  if [[ "$ready" == "true" ]]; then
    echo "  ready  $label"
  else
    echo "  later  $label"
  fi
}

bright_ready=false
moss_ready=false
livekit_client_ready=false
livekit_worker_ready=false

if configured BRIGHT_DATA_API_KEY || configured BRIGHTDATA_API_KEY; then
  bright_ready=true
fi
if configured MOSS_PROJECT_ID && configured MOSS_PROJECT_KEY; then
  moss_ready=true
fi
configured LIVEKIT_SANDBOX_ID && livekit_client_ready=true
if configured LIVEKIT_URL \
  && configured LIVEKIT_API_KEY \
  && configured LIVEKIT_API_SECRET; then
  livekit_worker_ready=true
fi

echo "CHECKPOINT consumer setup: ready — no provider keys are required at first launch."
echo "Operator capabilities (values were not printed):"
capability true "Local capture, SQLite graph, typed retrieval, and safe restore"
capability true "Native voice (on-device availability is checked at runtime)"
capability "$bright_ready" "Bright Data public enrichment"
capability "$moss_ready" "Moss local semantic retrieval"
capability "$livekit_client_ready" "LiveKit Mac voice client"
capability "$livekit_worker_ready" "LiveKit Cloud Inference voice worker"
echo "  runtime Apple's on-device model availability is checked inside the Mac app"

if [[ "$require_full_demo" == "true" ]]; then
  missing=()
  if ! configured BRIGHT_DATA_API_KEY && ! configured BRIGHTDATA_API_KEY; then
    missing+=("BRIGHT_DATA_API_KEY (or BRIGHTDATA_API_KEY)")
  fi
  for name in \
    MOSS_PROJECT_ID \
    MOSS_PROJECT_KEY \
    LIVEKIT_SANDBOX_ID \
    LIVEKIT_URL \
    LIVEKIT_API_KEY \
    LIVEKIT_API_SECRET; do
    configured "$name" || missing+=("$name")
  done

  if (( ${#missing[@]} > 0 )); then
    echo
    echo "The full sponsor demo still needs operator configuration:"
    for name in "${missing[@]}"; do
      echo "  - $name"
    done
    exit 1
  fi
fi
