#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project GuizadoTV.xcodeproj -scheme GuizadoTV \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build-simulator CODE_SIGNING_ALLOWED=NO build
simulator=$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; candidates=[v["udid"] for k in sorted(d,reverse=True) if "iOS" in k for v in d[k] if v.get("isAvailable") and v["name"].startswith("iPhone")]; assert candidates,"No iPhone simulator available"; print(candidates[0])')
xcrun simctl boot "$simulator"
xcrun simctl bootstatus "$simulator" -b
xcrun simctl install "$simulator" build-simulator/Build/Products/Debug-iphonesimulator/GuizadoTV.app
xcrun simctl launch "$simulator" tv.guizado.ios
sleep 10
xcrun simctl spawn "$simulator" launchctl list | grep -F 'tv.guizado.ios'
mkdir -p artifacts
xcrun simctl io "$simulator" screenshot artifacts/GUIZADO-TV-inicio-iPhone.png
printf '%s\n' 'Simulator smoke test: installed and launched; process still present after 10 seconds. Screenshot captured. Real-device playback, signing and installation still need verification.' > artifacts/PRUEBA-SIMULADOR.txt
