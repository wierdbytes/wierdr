#!/bin/sh
# Build a development-signed Wierdr.ipa into dist/ (installable on the team's
# registered devices: Xcode › Devices, Apple Configurator, or `devicectl device install app`).
set -eu
cd "$(dirname "$0")/.."
DERIVED=build/DerivedData
xcodebuild -project Wierdr.xcodeproj -scheme Wierdr -derivedDataPath $DERIVED \
  -skipPackagePluginValidation -skipMacroValidation -allowProvisioningUpdates \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/Wierdr.xcarchive archive | tail -3
cat > build/ExportOptions.plist <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>debugging</string>
  <key>teamID</key><string>AUL4CCB2XY</string>
  <key>signingStyle</key><string>automatic</string>
  <key>compileBitcode</key><false/>
  <key>stripSwiftSymbols</key><true/>
</dict></plist>
PL
rm -rf build/export
xcodebuild -exportArchive -archivePath build/Wierdr.xcarchive -exportPath build/export \
  -exportOptionsPlist build/ExportOptions.plist -allowProvisioningUpdates | tail -3
mkdir -p dist
cp build/export/Wierdr.ipa dist/Wierdr.ipa
echo "dist/Wierdr.ipa"
