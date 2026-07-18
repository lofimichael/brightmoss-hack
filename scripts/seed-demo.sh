#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
connection_file="${CHECKPOINT_CONNECTION_FILE:-$HOME/Library/Application Support/Checkpoint/agent-connection.json}"

if [[ ! -f "$connection_file" ]]; then
  echo "The local helper connection file does not exist: $connection_file"
  echo "Start the helper before seeding the demo."
  exit 1
fi

token="$(jq -er '.token' "$connection_file")"
if base_url="$(jq -er '.base_url' "$connection_file" 2>/dev/null)"; then
  :
else
  port="$(jq -er '.port' "$connection_file")"
  base_url="http://127.0.0.1:$port"
fi

payload="$(jq -n \
  --arg file "$project_root/demo/token-notes.md" \
  '{
    title: "BrightMoss auth",
    summary: "JWT generation is blocking the Mac agent.",
    next_step: "Implement and verify the LiveKit token endpoint.",
    artifacts: [
      {
        kind: "app",
        display_name: "Xcode",
        bundle_id: "com.apple.dt.Xcode"
      },
      {
        kind: "file",
        display_name: "token-notes.md",
        resource: $file
      },
      {
        kind: "url",
        display_name: "LiveKit token authentication",
        resource: "https://docs.livekit.io/home/client/connect/",
        captured_text: "Clients connect with a participant token issued by a trusted token server."
      }
    ]
  }')"

checkpoint_response="$(curl --fail-with-body --silent --show-error \
  -X POST "$base_url/checkpoints" \
  -H "Authorization: Bearer $token" \
  -H "Content-Type: application/json" \
  --data "$payload")"

printf '%s\n' "$checkpoint_response" \
  | jq '{id, title, summary, next_step, artifact_count: (.artifacts | length)}'

# Seed the same path passive capture uses. This produces a real, inspectable
# Expanded Knowledge ledger row without sending any local file text or requiring
# a well-timed app switch during the demo. The helper derives the public query;
# this script never supplies one.
checkpoint_id="$(printf '%s\n' "$checkpoint_response" | jq -er '.id')"
captured_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
observation_payload="$(jq -n \
  --arg checkpoint_id "$checkpoint_id" \
  --arg captured_at "$captured_at" \
  '{
    checkpoint_id: $checkpoint_id,
    captured_at: $captured_at,
    application_name: "Safari",
    app_bundle_id: "com.apple.Safari",
    window_title: "LiveKit client authentication",
    document_resource: "https://docs.livekit.io/home/client/connect/",
    extracted_text: "LiveKit clients connect using participant tokens issued by a trusted token server.",
    extraction_method: "accessibility",
    subjects: [
      {
        canonical_name: "LiveKit",
        kind: "technology",
        keywords: ["client connect", "participant token"],
        confidence: 0.98
      }
    ],
    likely_intent: {
      summary: "Review LiveKit client authentication guidance",
      confidence: 0.96
    },
    allow_public_enrichment: true
  }')"

curl --fail-with-body --silent --show-error \
  -X POST "$base_url/observations" \
  -H "Authorization: Bearer $token" \
  -H "Content-Type: application/json" \
  --data "$observation_payload" \
  | jq '{
      memory_id: .id,
      extraction_method,
      knowledge_status: (.enrichment.status // "not_attempted"),
      public_query: (.enrichment.outbound_query // null),
      added_sources: (.enrichment.sources | length? // 0)
    }'
