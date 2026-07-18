#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# One command for the judge-facing path. run-mac starts (or reuses) the current
# authenticated helper, seed-demo records a safe passive observation and lets
# the helper derive/enrich its public subject, then the native app opens.
export CHECKPOINT_DEMO_SEED=1
exec "$script_dir/run-mac.sh"
