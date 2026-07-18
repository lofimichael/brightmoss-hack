#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
mac_root="$project_root/mac"
configuration="${CHECKPOINT_BUILD_CONFIGURATION:-debug}"

case "$configuration" in
  debug)
    build_arguments=(--product Checkpoint)
    ;;
  release)
    build_arguments=(--configuration release --product Checkpoint)
    ;;
  *)
    echo "CHECKPOINT_BUILD_CONFIGURATION must be debug or release." >&2
    exit 2
    ;;
esac

cd "$mac_root"
swift build "${build_arguments[@]}" >&2
binary_dir="$(swift build "${build_arguments[@]}" --show-bin-path)"
app_path="$binary_dir/CHECKPOINT.app"
staging_root="$(mktemp -d "$binary_dir/.checkpoint-app.XXXXXX")"
staging_app="$staging_root/CHECKPOINT.app"

cleanup() {
  rm -rf "$staging_root"
}
trap cleanup EXIT

mkdir -p \
  "$staging_app/Contents/MacOS" \
  "$staging_app/Contents/Frameworks" \
  "$staging_app/Contents/Resources"

cp "$binary_dir/Checkpoint" "$staging_app/Contents/MacOS/Checkpoint"
cp "$mac_root/Resources/Info.plist" "$staging_app/Contents/Info.plist"

for framework_name in RustLiveKitUniFFI.framework LiveKitWebRTC.framework; do
  source_framework="$binary_dir/$framework_name"
  if [[ ! -d "$source_framework" ]]; then
    echo "Required runtime framework is missing: $framework_name" >&2
    exit 1
  fi
  ditto "$source_framework" "$staging_app/Contents/Frameworks/$framework_name"
done

for resource_bundle in "$binary_dir"/*.bundle; do
  [[ -d "$resource_bundle" ]] || continue
  ditto \
    "$resource_bundle" \
    "$staging_app/Contents/Resources/$(basename "$resource_bundle")"
done

for privacy_key in \
  NSMicrophoneUsageDescription \
  NSSpeechRecognitionUsageDescription \
  NSScreenCaptureUsageDescription; do
  privacy_copy="$(plutil -extract "$privacy_key" raw -o - "$staging_app/Contents/Info.plist")"
  if [[ -z "$privacy_copy" ]]; then
    echo "The packaged app is missing $privacy_key." >&2
    exit 1
  fi
done

for framework in "$staging_app/Contents/Frameworks"/*.framework; do
  codesign --force --sign - "$framework"
done
codesign --force --sign - "$staging_app/Contents/MacOS/Checkpoint"
codesign --force --sign - "$staging_app"
codesign --verify --deep --strict --verbose=2 "$staging_app" >&2

# This target is a generated build product under SwiftPM's configuration-specific
# directory. Validate the exact suffix before replacing it.
case "$app_path" in
  "$binary_dir/CHECKPOINT.app") ;;
  *)
    echo "Refusing to replace an unexpected app path: $app_path" >&2
    exit 1
    ;;
esac
rm -rf "$app_path"
mv "$staging_app" "$app_path"

printf '%s\n' "$app_path"
