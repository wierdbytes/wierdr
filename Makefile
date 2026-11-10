# Wierdr build helpers. See docs/BUILD.md.
SIM_NAME ?= Wierdr iPad Pro 13 (M4)
DERIVED  := build/DerivedData
XCB      := xcodebuild -project Wierdr.xcodeproj -scheme Wierdr -derivedDataPath $(DERIVED) -skipPackagePluginValidation -skipMacroValidation
BUNDLE_ID := pw.xff.wierdr

.PHONY: project test sim sim-build device install ipa clean

project:
	xcodegen generate

test:
	cd Packages/WierdrKit && swift test

sim-build: project
	$(XCB) -configuration Debug -destination 'platform=iOS Simulator,name=$(SIM_NAME)' build | tail -3

sim: sim-build
	xcrun simctl boot "$(SIM_NAME)" 2>/dev/null || true
	open -a Simulator
	xcrun simctl install "$(SIM_NAME)" $(DERIVED)/Build/Products/Debug-iphonesimulator/Wierdr.app
	xcrun simctl launch "$(SIM_NAME)" $(BUNDLE_ID)

device: project
	$(XCB) -configuration Debug -destination 'generic/platform=iOS' -allowProvisioningUpdates build | tail -3

# Installs on the first connected iPad (or DEVICE=<udid|name>).
install: device
	./scripts/install-device.sh $(DERIVED)/Build/Products/Debug-iphoneos/Wierdr.app $(DEVICE)

ipa: project
	./scripts/make-ipa.sh

clean:
	rm -rf build
