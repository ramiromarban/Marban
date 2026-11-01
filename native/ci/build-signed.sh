#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${GUIZADO_BUNDLE_ID:=tv.guizado.ios}"
: "${BUILD_CERTIFICATE_BASE64:?Falta el certificado en Secrets}"
: "${P12_PASSWORD:?Falta P12_PASSWORD en Secrets}"
: "${BUILD_PROVISION_PROFILE_BASE64:?Falta el perfil en Secrets}"
: "${KEYCHAIN_PASSWORD:?Falta KEYCHAIN_PASSWORD en Secrets}"
if ! [[ "$GUIZADO_BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then echo 'Bundle ID inválido.' >&2; exit 1; fi
scratch=$(mktemp -d)
keychain="$scratch/guizado-signing.keychain-db"
installed_profile=''
cleanup() {
  if [ -n "$installed_profile" ]; then rm -f "$installed_profile"; fi
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$scratch"
}
trap cleanup EXIT
printf %s "$BUILD_CERTIFICATE_BASE64" | base64 --decode > "$scratch/certificate.p12"
printf %s "$BUILD_PROVISION_PROFILE_BASE64" | base64 --decode > "$scratch/profile.mobileprovision"
security cms -D -i "$scratch/profile.mobileprovision" > "$scratch/profile.plist"
python3 ci/profile-options.py "$scratch/profile.plist" "$GUIZADO_BUNDLE_ID" "$scratch"
profile_uuid=$(cat "$scratch/uuid.txt")
team_id=$(cat "$scratch/team.txt")
mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
installed_profile="$HOME/Library/MobileDevice/Provisioning Profiles/$profile_uuid.mobileprovision"
cp "$scratch/profile.mobileprovision" "$installed_profile"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$keychain"
security import "$scratch/certificate.p12" -P "$P12_PASSWORD" -t cert -f pkcs12 -k "$keychain" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" "$HOME/Library/Keychains/login.keychain-db"
identity=$(security find-identity -v -p codesigning "$keychain" | sed -nE 's/.* ([0-9A-F]{40}) ".*/\1/p' | head -n 1)
if [ -z "$identity" ]; then echo 'El certificado no tiene una identidad de firma válida.' >&2; exit 1; fi
xcodebuild -project GuizadoTV.xcodeproj -scheme GuizadoTV \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -archivePath "$scratch/GuizadoTV.xcarchive" PRODUCT_BUNDLE_IDENTIFIER="$GUIZADO_BUNDLE_ID" \
  DEVELOPMENT_TEAM="$team_id" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" \
  PROVISIONING_PROFILE_SPECIFIER="$profile_uuid" archive
mkdir -p artifacts
xcodebuild -exportArchive -archivePath "$scratch/GuizadoTV.xcarchive" \
  -exportOptionsPlist "$scratch/ExportOptions.plist" -exportPath "$scratch/export"
ipa=$(find "$scratch/export" -maxdepth 1 -name '*.ipa' -print -quit)
test -n "$ipa"
cp "$ipa" artifacts/GUIZADO-TV-firmada.ipa
unzip -tq artifacts/GUIZADO-TV-firmada.ipa
mkdir "$scratch/verify"
unzip -q artifacts/GUIZADO-TV-firmada.ipa -d "$scratch/verify"
codesign --verify --deep --strict "$scratch/verify/Payload/GuizadoTV.app"
printf '%s\n' 'IPA exportada y firma verificada en macOS. Instalación limitada a dispositivos incluidos en el perfil Apple. Probar reproducción y funcionamiento en el iPhone antes de distribuir.' > artifacts/ESTADO.txt
shasum -a 256 artifacts/GUIZADO-TV-firmada.ipa > artifacts/SHA256.txt
