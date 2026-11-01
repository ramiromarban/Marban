#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${GUIZADO_BUNDLE_ID:=tv.guizado.ios}"
if ! [[ "$GUIZADO_BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  echo 'Bundle ID inválido.' >&2; exit 1
fi
mkdir -p artifacts
xcodebuild -project GuizadoTV.xcodeproj -scheme GuizadoTV \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build-device PRODUCT_BUNDLE_IDENTIFIER="$GUIZADO_BUNDLE_ID" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
app='build-device/Build/Products/Release-iphoneos/GuizadoTV.app'
test -f "$app/GuizadoTV"
lipo "$app/GuizadoTV" -verify_arch arm64
plutil -lint "$app/Info.plist"
destination="$PWD/artifacts/GUIZADO-TV-sin-firma.ipa"
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
mkdir "$staging/Payload"
ditto "$app" "$staging/Payload/GuizadoTV.app"
(cd "$staging" && /usr/bin/zip -qry "$destination" Payload)
unzip -tq artifacts/GUIZADO-TV-sin-firma.ipa
printf '%s\n' 'IPA arm64 compilada para dispositivo, SIN FIRMA. No se instala directamente: requiere firma y un método de instalación compatible. No es una compilación de simulador. Reproducción no probada en un iPhone.' > artifacts/ESTADO.txt
shasum -a 256 artifacts/GUIZADO-TV-sin-firma.ipa > artifacts/SHA256.txt
