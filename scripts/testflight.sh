#!/bin/sh
# Archive Wierdr and upload it to App Store Connect (TestFlight). docs/BUILD.md › TestFlight.
#
#   scripts/testflight.sh           archive, sign for the App Store, upload
#   scripts/testflight.sh --export  the same without uploading: dist/Wierdr-appstore.ipa
#
# Signing and upload go through the App Store Connect API key from ~/.appstoreconnect/.env
# (ASC_KEY_ID, ASC_ISSUER_ID; the key: ~/.appstoreconnect/private_keys/AuthKey_<id>.p8).
# Distribution is cloud-managed: Xcode signs with Apple's cloud certificate and makes the
# App Store profiles itself (the key needs the Admin role).
# The build number is CURRENT_PROJECT_VERSION from project.yml; each upload needs a new one
# (bump it in project.yml, or BUILD=<n> for this run only).
set -eu
set -o pipefail
cd "$(dirname "$0")/.."

MODE=upload
[ "${1:-}" = "--export" ] && MODE=export

ENV=$HOME/.appstoreconnect/.env
[ -f "$ENV" ] || { echo "no $ENV (ASC_KEY_ID, ASC_ISSUER_ID)" >&2; exit 1; }
. "$ENV"
KEY=$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8
[ -f "$KEY" ] || { echo "no $KEY" >&2; exit 1; }
AUTH="-allowProvisioningUpdates -authenticationKeyPath $KEY -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID"

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)
BUILD=${BUILD:-$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\(.*\)"/\1/p' project.yml)}
[ -n "$(git status --porcelain)" ] && echo "note: the working tree has uncommitted changes; they go into the build"
echo "Wierdr $VERSION ($BUILD) → $MODE"

xcodegen generate >/dev/null
ARCHIVE=build/Wierdr-appstore.xcarchive
rm -rf "$ARCHIVE"
# shellcheck disable=SC2086
xcodebuild -project Wierdr.xcodeproj -scheme Wierdr -derivedDataPath build/DerivedData \
  -skipPackagePluginValidation -skipMacroValidation $AUTH \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" CURRENT_PROJECT_VERSION="$BUILD" archive | grep -E "error:|\*\* ARCHIVE" | cut -c1-300

OPTS=build/ExportOptions-appstore.plist
cat > "$OPTS" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>AUL4CCB2XY</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>testFlightInternalTestingOnly</key><false/>
</dict></plist>
PL
rm -rf build/export-appstore
# shellcheck disable=SC2086
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath build/export-appstore \
  -exportOptionsPlist "$OPTS" $AUTH 2>&1 | grep -vE "^\s*$" | tail -8

IPA=build/export-appstore/Wierdr.ipa
[ -f "$IPA" ] || { echo "export failed: no $IPA" >&2; exit 1; }
if [ "$MODE" = export ]; then
  mkdir -p dist
  cp "$IPA" dist/Wierdr-appstore.ipa
  echo "dist/Wierdr-appstore.ipa"
else
  # altool with the key, not exportArchive's destination=upload: that one failed with
  # "Account credentials have expired" (build 91) while the same key worked for the API.
  xcrun altool --upload-app -f "$IPA" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" 2>&1 \
    | grep -E "UPLOAD|ERROR|error" | cut -c1-300
  echo "Uploaded $VERSION ($BUILD). App Store Connect processes it for a few minutes, then: TestFlight › Internal Testing."
fi
