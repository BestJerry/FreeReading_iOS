#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
swift test --jobs 2
xcodebuild -project FreeReading.xcodeproj -scheme FreeReading \
  -configuration Debug -jobs 2 -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build-ios CODE_SIGNING_ALLOWED=NO build
