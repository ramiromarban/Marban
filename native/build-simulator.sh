#!/bin/sh
set -eu
cd "$(dirname "$0")"
xcodebuild -project GuizadoTV.xcodeproj -scheme GuizadoTV -configuration Debug -sdk iphonesimulator -destination "generic/platform=iOS Simulator" -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
